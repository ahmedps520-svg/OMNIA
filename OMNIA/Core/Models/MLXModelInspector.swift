import Foundation

/// What an MLX model folder holds, from its config.json: the architecture, the numbers memory
/// planning needs, and how it's quantized.
struct MLXModelInfo: Sendable, Equatable {
    var modelType: String
    var facts: ArchitectureFacts
    var quantizationLabel: String?
    var weightBytes: UInt64
}

enum MLXModelInspector {
    enum Failure: LocalizedError, Equatable {
        case missing(String)
        case unreadable(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .missing(let file): "The model folder has no \(file)."
            case .unreadable(let file): "The model's \(file) couldn't be read."
            case .unsupported(let type): "MLX in OMNIA can't run this architecture (\(type)) yet."
            }
        }
    }

    /// Checks the folder has what MLX needs to run it, and reads its config.
    static func inspect(folderAt folder: URL) throws -> MLXModelInfo {
        let fileManager = FileManager.default
        func exists(_ name: String) -> Bool { fileManager.fileExists(atPath: folder.appending(path: name).path(percentEncoded: false)) }
        guard exists("config.json") else { throw Failure.missing("config.json") }
        guard exists("tokenizer.json") else { throw Failure.missing("tokenizer.json") }
        let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let weights = contents.filter { $0.pathExtension == "safetensors" }
        guard !weights.isEmpty else { throw Failure.missing("weights (.safetensors)") }
        let weightBytes = weights.reduce(UInt64(0)) { total, url in
            total + UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let data = try? Data(contentsOf: folder.appending(path: "config.json")),
              let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.unreadable("config.json")
        }
        return try info(config: config, weightBytes: weightBytes, chatTemplate: chatTemplate(in: folder))
    }

    /// The chat template: its own file, or inside tokenizer_config.json.
    static func chatTemplate(in folder: URL) -> String? {
        if let text = try? String(contentsOf: folder.appending(path: "chat_template.jinja"), encoding: .utf8) { return text }
        for name in ["chat_template.json", "tokenizer_config.json"] {
            guard let data = try? Data(contentsOf: folder.appending(path: name)),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let template = object["chat_template"] as? String { return template }
            // Some tokenizers list named templates: use the default one.
            if let named = object["chat_template"] as? [[String: Any]],
               let template = (named.first { $0["name"] as? String == "default" } ?? named.first)?["template"] as? String {
                return template
            }
        }
        return nil
    }

    /// Pure: what config.json says, with the weights' total size.
    static func info(config: [String: Any], weightBytes: UInt64, chatTemplate: String?) throws -> MLXModelInfo {
        // The registry knows a model by the top level's type; text_config may name its own part.
        guard let modelType = config["model_type"] as? String else { throw Failure.unreadable("config.json") }
        guard chatTemplate != nil else { throw Failure.missing("chat template") }
        // Multimodal configs keep the language model's numbers under text_config.
        let text = config.merging(config["text_config"] as? [String: Any] ?? [:]) { _, nested in nested }
        func int(_ key: String) -> Int? { (text[key] as? NSNumber)?.intValue }

        guard let layers = int("num_hidden_layers"), layers > 0 else { throw Failure.unreadable("config.json") }
        let heads = int("num_attention_heads") ?? 1
        let kvHeads = int("num_key_value_heads") ?? heads
        let hidden = int("hidden_size") ?? 0
        let headDim = int("head_dim") ?? (heads > 0 ? hidden / heads : 0)
        // Gemma 4's full-attention layers have their own head size and KV-head count.
        let fullHeads = int("num_global_key_value_heads") ?? kvHeads
        let fullHeadDim = int("global_head_dim") ?? headDim
        let window = int("sliding_window") ?? 0
        // Gemma 4 E2B and E4B: the last layers reuse earlier layers' caches.
        let cachedLayers = max(layers - (int("num_kv_shared_layers") ?? 0), 0)

        // Which layers keep a full cache, a sliding window, or a fixed recurrent state.
        var full = cachedLayers, sliding = 0, linear = 0
        if let types = text["layer_types"] as? [String], types.count == layers {
            let cached = types.prefix(cachedLayers)
            func isLinear(_ type: String) -> Bool { type.contains("linear") || type.contains("mamba") || type.contains("conv") }
            sliding = cached.filter { $0.contains("sliding") }.count
            full = cached.filter { !$0.contains("sliding") && !isLinear($0) }.count
            linear = types.filter(isLinear).count
        } else if let pattern = int("sliding_window_pattern"), pattern > 1, window > 0 {
            full = cachedLayers / pattern
            sliding = cachedLayers - full
        }
        let recurrent = linear > 0 ? UInt64(linear) * recurrentStateBytes(text) : 0

        // Parameters from the weights' size and precision; quantized weights carry a 16-bit scale
        // and bias for every group.
        let quantization = (config["quantization"] ?? config["quantization_config"]) as? [String: Any]
        let bits = (quantization?["bits"] as? NSNumber)?.intValue
        let groupSize = (quantization?["group_size"] as? NSNumber)?.intValue ?? 64
        let bytesPerParameter = bits.map { (Double($0) + 32 / Double(max(groupSize, 1))) / 8 } ?? 2
        let parameters = Double(weightBytes) / bytesPerParameter / 1e9

        let facts = ArchitectureFacts(
            architecture: modelType, layers: layers,
            kvElementsFull: full * fullHeads * fullHeadDim * 2, kvElementsSliding: sliding * kvHeads * headDim * 2,
            slidingWindow: sliding > 0 ? window : 0,
            recurrentStateBytes: recurrent, embeddingLength: hidden, vocabSize: int("vocab_size") ?? 0,
            trainContext: int("max_position_embeddings") ?? 4096, parameters: parameters,
            thinkingToggle: chatTemplate?.contains("enable_thinking") ?? false)
        return MLXModelInfo(modelType: modelType, facts: facts, quantizationLabel: bits.map { "MLX \($0)-bit" } ?? "MLX 16-bit",
                            weightBytes: weightBytes)
    }

    /// A linear-attention layer's state (Qwen3.5's gated delta rule): a value-by-key matrix per
    /// head in 32-bit floats, plus its convolution's last few inputs.
    private static func recurrentStateBytes(_ config: [String: Any]) -> UInt64 {
        func int(_ key: String) -> Int { (config[key] as? NSNumber)?.intValue ?? 0 }
        let keyHeads = int("linear_num_key_heads"), valueHeads = int("linear_num_value_heads")
        let keyDim = int("linear_key_head_dim"), valueDim = int("linear_value_head_dim")
        let kernel = max(int("linear_conv_kernel_dim"), 1)
        guard valueHeads > 0, keyDim > 0, valueDim > 0 else { return 16 << 20 }
        let state = valueHeads * keyDim * valueDim * 4
        let convolution = (keyHeads * keyDim * 2 + valueHeads * valueDim) * (kernel - 1) * 2
        return UInt64(state + convolution)
    }
}
