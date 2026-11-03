import Foundation
import llama

/// A llama.cpp embedding model: turns text into vectors whose closeness reflects meaning.
///
/// Like `LlamaRuntime`, every C call happens on a private serial queue. Each text is one
/// sequence in a batch and comes back as its pooled vector (the pooling the GGUF names: mean
/// for EmbeddingGemma, CLS for BERT models, last token for Qwen3-Embedding), L2-normalized so
/// a dot product is the cosine similarity.
final class EmbeddingRuntime: @unchecked Sendable {
    enum Failure: LocalizedError {
        case loadFailed
        case contextFailed
        case notAnEmbeddingModel
        case decodeFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .loadFailed: "The embedding model couldn't be read."
            case .contextFailed: "The embedding model couldn't be started."
            case .notAnEmbeddingModel: "This file isn't an embedding model."
            case .decodeFailed(let status): "Embedding failed (llama_decode returned \(status))."
            }
        }
    }

    /// Length of each vector.
    let dimensions: Int
    /// Tokens of a text that are read; longer texts are cut to this.
    let maxTokens: Int

    private let queue: DispatchQueue
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private var batch: llama_batch
    /// Texts embedded together in one batch.
    private static let sequenceLimit = 8
    private var isClosed = false

    static func load(fileURL: URL, contextLength: Int = 2048, threads: Int = 4) async throws -> EmbeddingRuntime {
        _ = LlamaRuntime.engineVersion // initializes the llama.cpp backend
        let queue = DispatchQueue(label: "app.omnia.embedding", qos: .userInitiated)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try EmbeddingRuntime(fileURL: fileURL, contextLength: contextLength,
                                                                        threads: threads, queue: queue))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private init(fileURL: URL, contextLength: Int, threads: Int, queue: DispatchQueue) throws {
        self.queue = queue
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 999
        #endif
        guard let loadedModel = llama_model_load_from_file(fileURL.path(percentEncoded: false), modelParams) else {
            throw Failure.loadFailed
        }
        let length = max(256, min(contextLength, Int(llama_model_n_ctx_train(loadedModel))))
        var params = llama_context_default_params()
        params.n_ctx = UInt32(length)
        // Encoders read a whole batch in one micro-batch.
        params.n_batch = UInt32(length)
        params.n_ubatch = UInt32(length)
        params.n_seq_max = UInt32(Self.sequenceLimit)
        params.kv_unified = true
        params.n_threads = Int32(threads)
        params.n_threads_batch = Int32(threads)
        params.embeddings = true
        params.pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED
        params.no_perf = true
        #if targetEnvironment(simulator)
        params.offload_kqv = false
        #endif
        guard let createdContext = llama_init_from_model(loadedModel, params) else {
            llama_model_free(loadedModel)
            throw Failure.contextFailed
        }
        guard llama_pooling_type(createdContext) != LLAMA_POOLING_TYPE_NONE,
              let loadedVocab = llama_model_get_vocab(loadedModel) else {
            llama_free(createdContext)
            llama_model_free(loadedModel)
            throw Failure.notAnEmbeddingModel
        }
        model = loadedModel
        context = createdContext
        vocab = loadedVocab
        maxTokens = length
        dimensions = Int(llama_model_n_embd_out(loadedModel))
        batch = llama_batch_init(Int32(length), 0, 1)
    }

    /// One normalized vector per text, in order.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    guard !self.isClosed else { throw Failure.contextFailed }
                    continuation.resume(returning: try self.run(texts))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.freeResources()
                continuation.resume()
            }
        }
    }

    deinit {
        if !isClosed { freeResources() }
    }

    private func freeResources() {
        guard !isClosed else { return }
        isClosed = true
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    // MARK: Batches

    private func run(_ texts: [String]) throws -> [[Float]] {
        let tokenized = try texts.map(tokens)
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        var start = 0
        while start < tokenized.count {
            // As many texts as fit the batch, at least one.
            var end = start
            var used = 0
            while end < tokenized.count, end - start < Self.sequenceLimit,
                  end == start || used + tokenized[end].count <= maxTokens {
                used += tokenized[end].count
                end += 1
            }
            vectors += try embedBatch(Array(tokenized[start..<end]))
            start = end
        }
        return vectors
    }

    private func embedBatch(_ sequences: [[llama_token]]) throws -> [[Float]] {
        // Models with a cache (decoder embedders such as Qwen3-Embedding) start each batch empty.
        if let memory = llama_get_memory(context) {
            llama_memory_clear(memory, true)
        }
        batch.n_tokens = 0
        for (sequence, tokens) in sequences.enumerated() {
            for (position, token) in tokens.enumerated() {
                let index = Int(batch.n_tokens)
                batch.token[index] = token
                batch.pos[index] = llama_pos(position)
                batch.n_seq_id[index] = 1
                batch.seq_id[index]![0] = llama_seq_id(sequence)
                batch.logits[index] = 1
                batch.n_tokens += 1
            }
        }
        let status = llama_decode(context, batch)
        guard status == 0 else { throw Failure.decodeFailed(status) }
        return try sequences.indices.map { sequence in
            guard let pooled = llama_get_embeddings_seq(context, llama_seq_id(sequence)) else {
                throw Failure.notAnEmbeddingModel
            }
            return Self.normalized(Array(UnsafeBufferPointer(start: pooled, count: dimensions)))
        }
    }

    /// The text's tokens with the model's special tokens; a text that's too long keeps its
    /// beginning and its final token (the EOS or SEP some poolings read).
    private func tokens(_ text: String) throws -> [llama_token] {
        let byteCount = text.utf8.count
        var buffer = [llama_token](repeating: 0, count: byteCount + 8)
        var count = llama_tokenize(vocab, text, Int32(byteCount), &buffer, Int32(buffer.count), true, false)
        if count < 0, count != Int32.min {
            buffer = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, Int32(byteCount), &buffer, Int32(buffer.count), true, false)
        }
        guard count > 0 else { throw InferenceError.tokenizationFailed }
        let tokens = Array(buffer.prefix(Int(count)))
        guard tokens.count > maxTokens else { return tokens }
        return Array(tokens.prefix(maxTokens - 1)) + [tokens[tokens.count - 1]]
    }

    static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return vector }
        return vector.map { $0 / length }
    }
}
