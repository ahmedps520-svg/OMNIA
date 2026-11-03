import Foundation
import Testing
@testable import OMNIA

/// MLX models are folders: how their downloads are tracked and what their config.json says.
@Suite("MLX models")
struct MLXModelTests {
    @Test func tracksWhichFileOfAFolderATaskIs() {
        let plain = DownloadManager.parseTaskDescription(DownloadManager.taskDescription(id: "repo/model.gguf", file: nil))
        #expect(plain.id == "repo/model.gguf")
        #expect(plain.file == nil)
        let folder = DownloadManager.parseTaskDescription(DownloadManager.taskDescription(id: "mlx/repo", file: 3))
        #expect(folder.id == "mlx/repo")
        #expect(folder.file == 3)
    }

    @Test func readsADenseModel() throws {
        let config: [String: Any] = [
            "model_type": "llama", "num_hidden_layers": 16, "num_attention_heads": 32, "num_key_value_heads": 8,
            "hidden_size": 2048, "vocab_size": 128_256, "max_position_embeddings": 131_072,
            "quantization": ["bits": 4, "group_size": 64]
        ]
        let info = try MLXModelInspector.info(config: config, weightBytes: 1_800_000_000, chatTemplate: "{{ messages }}")
        #expect(info.modelType == "llama")
        #expect(info.quantizationLabel == "4-bit")
        // 8 KV heads × 64 dimensions × keys and values, in all 16 layers.
        #expect(info.facts.kvElementsFull == 16 * 8 * 64 * 2)
        #expect(info.facts.kvElementsSliding == 0)
        // 4 bits plus a 16-bit scale and bias per 64 weights: 0.5625 bytes a parameter.
        #expect(abs(info.facts.parameters - 3.2) < 0.01)
        #expect(info.facts.trainContext == 131_072)
        #expect(!info.facts.thinkingToggle)
    }

    @Test func readsSlidingWindowLayersUnderTextConfig() throws {
        let types = (0..<12).map { $0 % 6 == 5 ? "full_attention" : "sliding_attention" }
        let config: [String: Any] = [
            "model_type": "gemma3",
            "text_config": [
                "num_hidden_layers": 12, "num_attention_heads": 8, "num_key_value_heads": 4, "head_dim": 256,
                "hidden_size": 2560, "sliding_window": 1024, "layer_types": types
            ] as [String: Any],
            "quantization": ["bits": 4, "group_size": 64]
        ]
        let info = try MLXModelInspector.info(config: config, weightBytes: 2_000_000_000, chatTemplate: "{{ messages }}")
        #expect(info.facts.layers == 12)
        #expect(info.facts.kvElementsFull == 2 * 4 * 256 * 2)
        #expect(info.facts.kvElementsSliding == 10 * 4 * 256 * 2)
        #expect(info.facts.slidingWindow == 1024)
    }

    @Test func readsAHybridModelsRecurrentLayers() throws {
        let types = (0..<8).map { $0 % 4 == 3 ? "full_attention" : "linear_attention" }
        let config: [String: Any] = [
            "model_type": "qwen3_5", "num_hidden_layers": 8, "num_attention_heads": 16, "num_key_value_heads": 2,
            "head_dim": 256, "hidden_size": 2048, "layer_types": types,
            "linear_num_key_heads": 16, "linear_num_value_heads": 32, "linear_key_head_dim": 128,
            "linear_value_head_dim": 128, "linear_conv_kernel_dim": 4
        ]
        let info = try MLXModelInspector.info(config: config, weightBytes: 4_000_000_000,
                                              chatTemplate: "{% if enable_thinking %}<think>{% endif %}")
        #expect(info.facts.kvElementsFull == 2 * 2 * 256 * 2)
        #expect(info.facts.recurrentStateBytes > 6 * 32 * 128 * 128 * 4)
        #expect(info.quantizationLabel == "16-bit")
        #expect(info.facts.thinkingToggle)
    }

    /// mlx-community/gemma-4-e4b-it-4bit's config: 42 layers, the last 18 reusing earlier caches,
    /// full layers with 512-wide heads.
    @Test func readsGemma4SharedCachesAndWideFullLayers() throws {
        let types = (0..<42).map { $0 % 6 == 5 ? "full_attention" : "sliding_attention" }
        let config: [String: Any] = [
            "model_type": "gemma4",
            "text_config": [
                "model_type": "gemma4_text", "num_hidden_layers": 42, "num_attention_heads": 8, "num_key_value_heads": 2,
                "head_dim": 256, "global_head_dim": 512, "num_global_key_value_heads": NSNull(), "hidden_size": 2560,
                "sliding_window": 512, "num_kv_shared_layers": 18, "layer_types": types, "max_position_embeddings": 131_072
            ] as [String: Any],
            "quantization": ["bits": 4, "group_size": 64]
        ]
        let info = try MLXModelInspector.info(config: config, weightBytes: 5_146_800_534, chatTemplate: "{{ messages }}")
        #expect(info.modelType == "gemma4")
        // 24 layers keep a cache: 4 full (2 heads × 512 × K and V) and 20 sliding (2 × 256 × 2).
        #expect(info.facts.kvElementsFull == 4 * 2 * 512 * 2)
        #expect(info.facts.kvElementsSliding == 20 * 2 * 256 * 2)
        #expect(info.facts.slidingWindow == 512)
    }

    @Test func needsAChatTemplate() {
        let config: [String: Any] = ["model_type": "llama", "num_hidden_layers": 2]
        #expect(throws: MLXModelInspector.Failure.missing("chat template")) {
            try MLXModelInspector.info(config: config, weightBytes: 1, chatTemplate: nil)
        }
    }
}
