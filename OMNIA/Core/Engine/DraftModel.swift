import Foundation
import llama

/// A small model with the same vocabulary as the main one, used for speculative decoding: it
/// proposes several tokens ahead, which the main model then checks in a single batch.
///
/// Owned by a `LlamaRuntime` and confined to its serial queue, like the runtime itself.
final class DraftModel {
    enum Failure: LocalizedError {
        case loadFailed
        case contextFailed
        case incompatible(String)
        case noRollback

        var errorDescription: String? {
            switch self {
            case .loadFailed: "The draft model couldn't be loaded."
            case .contextFailed: "Not enough memory for the draft model's context."
            case .incompatible(let reason): "The draft model can't be used with this model: \(reason)."
            case .noRollback: "This draft model's architecture can't undo rejected tokens."
            }
        }
    }

    let displayName: String
    /// Tokens proposed per step.
    let length: Int
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private var batch: llama_batch
    private let batchCapacity: Int
    private let slidingWindow: Int
    /// Tokens held in the draft's cache, by position.
    private(set) var cachedTokens: [llama_token] = []
    private var isClosed = false

    init(fileURL: URL, displayName: String, length: Int, contextLength: Int, threads: Int, gpuOffload: Bool,
         targetVocab: OpaquePointer) throws {
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = gpuOffload ? 999 : 0
        #endif
        guard let loaded = llama_model_load_from_file(fileURL.path(percentEncoded: false), modelParams) else {
            throw Failure.loadFailed
        }
        guard let draftVocab = llama_model_get_vocab(loaded) else {
            llama_model_free(loaded)
            throw Failure.loadFailed
        }
        if let reason = DraftModel.incompatibility(target: targetVocab, draft: draftVocab) {
            llama_model_free(loaded)
            throw Failure.incompatible(reason)
        }

        // Recurrent and hybrid layers can only undo rejected tokens from state snapshots.
        let recurrent = llama_model_is_recurrent(loaded) || llama_model_is_hybrid(loaded)
        var params = llama_context_default_params()
        params.n_ctx = UInt32(contextLength)
        params.n_batch = 512
        params.n_ubatch = 512
        params.n_seq_max = 1
        params.n_rs_seq = recurrent ? UInt32(length + 1) : 0
        params.n_threads = Int32(threads)
        params.n_threads_batch = Int32(threads)
        params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        #if targetEnvironment(simulator)
        params.offload_kqv = false
        #else
        params.offload_kqv = gpuOffload
        #endif
        params.swa_full = false
        params.no_perf = true
        guard let created = llama_init_from_model(loaded, params) else {
            llama_model_free(loaded)
            throw Failure.contextFailed
        }
        if recurrent && llama_n_rs_seq(created) < UInt32(length) {
            llama_free(created)
            llama_model_free(loaded)
            throw Failure.noRollback
        }
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            llama_free(created)
            llama_model_free(loaded)
            throw Failure.contextFailed
        }
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())

        self.displayName = displayName
        self.length = length
        model = loaded
        context = created
        vocab = draftVocab
        sampler = chain
        batchCapacity = max(1, Int(llama_n_batch(created)))
        batch = llama_batch_init(Int32(batchCapacity), 0, 1)
        slidingWindow = Int(llama_model_n_swa(loaded))
    }

    /// llama.cpp's rule for draft models (`common_speculative_are_compatible`): the same tokenizer
    /// type, the same start and end tokens, vocabulary sizes within 128 of each other, and the same
    /// text for every token from id 5 on. Returns why they differ, or nil when compatible.
    static func incompatibility(target: OpaquePointer, draft: OpaquePointer) -> String? {
        if llama_vocab_type(target) != llama_vocab_type(draft) { return "it uses a different kind of tokenizer" }
        let addsBOS = llama_vocab_get_add_bos(target)
        if addsBOS != llama_vocab_get_add_bos(draft) || (addsBOS && llama_vocab_bos(target) != llama_vocab_bos(draft)) {
            return "its start-of-text token differs"
        }
        let addsEOS = llama_vocab_get_add_eos(target)
        if addsEOS != llama_vocab_get_add_eos(draft) || (addsEOS && llama_vocab_eos(target) != llama_vocab_eos(draft)) {
            return "its end-of-text token differs"
        }
        let targetCount = llama_vocab_n_tokens(target)
        let draftCount = llama_vocab_n_tokens(draft)
        if abs(targetCount - draftCount) > 128 {
            return "its vocabulary has \(draftCount) tokens instead of \(targetCount)"
        }
        let shared = min(targetCount, draftCount)
        guard shared > 5 else { return nil }
        for id in Int32(5)..<shared {
            guard let a = llama_vocab_get_text(target, id), let b = llama_vocab_get_text(draft, id), strcmp(a, b) == 0 else {
                return "token \(id) differs"
            }
        }
        return nil
    }

    /// Makes the draft's cache hold exactly `tokens` (the main model's cache), keeping whatever
    /// prefix it already shares.
    func sync(to tokens: [llama_token]) throws {
        let memory = llama_get_memory(context)
        var common = zip(cachedTokens, tokens).prefix { $0 == $1 }.count
        if common < cachedTokens.count {
            // A sliding-window cache must still hold the window before `common` to keep it.
            let windowStart = llama_pos(max(0, common - slidingWindow))
            if common == 0 || (slidingWindow > 0 && llama_memory_seq_pos_min(memory, 0) > windowStart)
                || !llama_memory_seq_rm(memory, 0, llama_pos(common), -1) {
                llama_memory_clear(memory, true)
                common = 0
            }
            cachedTokens = Array(cachedTokens.prefix(common))
        }
        var index = common
        while index < tokens.count {
            let end = min(index + batchCapacity, tokens.count)
            batch.n_tokens = 0
            for position in index..<end {
                LlamaRuntime.add(&batch, token: tokens[position], position: position, logits: false)
            }
            let status = llama_decode(context, batch)
            guard status == 0 else {
                llama_memory_clear(memory, true)
                cachedTokens = []
                throw InferenceError.decodeFailed(status)
            }
            cachedTokens.append(contentsOf: tokens[index..<end])
            index = end
        }
    }

    /// Proposes up to `count` tokens that follow `last`, greedily. The cache must already hold
    /// everything before `last`; afterwards it holds `last` and all but the final proposal.
    func propose(after last: llama_token, count: Int) throws -> [llama_token] {
        var proposal: [llama_token] = []
        var token = last
        for _ in 0..<count {
            batch.n_tokens = 0
            LlamaRuntime.add(&batch, token: token, position: cachedTokens.count, logits: true)
            let status = llama_decode(context, batch)
            guard status == 0 else {
                llama_memory_clear(llama_get_memory(context), true)
                cachedTokens = []
                throw InferenceError.decodeFailed(status)
            }
            cachedTokens.append(token)
            token = llama_sampler_sample(sampler, context, -1)
            proposal.append(token)
            // Nothing worth drafting after the end of the reply.
            if llama_vocab_is_eog(vocab, token) { break }
        }
        return proposal
    }

    /// Keeps only the first `count` cached tokens: the ones the main model accepted.
    func keep(_ count: Int) {
        guard count < cachedTokens.count else { return }
        let memory = llama_get_memory(context)
        if llama_memory_seq_rm(memory, 0, llama_pos(count), -1) {
            cachedTokens.removeLast(cachedTokens.count - count)
        } else {
            llama_memory_clear(memory, true)
            cachedTokens = []
        }
    }

    func reset() {
        llama_memory_clear(llama_get_memory(context), true)
        cachedTokens = []
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        cachedTokens = []
        llama_sampler_free(sampler)
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    deinit { close() }
}
