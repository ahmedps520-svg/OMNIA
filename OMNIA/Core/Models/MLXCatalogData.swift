// MLX models: folders of safetensors run by the MLX engine, from public Hugging Face repositories.
// Generated from scripts/catalog/mlx-models.json (Hub file sizes and SHA-256 at pinned commits, and
// each config.json). Regenerate with scripts/generate-mlx-catalog.mjs rather than editing by hand.

import Foundation

extension ModelCatalog {
    static let mlx: [CatalogModel] = [
        CatalogModel(
            id: "mlx-gemma-4-e2b-it",
            name: "Gemma 4 E2B",
            developer: "Google DeepMind",
            repo: "mlx-community/gemma-4-e2b-it-4bit",
            license: "Apache 2.0",
            released: "April 2026",
            summary: "Gemma 4 E2B on MLX: the quickest model here, for short answers on any device.",
            qualityScore: 54,
            tags: ["MLX", "Fastest", "Efficient"],
            facts: ArchitectureFacts(
                architecture: "gemma4", layers: 35, kvElementsFull: 3_072, kvElementsSliding: 6_144,
                slidingWindow: 512, recurrentStateBytes: 0,
                embeddingLength: 1_536, vocabSize: 262_144, trainContext: 131_072,
                parameters: 5.1, activeParameters: 2.3, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "MLX 4-bit", fileName: "gemma-4-e2b-it-4bit", sizeBytes: 3_583_085_182, sha256: "", files: [
                    ModelFile(path: "chat_template.jinja", bytes: 17_336, sha256: "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082"),
                    ModelFile(path: "config.json", bytes: 6_395, sha256: "6397cb6eca41b911d1dcab74e17941351057bd759284052a2331918ff6f9246c"),
                    ModelFile(path: "generation_config.json", bytes: 208, sha256: "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
                    ModelFile(path: "model.safetensors", bytes: 3_550_670_554, sha256: "038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e"),
                    ModelFile(path: "model.safetensors.index.json", bytes: 218_323, sha256: "edb157dbf495e23f37377af4a628a9ad13c4ee7937f93ccb36ec9e9a19940f16"),
                    ModelFile(path: "tokenizer.json", bytes: 32_169_626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                    ModelFile(path: "tokenizer_config.json", bytes: 2_740, sha256: "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656")
                ], revision: "238767527555cb75a05732a84dff5d6ba0dd6809")
            ]
        ),
        CatalogModel(
            id: "mlx-gemma-4-e4b-it",
            name: "Gemma 4 E4B",
            developer: "Google DeepMind",
            repo: "mlx-community/gemma-4-e4b-it-4bit",
            license: "Apache 2.0",
            released: "April 2026",
            summary: "Gemma 4 E4B on MLX: made for phones and tablets, with optional reasoning.",
            qualityScore: 64,
            tags: ["MLX", "Efficient", "Optional reasoning"],
            facts: ArchitectureFacts(
                architecture: "gemma4", layers: 42, kvElementsFull: 8_192, kvElementsSliding: 20_480,
                slidingWindow: 512, recurrentStateBytes: 0,
                embeddingLength: 2_560, vocabSize: 262_144, trainContext: 131_072,
                parameters: 8, activeParameters: 4.5, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "MLX 4-bit", fileName: "gemma-4-e4b-it-4bit", sizeBytes: 5_179_238_033, sha256: "", files: [
                    ModelFile(path: "chat_template.jinja", bytes: 17_336, sha256: "2f1b4d75d067bae3fe44e676721c7f077d243bc007156cb9c2f8b5836613d082"),
                    ModelFile(path: "config.json", bytes: 6_628, sha256: "780ccb3a514a5f1ced161d383f948fc22eca9b84b752ca19494f625bd9bad7a6"),
                    ModelFile(path: "generation_config.json", bytes: 208, sha256: "d4226bbe3117d2d253ba4609720ba82c6c4ce4627a9a6ae05387c78983ac03de"),
                    ModelFile(path: "model.safetensors", bytes: 5_146_800_534, sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
                    ModelFile(path: "model.safetensors.index.json", bytes: 240_961, sha256: "f8accac59ee7efe87e0c298c854610b262c3cadd477407503147c71209ff0093"),
                    ModelFile(path: "tokenizer.json", bytes: 32_169_626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                    ModelFile(path: "tokenizer_config.json", bytes: 2_740, sha256: "080d9e1aff284e2f6043889cd05367966f7c7b80e025fbc0b06745e218158656")
                ], revision: "475b9088d29754a3379866cf5aeb6b41acd313c2")
            ]
        ),
        CatalogModel(
            id: "mlx-gemma-4-12b-it",
            name: "Gemma 4 12B",
            developer: "Google DeepMind",
            repo: "mlx-community/gemma-4-12B-it-4bit",
            license: "Apache 2.0",
            released: "May 2026",
            summary: "Gemma 4 12B on MLX: polished, well-formatted answers and a long context. Best on iPad.",
            qualityScore: 80,
            tags: ["MLX", "Optional reasoning", "Dense"],
            facts: ArchitectureFacts(
                architecture: "gemma4_unified", layers: 48, kvElementsFull: 8_192, kvElementsSliding: 163_840,
                slidingWindow: 1_024, recurrentStateBytes: 0,
                embeddingLength: 3_840, vocabSize: 262_144, trainContext: 262_144,
                parameters: 12, activeParameters: 12, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "MLX 4-bit", fileName: "gemma-4-12B-it-4bit", sizeBytes: 6_773_370_326, sha256: "", files: [
                    ModelFile(path: "chat_template.jinja", bytes: 17_466, sha256: "36e3a42e5cf14cd0020e72d92e1fdd9970f59b82170e421f0cbe1bb42bead3f0"),
                    ModelFile(path: "config.json", bytes: 5_415, sha256: "fbc1c1cb48ed86ec98482b2d41f5a03d3991aba74b7c29a93d430761e6518a38"),
                    ModelFile(path: "generation_config.json", bytes: 260, sha256: "a8349d9bd64cc5841297fcb5002f0fdc4749c473c8f1b10ea337f9ce4ee7014e"),
                    ModelFile(path: "model-00001-of-00002.safetensors", bytes: 5_351_756_584, sha256: "0d58feed0c98a69c07317b4481aeae5ab2785f12a496ea96ab24c4842808de78"),
                    ModelFile(path: "model-00002-of-00002.safetensors", bytes: 1_389_282_927, sha256: "5b00a1bcb596ce6e827b4cdea6ecf2a0f35bb01306eb87c1ea4b3bcde36c7755"),
                    ModelFile(path: "model.safetensors.index.json", bytes: 135_329, sha256: "9ac99e7a6cf3e4d40eb8df01644fe9c04036ace94f3389df35db9d9449758516"),
                    ModelFile(path: "tokenizer.json", bytes: 32_169_626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                    ModelFile(path: "tokenizer_config.json", bytes: 2_719, sha256: "fc1384a911d2c9860ac07bc3ceafff20bff26695991744b7dbe5e1e4522bfa57")
                ], revision: "73bcf09092aa277861d5a191b989b666f7f32e8f")
            ]
        ),
        CatalogModel(
            id: "mlx-qwen3.5-4b",
            name: "Qwen3.5 4B",
            developer: "Qwen (Alibaba)",
            repo: "mlx-community/Qwen3.5-4B-MLX-4bit",
            license: "Apache 2.0",
            released: "February 2026",
            summary: "Qwen3.5 4B on MLX: strong reasoning for its size with a very small memory cache.",
            qualityScore: 70,
            tags: ["MLX", "Reasoning", "Efficient"],
            facts: ArchitectureFacts(
                architecture: "qwen3_5", layers: 32, kvElementsFull: 16_384, kvElementsSliding: 0,
                slidingWindow: 0, recurrentStateBytes: 51_511_296,
                embeddingLength: 2_560, vocabSize: 248_320, trainContext: 262_144,
                parameters: 4.7, activeParameters: 4.7, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "MLX 4-bit", fileName: "Qwen3.5-4B-MLX-4bit", sizeBytes: 3_054_404_243, sha256: "", files: [
                    ModelFile(path: "chat_template.jinja", bytes: 7_756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
                    ModelFile(path: "config.json", bytes: 3_366, sha256: "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
                    ModelFile(path: "model.safetensors", bytes: 3_034_300_695, sha256: "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
                    ModelFile(path: "model.safetensors.index.json", bytes: 101_944, sha256: "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
                    ModelFile(path: "tokenizer.json", bytes: 19_989_343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                    ModelFile(path: "tokenizer_config.json", bytes: 1_139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182")
                ], revision: "32f3e8ecf65426fc3306969496342d504bfa13f3")
            ]
        ),
        CatalogModel(
            id: "mlx-qwen3.5-9b",
            name: "Qwen3.5 9B",
            developer: "Qwen (Alibaba)",
            repo: "mlx-community/Qwen3.5-9B-4bit",
            license: "Apache 2.0",
            released: "February 2026",
            summary: "Qwen3.5 9B on MLX: well-rounded, with a 262K context and a very small memory cache.",
            qualityScore: 77,
            tags: ["MLX", "Reasoning", "Hybrid attention"],
            facts: ArchitectureFacts(
                architecture: "qwen3_5", layers: 32, kvElementsFull: 16_384, kvElementsSliding: 0,
                slidingWindow: 0, recurrentStateBytes: 51_511_296,
                embeddingLength: 4_096, vocabSize: 248_320, trainContext: 262_144,
                parameters: 9.7, activeParameters: 9.7, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "MLX 4-bit", fileName: "Qwen3.5-9B-4bit", sizeBytes: 5_970_346_233, sha256: "", files: [
                    ModelFile(path: "chat_template.jinja", bytes: 7_756, sha256: "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
                    ModelFile(path: "config.json", bytes: 3_331, sha256: "a96942cb6a8a1d3f1d17514d81a1925d04362a6a3233b389d13012211baaa9f8"),
                    ModelFile(path: "model-00001-of-00002.safetensors", bytes: 5_349_771_222, sha256: "a68b87558c6ef43f74c2bd63ce7e9092ceddc3101f3def0030774bae5f42aadd"),
                    ModelFile(path: "model-00002-of-00002.safetensors", bytes: 600_449_850, sha256: "b0a770bf8469c7f3f18756a0e0283f1c1174344a83e059a4e483f6af4907352d"),
                    ModelFile(path: "model.safetensors.index.json", bytes: 123_592, sha256: "dd023913fb87cfdae27fb11dcf695117c925833796ccac3c64117d6652d8ff1e"),
                    ModelFile(path: "tokenizer.json", bytes: 19_989_343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                    ModelFile(path: "tokenizer_config.json", bytes: 1_139, sha256: "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182")
                ], revision: "8b2b98c00a6b4d291155e4890773ca8f769aee53")
            ]
        ),
        CatalogModel(
            id: "mlx-granite-4.2-3b",
            name: "Granite 4.2 3B",
            developer: "IBM",
            repo: "ibm-granite/granite-4.2-3b-q4-mlx",
            license: "Apache 2.0",
            released: "August 2026",
            summary: "Granite 4.2 3B, IBM's own MLX build: a compact reasoning model.",
            qualityScore: 60,
            tags: ["MLX", "Reasoning", "Efficient"],
            facts: ArchitectureFacts(
                architecture: "granite", layers: 40, kvElementsFull: 40_960, kvElementsSliding: 0,
                slidingWindow: 0, recurrentStateBytes: 0,
                embeddingLength: 2_560, vocabSize: 100_352, trainContext: 131_072,
                parameters: 3.7, activeParameters: 3.7, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "MLX 4-bit", fileName: "granite-4.2-3b-q4-mlx", sizeBytes: 2_066_169_685, sha256: "", files: [
                    ModelFile(path: "chat_template.jinja", bytes: 9_013, sha256: "f0ba43f79b3cabca5e5a7584c77aec92f49feae45cdf7779c87d9fc54cd90258"),
                    ModelFile(path: "config.json", bytes: 1_185, sha256: "bfcb1a01587dae223af89f07b960f0b456ef9fe9576167a126aa807941b213d7"),
                    ModelFile(path: "generation_config.json", bytes: 207, sha256: "1b9baf0a7959d31d7fb58ff6b506c27d09a73d395cadccc7e6dd1d4b7e43fd9d"),
                    ModelFile(path: "model.safetensors", bytes: 2_059_005_430, sha256: "a71cf9297827b3c3d6ad426081b67c423044f6576632dabe40e7590552fd267d"),
                    ModelFile(path: "tokenizer.json", bytes: 7_153_414, sha256: "883975314d58743726347caaf2c32ac89afd5ad57222cffbc4f052f2ab27b2d7"),
                    ModelFile(path: "tokenizer_config.json", bytes: 436, sha256: "0b1cc678b9fbde8ce90c81e0f6483c4e1696dfa377330e42a88106416b96e659")
                ], revision: "0c6f39b1827afd5eb2c1c3b13751929857434953")
            ]
        )
    ]
}
