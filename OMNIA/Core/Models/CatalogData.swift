// Generated from Hugging Face API data (sizes, SHA-256) and each file's GGUF header (architecture facts).
// Every repository below was verified as openly downloadable (not gated) on 2026-11-02.
// Image encoders (mmproj files, for photos and screenshots) were verified the same way on 2026-11-03.
// Regenerate with scripts/generate-catalog.mjs rather than editing by hand.

import Foundation

extension ModelCatalog {
    static let curated: [CatalogModel] = [
        CatalogModel(
            id: "qwen3.8-27b",
            name: "Qwen3.8 27B",
            developer: "Qwen (Alibaba)",
            repo: "unsloth/Qwen3.8-27B-GGUF",
            license: "Apache 2.0",
            released: "August 2026",
            summary: "Qwen's strongest small model and the most capable in this catalog. Its hybrid Gated DeltaNet design keeps the KV cache tiny for long contexts; it thinks before answering by default.",
            qualityScore: 92,
            tags: ["Reasoning", "Hybrid attention"],
            facts: ArchitectureFacts(
                architecture: "qwen35", layers: 64, kvElementsFull: 32_768, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 156_893_184,
                embeddingLength: 5_120, vocabSize: 248_320, trainContext: 262_144,
                parameters: 27.8, activeParameters: 27.8, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "UD-IQ2_XXS", fileName: "Qwen3.8-27B-UD-IQ2_XXS.gguf", sizeBytes: 7_266_070_528, sha256: "e792d8fb3142fe6d9171876d6da0f71f05a71028718debc72dbec93ff645e67d"),
                CatalogVariant(quant: "UD-Q2_K_XL", fileName: "Qwen3.8-27B-UD-Q2_K_XL.gguf", sizeBytes: 9_828_981_664, sha256: "fd4730dd8aad070517978752b63d530aeb1740d2283cab9fa24f1e404032ddb0"),
                CatalogVariant(quant: "UD-IQ3_XXS", fileName: "Qwen3.8-27B-UD-IQ3_XXS.gguf", sizeBytes: 10_934_860_704, sha256: "c0b7c3038681ed2e3040456c1dd45f9858b6c2290bed172c70388a94874f3eee"),
                CatalogVariant(quant: "UD-Q3_K_XL", fileName: "Qwen3.8-27B-UD-Q3_K_XL.gguf", sizeBytes: 13_146_393_504, sha256: "8c2a45ff85e7674ca185ec8eb6cdeab0e617ed9d8018caed0b64380eb2a67a5e"),
                CatalogVariant(quant: "UD-Q4_K_M", fileName: "Qwen3.8-27B-UD-Q4_K_M.gguf", sizeBytes: 16_464_440_224, sha256: "322e194ff79741c7baa497c240f677f54b201b0efab44ca8e50f122b39123482"),
                CatalogVariant(quant: "UD-Q5_K_M", fileName: "Qwen3.8-27B-UD-Q5_K_M.gguf", sizeBytes: 19_771_509_664, sha256: "2de73110cb254cbf09b54b717578dadff12ef1194e7271527e68202f39ba4bfd"),
                CatalogVariant(quant: "UD-Q6_K", fileName: "Qwen3.8-27B-UD-Q6_K.gguf", sizeBytes: 21_983_677_344, sha256: "c9c206812fbe4ac7b76a729e25928b63f2ae89d37f69da7a71c20aec763cd436"),
                CatalogVariant(quant: "Q8_0", fileName: "Qwen3.8-27B-Q8_0.gguf", sizeBytes: 29_047_086_048, sha256: "a680f44a06920e5d689774823782006aa3acc8db95750323373b24139b67e348")
            ],
            projector: CatalogProjector(repo: "ggml-org/Qwen3.8-27B-GGUF", fileName: "mmproj-Qwen3.8-27B-Q8_0.gguf",
                                        sizeBytes: 629_247_008, sha256: "2e968a6af97ce35d8971890b257b9b7edabf20ad91450501fa53162a19ee33eb")
        ),
        CatalogModel(
            id: "qwen3.6-35b-a3b",
            name: "Qwen3.6 35B-A3B",
            developer: "Qwen (Alibaba)",
            repo: "unsloth/Qwen3.6-35B-A3B-GGUF",
            license: "Apache 2.0",
            released: "April 2026",
            summary: "256-expert mixture of experts with about 3B active parameters: high reasoning quality at the speed of a small model.",
            qualityScore: 87,
            tags: ["Reasoning", "Mixture of experts"],
            facts: ArchitectureFacts(
                architecture: "qwen35moe", layers: 40, kvElementsFull: 10_240, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 65_863_680,
                embeddingLength: 2_048, vocabSize: 248_320, trainContext: 262_144,
                parameters: 36, activeParameters: 3, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "UD-IQ2_XXS", fileName: "Qwen3.6-35B-A3B-UD-IQ2_XXS.gguf", sizeBytes: 10_756_586_464, sha256: "2e8f5f705355c56311432d0a8a5d14a696dbb7e4b197d05c75ba805fc1857bef"),
                CatalogVariant(quant: "UD-IQ2_M", fileName: "Qwen3.6-35B-A3B-UD-IQ2_M.gguf", sizeBytes: 11_522_702_304, sha256: "2be7ef1ed7e1af8b10d3829102cf9a6c2bd5ddb64d675b4ece23a60799403d43"),
                CatalogVariant(quant: "UD-Q2_K_XL", fileName: "Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf", sizeBytes: 12_290_628_576, sha256: "96b9c0af5c77a4ecaabe3983175112b5ece763261c1ece12b2494b692a70dad7"),
                CatalogVariant(quant: "UD-IQ3_XXS", fileName: "Qwen3.6-35B-A3B-UD-IQ3_XXS.gguf", sizeBytes: 13_211_155_424, sha256: "9c964e657212fea1f24905dd7b0a89b82fd807d19fab0b41da14251b07b88fbe")
            ],
            projector: CatalogProjector(repo: "ggml-org/Qwen3.6-35B-A3B-GGUF", fileName: "mmproj-Qwen3.6-35B-A3B-Q8_0.gguf",
                                        sizeBytes: 614_194_304, sha256: "904cbf8c8e876220066ab3bf676c7efa40f3da372276fdaf8b01d2fb2a37a51d")
        ),
        CatalogModel(
            id: "ornith-1.5-35b-a3b",
            name: "Ornith 1.5 35B-A3B",
            developer: "Ornith AI",
            repo: "bartowski/Ornith-1.5-35B-A3B-GGUF",
            license: "MIT",
            released: "August 2026",
            summary: "Qwen3.6-architecture mixture of experts refined with reinforcement learning. Very strong reasoning and coding scores with only about 3B parameters active per token.",
            qualityScore: 89,
            tags: ["Reasoning", "Mixture of experts"],
            facts: ArchitectureFacts(
                architecture: "qwen35moe", layers: 41, kvElementsFull: 10_240, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 68_059_136,
                embeddingLength: 2_048, vocabSize: 248_320, trainContext: 262_144,
                parameters: 36, activeParameters: 3, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ2_XXS", fileName: "Ornith-1.5-35B-A3B-IQ2_XXS.gguf", sizeBytes: 10_255_140_512, sha256: "14963c6830ae8287ad42a53c0fd87ca9fc67a8de8da1d18e3a076a348e96a32f"),
                CatalogVariant(quant: "IQ2_S", fileName: "Ornith-1.5-35B-A3B-IQ2_S.gguf", sizeBytes: 11_486_963_360, sha256: "49b923ebe5f4d4a4384ccb86dd2b93effacc96ec1a3054a0192cc61dc045ebab"),
                CatalogVariant(quant: "IQ2_M", fileName: "Ornith-1.5-35B-A3B-IQ2_M.gguf", sizeBytes: 12_543_403_680, sha256: "be92ed1eb2da35876e91a5551c527ddcce450d49ec53aba92f03e26adba7b996")
            ],
            projector: CatalogProjector(repo: "bartowski/Ornith-1.5-35B-A3B-GGUF", fileName: "mmproj-Ornith-1.5-35B-A3B-f16.gguf",
                                        sizeBytes: 899_283_296, sha256: "815c9a671991aceeef46ca1aa103b64499db8cfadf21c83005a20ed839d53c7c")
        ),
        CatalogModel(
            id: "gemma-4-26b-a4b-it",
            name: "Gemma 4 26B-A4B IT",
            developer: "Google DeepMind",
            repo: "bartowski/google_gemma-4-26B-A4B-it-GGUF",
            license: "Apache 2.0",
            released: "April 2026",
            summary: "Google DeepMind's Gemma 4 mixture of experts (3.8B active). Excellent writing and multilingual quality; reasoning can be switched on.",
            qualityScore: 85,
            tags: ["Mixture of experts", "Optional reasoning"],
            facts: ArchitectureFacts(
                architecture: "gemma4", layers: 30, kvElementsFull: 10_240, kvElementsSliding: 102_400,
                slidingWindow: 1_024, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 2_816, vocabSize: 262_144, trainContext: 262_144,
                parameters: 25.2, activeParameters: 3.8, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ2_M", fileName: "google_gemma-4-26B-A4B-it-IQ2_M.gguf", sizeBytes: 10_700_622_464, sha256: "88c25a0e8ecc975b90bcf3766301d5e565a5378ed04fbdd04c8049d87eab43a5"),
                CatalogVariant(quant: "IQ3_XXS", fileName: "google_gemma-4-26B-A4B-it-IQ3_XXS.gguf", sizeBytes: 12_160_200_320, sha256: "61a9be08df2dd3ee5e98b23f1f548530c05ec89e02647a650f2ad447fcc83998"),
                CatalogVariant(quant: "Q3_K_M", fileName: "google_gemma-4-26B-A4B-it-Q3_K_M.gguf", sizeBytes: 13_019_981_440, sha256: "4826221b7a285284b65222537f58ebfc6880290ff5441e13bfb1a7ca4d65df21"),
                CatalogVariant(quant: "Q3_K_L", fileName: "google_gemma-4-26B-A4B-it-Q3_K_L.gguf", sizeBytes: 13_199_180_416, sha256: "2a74593c43e06245f86577f2d1e27a268d91be655993f70dfd64cb556214b347"),
                CatalogVariant(quant: "IQ3_M", fileName: "google_gemma-4-26B-A4B-it-IQ3_M.gguf", sizeBytes: 13_280_213_632, sha256: "b08876e7eb0adc0dcac8f2d24ec064c62fd2cbd1813514516ad669e75fefecf6")
            ],
            projector: CatalogProjector(repo: "ggml-org/gemma-4-26B-A4B-it-GGUF", fileName: "mmproj-gemma-4-26B-A4B-it-Q8_0.gguf",
                                        sizeBytes: 806_408_320, sha256: "cc4e855736da450bf1e162d8cccfe0ad685727d0c9e04ef7dd8d884f3121039b")
        ),
        CatalogModel(
            id: "gpt-oss-20b",
            name: "gpt-oss-20b",
            developer: "OpenAI",
            repo: "ggml-org/gpt-oss-20b-GGUF",
            license: "Apache 2.0",
            released: "August 2025",
            summary: "OpenAI's open-weight reasoning model in its native MXFP4 precision. It reasons in a separate analysis channel before answering.",
            qualityScore: 82,
            tags: ["Reasoning", "Mixture of experts"],
            facts: ArchitectureFacts(
                architecture: "gpt-oss", layers: 24, kvElementsFull: 12_288, kvElementsSliding: 12_288,
                slidingWindow: 128, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 2_880, vocabSize: 201_088, trainContext: 131_072,
                parameters: 20.9, activeParameters: 3.6, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "MXFP4", fileName: "gpt-oss-20b-MXFP4.gguf", sizeBytes: 12_109_566_624, sha256: "27cd6c432c7672cb812a92f611cf3ba7bbc35928262bb1e1253ff4ee6ae35901")
            ]
        ),
        CatalogModel(
            id: "lfm2.5-24b-a2b",
            name: "LFM2.5 24B-A2B",
            developer: "Liquid AI",
            repo: "unsloth/LFM2.5-24B-A2B-GGUF",
            license: "LFM Open License 1.0",
            released: "October 2026",
            summary: "Liquid AI hybrid mixture of experts with only 2.45B active parameters: the fastest 20B-class model, built for on-device agents.",
            qualityScore: 74,
            tags: ["Reasoning", "Mixture of experts", "Fast"],
            facts: ArchitectureFacts(
                architecture: "lfm2moe", layers: 40, kvElementsFull: 10_240, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 737_280,
                embeddingLength: 2_048, vocabSize: 128_000, trainContext: 131_072,
                parameters: 24, activeParameters: 2.45, thinkingToggle: false),
            variants: [
                CatalogVariant(quant: "UD-IQ2_M", fileName: "LFM2.5-24B-A2B-UD-IQ2_M.gguf", sizeBytes: 7_535_313_152, sha256: "54d861a1245d460389e971112e07f9313d75778ba96e12880594f2352a83a992"),
                CatalogVariant(quant: "UD-Q2_K_XL", fileName: "LFM2.5-24B-A2B-UD-Q2_K_XL.gguf", sizeBytes: 8_042_561_760, sha256: "bc1b210bdeec1592e3dc374cc9154fd29654a9004d01a6a9eae4809de69f58dc"),
                CatalogVariant(quant: "UD-IQ3_XXS", fileName: "LFM2.5-24B-A2B-UD-IQ3_XXS.gguf", sizeBytes: 8_959_328_480, sha256: "e06694b1f0bb322ecfde6bf9af260d2f2047ed1b30bbfdd04d97bf55472bfeec"),
                CatalogVariant(quant: "UD-Q3_K_XL", fileName: "LFM2.5-24B-A2B-UD-Q3_K_XL.gguf", sizeBytes: 10_947_100_928, sha256: "d54834c785c7e265f1cb7375e47aa6f55a0b7cfab75816254c4d2e0c82fd5efc")
            ]
        ),
        CatalogModel(
            id: "muse-glimmer-30b",
            name: "Muse Glimmer 30B",
            developer: "Meta",
            repo: "bartowski/Muse-Glimmer-30B-GGUF",
            license: "Apache 2.0",
            released: "August 2026",
            summary: "Meta's 2026 open-weight model, distilled from Muse Spark, with adjustable reasoning strength. Dense, so slower than mixture-of-experts peers.",
            qualityScore: 82,
            tags: ["Reasoning", "Dense"],
            facts: ArchitectureFacts(
                architecture: "muse-glimmer", layers: 52, kvElementsFull: 6_656, kvElementsSliding: 19_968,
                slidingWindow: 2_048, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 6_656, vocabSize: 202_048, trainContext: 131_072,
                parameters: 29.8, activeParameters: 29.8, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ2_M", fileName: "Muse-Glimmer-30B-IQ2_M.gguf", sizeBytes: 10_657_479_200, sha256: "67a24245fb600a01668163b7afb5287c0413eff21f326b482da45b8fa0727e7d"),
                CatalogVariant(quant: "IQ3_XXS", fileName: "Muse-Glimmer-30B-IQ3_XXS.gguf", sizeBytes: 11_546_640_928, sha256: "bc489d8df5a3bdf85ef200bd1dcec9a436290502354810163549cac328dac90a"),
                CatalogVariant(quant: "IQ3_M", fileName: "Muse-Glimmer-30B-IQ3_M.gguf", sizeBytes: 13_106_238_240, sha256: "bc867ee4fc139be474cc4e6c1794ac584507ec510bcfdefe9772a61779181b6f")
            ],
            projector: CatalogProjector(repo: "meta-models/Muse-Glimmer-30B-GGUF", fileName: "mmproj-Muse-Glimmer-30B-Q4_K_M.gguf",
                                        sizeBytes: 1_400_328_928, sha256: "f48b452316f9b213758e8659444029b961a24a07f99a1abb2a9f88b06f7c00c6")
        ),
        CatalogModel(
            id: "gemma-4-12b-it",
            name: "Gemma 4 12B IT",
            developer: "Google DeepMind",
            repo: "bartowski/gemma-4-12B-it-GGUF",
            license: "Apache 2.0",
            released: "May 2026",
            summary: "Dense Gemma 4 with long context and polished, well-formatted answers. Reasoning is off by default and can be enabled per conversation.",
            qualityScore: 80,
            tags: ["Optional reasoning", "Dense"],
            facts: ArchitectureFacts(
                architecture: "gemma4", layers: 48, kvElementsFull: 8_192, kvElementsSliding: 163_840,
                slidingWindow: 1_024, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 3_840, vocabSize: 262_144, trainContext: 131_072,
                parameters: 12, activeParameters: 12, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ4_XS", fileName: "gemma-4-12B-it-IQ4_XS.gguf", sizeBytes: 6_780_746_208, sha256: "60e817ec84aabab9d20ac1eeec5d0e5fc5859993eb2f234e0f0d95fef2aa87f7"),
                CatalogVariant(quant: "Q4_0", fileName: "gemma-4-12B-it-Q4_0.gguf", sizeBytes: 7_127_759_328, sha256: "3624c1b6039ceaf8bfaa92581401de40d25fab9bf914f31039a5940a0bc1ee15"),
                CatalogVariant(quant: "Q4_K_M", fileName: "gemma-4-12B-it-Q4_K_M.gguf", sizeBytes: 7_662_533_088, sha256: "3962624dcd25b947d889dc9ae1bf275b61db6cd4dbe694057f34fffef1671509"),
                CatalogVariant(quant: "Q5_K_M", fileName: "gemma-4-12B-it-Q5_K_M.gguf", sizeBytes: 8_774_965_728, sha256: "24fe88d9e6bba6a1805629a09e40d4d837a894d559c7708055f7a03211e2a25e"),
                CatalogVariant(quant: "Q6_K", fileName: "gemma-4-12B-it-Q6_K.gguf", sizeBytes: 10_239_326_688, sha256: "53336de05c4af36dcb61daf0d984be076ddf0245e3ce7f61aa10b72cb4044e97"),
                CatalogVariant(quant: "Q8_0", fileName: "gemma-4-12B-it-Q8_0.gguf", sizeBytes: 12_669_647_328, sha256: "929bd294cbdc59e41450488bea524a174f1c6ddc43f140fdb5905a5fd1e41969")
            ],
            projector: CatalogProjector(repo: "bartowski/gemma-4-12B-it-GGUF", fileName: "mmproj-gemma-4-12B-it-f16.gguf",
                                        sizeBytes: 122_031_552, sha256: "563192209f002b0a13af16a4992fdb9dd61187a36919eaf65f408bb47af3d272")
        ),
        CatalogModel(
            id: "ministral-3-14b-instruct-2512",
            name: "Ministral 3 14B Instruct 2512",
            developer: "Mistral AI",
            repo: "bartowski/mistralai_Ministral-3-14B-Instruct-2512-GGUF",
            license: "Apache 2.0",
            released: "December 2025",
            summary: "Mistral's 14B instruct model answers directly without a thinking phase, so replies start quickly. Mistral recommends a low temperature.",
            qualityScore: 76,
            tags: ["Fast answers", "Dense"],
            facts: ArchitectureFacts(
                architecture: "mistral3", layers: 40, kvElementsFull: 81_920, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 5_120, vocabSize: 131_072, trainContext: 262_144,
                parameters: 13.9, activeParameters: 13.9, thinkingToggle: false),
            variants: [
                CatalogVariant(quant: "IQ4_XS", fileName: "mistralai_Ministral-3-14B-Instruct-2512-IQ4_XS.gguf", sizeBytes: 7_411_185_056, sha256: "2895179103887c0af8ae306d5c27d09d2ff4af7da1bda4866f06113d2b669668"),
                CatalogVariant(quant: "Q4_0", fileName: "mistralai_Ministral-3-14B-Instruct-2512-Q4_0.gguf", sizeBytes: 7_805_711_776, sha256: "33f6dfe39c946265744a44734c6636d2224b6a3cebfa39e1b502604598ba55ad"),
                CatalogVariant(quant: "Q4_K_M", fileName: "mistralai_Ministral-3-14B-Instruct-2512-Q4_K_M.gguf", sizeBytes: 8_239_068_576, sha256: "a95aea79c3043039306f9c3957aa091baf24d428507eb7596c59ddc54ff75b80"),
                CatalogVariant(quant: "Q5_K_M", fileName: "mistralai_Ministral-3-14B-Instruct-2512-Q5_K_M.gguf", sizeBytes: 9_620_567_456, sha256: "d6ab2abd228ed45c7d85b4896d6d6d86a40421e741aaf8add9da61c4a0563a0f"),
                CatalogVariant(quant: "Q6_K", fileName: "mistralai_Ministral-3-14B-Instruct-2512-Q6_K.gguf", sizeBytes: 11_088_410_016, sha256: "4321da3bfec9f407025e693e2c5dc05d166b7acc67b03bbada46c7eb5847b2cd")
            ],
            projector: CatalogProjector(repo: "ggml-org/Ministral-3-14B-Instruct-2512-GGUF", fileName: "mmproj-Ministral-3-14B-Instruct-2512-Q8_0.gguf",
                                        sizeBytes: 468_347_296, sha256: "2227355540f1d88b462892ea0bcc5c45cc73eb29433652bdedc33a8de88ba31b")
        ),
        CatalogModel(
            id: "ornith-1.5-9b",
            name: "Ornith 1.5 9B",
            developer: "Ornith AI",
            repo: "ornith-ai/Ornith-1.5-9B-GGUF",
            license: "MIT",
            released: "August 2026",
            summary: "The strongest model around 9B on published benchmarks: Qwen3.5-9B further trained with a self-improving reinforcement learning loop.",
            qualityScore: 81,
            tags: ["Reasoning", "Hybrid attention"],
            facts: ArchitectureFacts(
                architecture: "qwen35", layers: 33, kvElementsFull: 16_384, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 54_886_400,
                embeddingLength: 4_096, vocabSize: 248_320, trainContext: 262_144,
                parameters: 9.7, activeParameters: 9.7, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "Q4_K_M", fileName: "Ornith-1.5-9B-Q4_K_M.gguf", sizeBytes: 5_780_090_816, sha256: "70c112196e0b7023803c9762752e46d29e612a92c83f995bc3ba1ceb07e8fab6"),
                CatalogVariant(quant: "Q5_K_M", fileName: "Ornith-1.5-9B-Q5_K_M.gguf", sizeBytes: 6_642_544_576, sha256: "e4d9634a3b6546a5c00a8680568fe1125f6c98c704ee51ae52ba07650fb4247d"),
                CatalogVariant(quant: "Q6_K", fileName: "Ornith-1.5-9B-Q6_K.gguf", sizeBytes: 7_558_901_696, sha256: "b6f76e74f86245b3caee014b797c10dca931c4dfdaabfb134eab655f81e4154a"),
                CatalogVariant(quant: "Q8_0", fileName: "Ornith-1.5-9B-Q8_0.gguf", sizeBytes: 9_786_060_384, sha256: "22086870b009dbe9815ee752c48a82de930118a7c5ce5599590892ae03b8b010")
            ],
            projector: CatalogProjector(repo: "bartowski/Ornith-1.5-9B-GGUF", fileName: "mmproj-Ornith-1.5-9B-f16.gguf",
                                        sizeBytes: 918_165_728, sha256: "946850fd82bd43b856d878267bc9db809f0aaa37c81bf11918ecad1de464625e")
        ),
        CatalogModel(
            id: "qwen3.5-9b",
            name: "Qwen3.5 9B",
            developer: "Qwen (Alibaba)",
            repo: "bartowski/Qwen_Qwen3.5-9B-GGUF",
            license: "Apache 2.0",
            released: "February 2026",
            summary: "Well-rounded 9B hybrid model with a 262K context window and a very small KV cache.",
            qualityScore: 77,
            tags: ["Reasoning", "Hybrid attention"],
            facts: ArchitectureFacts(
                architecture: "qwen35", layers: 33, kvElementsFull: 16_384, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 54_886_400,
                embeddingLength: 4_096, vocabSize: 248_320, trainContext: 262_144,
                parameters: 9.7, activeParameters: 9.7, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ4_XS", fileName: "Qwen_Qwen3.5-9B-IQ4_XS.gguf", sizeBytes: 5_501_202_464, sha256: "7d977cc96c2e08616016d967f232083e354691a8a16f345b26f7d782ee5c9601"),
                CatalogVariant(quant: "Q4_0", fileName: "Qwen_Qwen3.5-9B-Q4_0.gguf", sizeBytes: 5_741_391_904, sha256: "a44b0e06af0c97cece312f6dca52b3639d038d1a74a2e194b22e159f9ccdbb21"),
                CatalogVariant(quant: "Q4_K_M", fileName: "Qwen_Qwen3.5-9B-Q4_K_M.gguf", sizeBytes: 6_169_341_984, sha256: "d784ce9eda1a5a7b51e8f705a9e6310844bf4f173654d115823c775fdea56d43"),
                CatalogVariant(quant: "Q5_K_M", fileName: "Qwen_Qwen3.5-9B-Q5_K_M.gguf", sizeBytes: 7_111_487_520, sha256: "a686d88ec1e6881f9bf161526826cd6d6874b7f0e80e0f79acf6144a132c5d7e"),
                CatalogVariant(quant: "Q6_K", fileName: "Qwen_Qwen3.5-9B-Q6_K.gguf", sizeBytes: 7_958_818_848, sha256: "073a9275e65d9c8cd2819cf5f77b99fbaa6e87ba591da6bbaa86ec073a64bfef"),
                CatalogVariant(quant: "Q8_0", fileName: "Qwen_Qwen3.5-9B-Q8_0.gguf", sizeBytes: 9_804_541_984, sha256: "b58fe056b5435070240de259f3f981aa38fee96825bbd78c088d5fd90e46f2b5")
            ],
            projector: CatalogProjector(repo: "bartowski/Qwen_Qwen3.5-9B-GGUF", fileName: "mmproj-Qwen_Qwen3.5-9B-f16.gguf",
                                        sizeBytes: 918_165_952, sha256: "97f420245a85ce129bb764e86a5e21e27d782fe6d6056c6839b9c5fdb8f38289")
        ),
        CatalogModel(
            id: "mimo-v2.6-distill-qwen-9b",
            name: "MiMo-V2.6 Distill Qwen 9B",
            developer: "Xiaomi MiMo",
            repo: "bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF",
            license: "MIT",
            released: "September 2026",
            summary: "Xiaomi's distillation of MiMo-V2.6 into Qwen3.5-9B, with large gains on coding and agentic benchmarks.",
            qualityScore: 79,
            tags: ["Reasoning", "Coding"],
            facts: ArchitectureFacts(
                architecture: "qwen35", layers: 32, kvElementsFull: 16_384, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 52_690_944,
                embeddingLength: 4_096, vocabSize: 248_320, trainContext: 262_144,
                parameters: 9.4, activeParameters: 9.4, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ4_XS", fileName: "MiMo-V2.6-Distill-Qwen-9B-IQ4_XS.gguf", sizeBytes: 5_227_304_480, sha256: "eccfbc188e71dec8350fbdd5af898d2a50691ac67e077327c52baa9da1e91d90"),
                CatalogVariant(quant: "Q4_0", fileName: "MiMo-V2.6-Distill-Qwen-9B-Q4_0.gguf", sizeBytes: 5_482_829_344, sha256: "0dadc6593e5fe790a510fcb7fcd1dc6993664db562b2e8ec7b34825e99d52f4f"),
                CatalogVariant(quant: "Q4_K_M", fileName: "MiMo-V2.6-Distill-Qwen-9B-Q4_K_M.gguf", sizeBytes: 5_841_049_120, sha256: "4bca6f18c73f72270c7a20c2ea2bea581de8246e318714277120369d34048c81"),
                CatalogVariant(quant: "Q5_K_M", fileName: "MiMo-V2.6-Distill-Qwen-9B-Q5_K_M.gguf", sizeBytes: 6_876_124_704, sha256: "04cf46f2b5584ef922697d6c063f94879434fb86c467f1a09e52daf0cddaf35f"),
                CatalogVariant(quant: "Q6_K", fileName: "MiMo-V2.6-Distill-Qwen-9B-Q6_K.gguf", sizeBytes: 7_793_710_624, sha256: "ef96d05a2ddf2cbb450d1af1ac3860ec769d3575bafa70692ee5609bda3fad7d"),
                CatalogVariant(quant: "Q8_0", fileName: "MiMo-V2.6-Distill-Qwen-9B-Q8_0.gguf", sizeBytes: 9_545_979_424, sha256: "2fad0aa11bb9e7aa491ff12f768954f9dd0a6e7d4ce4a897ca73ec420f3b90ae")
            ],
            projector: CatalogProjector(repo: "bartowski/MiMo-V2.6-Distill-Qwen-9B-GGUF", fileName: "mmproj-MiMo-V2.6-Distill-Qwen-9B-f16.gguf",
                                        sizeBytes: 918_166_048, sha256: "ff348f3180a63188aa7285db85f550fe38acb61dd013c599eb8bad08d2cc2576")
        ),
        CatalogModel(
            id: "granite-4.2-8b",
            name: "Granite 4.2 8B",
            developer: "IBM",
            repo: "ibm-granite/granite-4.2-8b-GGUF",
            license: "Apache 2.0",
            released: "August 2026",
            summary: "IBM's 8B reasoning model with strong math and tool-use results and a low-effort reasoning mode.",
            qualityScore: 72,
            tags: ["Reasoning", "Dense"],
            facts: ArchitectureFacts(
                architecture: "granite", layers: 40, kvElementsFull: 81_920, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 4_096, vocabSize: 100_352, trainContext: 131_072,
                parameters: 8.8, activeParameters: 8.8, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "Q4_0", fileName: "granite-4.2-8b-Q4_0.gguf", sizeBytes: 5_055_955_072, sha256: "82af51c80f8c2913430aa020f97bd3d4708c5fc49c5bfbff09ac012f3c2132d2"),
                CatalogVariant(quant: "Q4_K_M", fileName: "granite-4.2-8b-Q4_K_M.gguf", sizeBytes: 5_347_917_952, sha256: "16a9369d0805f80b7377d25d87f937a90c05dc04ad79173a52001e42c9aab311"),
                CatalogVariant(quant: "Q5_K_M", fileName: "granite-4.2-8b-Q5_K_M.gguf", sizeBytes: 6_253_887_616, sha256: "074ac7ee98b1703674657a65051caebe188d543656e0ad71eb1f6bb3ae063407"),
                CatalogVariant(quant: "Q6_K", fileName: "granite-4.2-8b-Q6_K.gguf", sizeBytes: 7_216_480_384, sha256: "5ad3d67f6fe09a448031029bead7f6a088697ca2787c0c5640bf964c59df1a21"),
                CatalogVariant(quant: "Q8_0", fileName: "granite-4.2-8b-Q8_0.gguf", sizeBytes: 9_345_613_952, sha256: "fb66ad5750680c77c76b9dc095961375f14fc88ba15fd5fc084ef6e6701bad77")
            ]
        ),
        CatalogModel(
            id: "qwen3.5-4b",
            name: "Qwen3.5 4B",
            developer: "Qwen (Alibaba)",
            repo: "bartowski/Qwen_Qwen3.5-4B-GGUF",
            license: "Apache 2.0",
            released: "February 2026",
            summary: "The best general-knowledge and reasoning model around 4B parameters. An excellent everyday choice on iPhone.",
            qualityScore: 70,
            tags: ["Reasoning", "Efficient"],
            facts: ArchitectureFacts(
                architecture: "qwen35", layers: 33, kvElementsFull: 16_384, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 54_886_400,
                embeddingLength: 2_560, vocabSize: 248_320, trainContext: 262_144,
                parameters: 4.7, activeParameters: 4.7, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ4_XS", fileName: "Qwen_Qwen3.5-4B-IQ4_XS.gguf", sizeBytes: 2_671_339_488, sha256: "628124c61a806897d3f28dcd416be6daff94f62f731eb900d4381875eac9e412"),
                CatalogVariant(quant: "Q4_0", fileName: "Qwen_Qwen3.5-4B-Q4_0.gguf", sizeBytes: 2_776_033_248, sha256: "3e977de32dfb9377ff827f210091cce5d3c05c7b0f0b9b0c8005df7c0677a49b"),
                CatalogVariant(quant: "Q4_K_M", fileName: "Qwen_Qwen3.5-4B-Q4_K_M.gguf", sizeBytes: 3_013_027_808, sha256: "13c16f426047e2de38cd075bdade4a7bcbc8c774384876f677740cda65f8a983"),
                CatalogVariant(quant: "Q5_K_M", fileName: "Qwen_Qwen3.5-4B-Q5_K_M.gguf", sizeBytes: 3_443_763_168, sha256: "21c4643259ce62ffd979848e5819ce03823fd9e9902279ab54cc0d572d83d33e"),
                CatalogVariant(quant: "Q6_K", fileName: "Qwen_Qwen3.5-4B-Q6_K.gguf", sizeBytes: 3_805_358_048, sha256: "5a5bc7a3f9375b395e9f81fb69109038cf160c84606b8192f13cbb8355ca59f2"),
                CatalogVariant(quant: "Q8_0", fileName: "Qwen_Qwen3.5-4B-Q8_0.gguf", sizeBytes: 4_622_131_168, sha256: "5c74c0ede371924357dff0cb6ba145bd67208b9b2389ded681adfff3f7608db7")
            ],
            projector: CatalogProjector(repo: "bartowski/Qwen_Qwen3.5-4B-GGUF", fileName: "mmproj-Qwen_Qwen3.5-4B-f16.gguf",
                                        sizeBytes: 672_423_488, sha256: "659b59dd44b73b1cd34af6cc424669484b06dc80f4340adf8ea84ad776eef813")
        ),
        CatalogModel(
            id: "nemotron-3.5-bolt-e4b",
            name: "NVIDIA Nemotron 3.5 Bolt E4B",
            developer: "NVIDIA",
            repo: "bartowski/NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF",
            license: "OpenMDW 1.1",
            released: "October 2026",
            summary: "NVIDIA's chat-tuned Gemma 4 E4B, focused on natural conversation and instruction following.",
            qualityScore: 66,
            tags: ["Conversation", "Efficient"],
            facts: ArchitectureFacts(
                architecture: "gemma4", layers: 42, kvElementsFull: 8_192, kvElementsSliding: 20_480,
                slidingWindow: 512, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 2_560, vocabSize: 262_144, trainContext: 65_536,
                parameters: 8, activeParameters: 4.5, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ4_XS", fileName: "NVIDIA-Nemotron-3.5-Bolt-E4B-IQ4_XS.gguf", sizeBytes: 4_770_131_296, sha256: "7874aa84419f61b3ced4cbe762a171ccc3d2930381bf58fd0685dde888e89d46"),
                CatalogVariant(quant: "Q4_K_M", fileName: "NVIDIA-Nemotron-3.5-Bolt-E4B-Q4_K_M.gguf", sizeBytes: 5_162_292_576, sha256: "5f0f982d11bc1408783d13e4440b06e6c1e989024ac26f9a2999cb4c496bedcc"),
                CatalogVariant(quant: "Q4_0", fileName: "NVIDIA-Nemotron-3.5-Bolt-E4B-Q4_0.gguf", sizeBytes: 5_223_863_648, sha256: "576045a32183bd9945ecf4b7b007592da8eaa9f277beb7de566101571b1b6628"),
                CatalogVariant(quant: "Q5_K_M", fileName: "NVIDIA-Nemotron-3.5-Bolt-E4B-Q5_K_M.gguf", sizeBytes: 5_983_548_768, sha256: "58e25be8678a32cc28d9f31400d41759ee1f1cdd24e7133d87f49a7089a654d7"),
                CatalogVariant(quant: "Q6_K", fileName: "NVIDIA-Nemotron-3.5-Bolt-E4B-Q6_K.gguf", sizeBytes: 6_448_997_728, sha256: "e372a90ea52b410fcd782a5a91caccb081f77389965dd7aae3620482760e1e98"),
                CatalogVariant(quant: "Q8_0", fileName: "NVIDIA-Nemotron-3.5-Bolt-E4B-Q8_0.gguf", sizeBytes: 8_031_245_664, sha256: "05d749c477d716a4c6cce6bfcff319c71c390826b859cdc2f14291ab7832ca44")
            ],
            projector: CatalogProjector(repo: "bartowski/NVIDIA-Nemotron-3.5-Bolt-E4B-GGUF", fileName: "mmproj-NVIDIA-Nemotron-3.5-Bolt-E4B-f16.gguf",
                                        sizeBytes: 990_373_664, sha256: "64c6e621ee6a791765ad251f808b3981da5a1722c52b0ed473f0e4156617e6e2")
        ),
        CatalogModel(
            id: "gemma-4-e4b-it",
            name: "Gemma 4 E4B IT",
            developer: "Google DeepMind",
            repo: "bartowski/google_gemma-4-E4B-it-GGUF",
            license: "Apache 2.0",
            released: "April 2026",
            summary: "Gemma 4 with 4.5B effective parameters, designed for phones and tablets.",
            qualityScore: 64,
            tags: ["Efficient", "Optional reasoning"],
            facts: ArchitectureFacts(
                architecture: "gemma4", layers: 42, kvElementsFull: 8_192, kvElementsSliding: 20_480,
                slidingWindow: 512, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 2_560, vocabSize: 262_144, trainContext: 131_072,
                parameters: 8, activeParameters: 4.5, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ4_XS", fileName: "google_gemma-4-E4B-it-IQ4_XS.gguf", sizeBytes: 5_112_828_384, sha256: "a24429604e6f680e7bdf087b863a6cecc90f80b3d908f95d888f4f05003fdee3"),
                CatalogVariant(quant: "Q4_0", fileName: "google_gemma-4-E4B-it-Q4_0.gguf", sizeBytes: 5_223_860_704, sha256: "604e903d29d2e0bbcee3dad449adc3e022299bf8a2d1dc7bc0166470e88d2203"),
                CatalogVariant(quant: "Q4_K_M", fileName: "google_gemma-4-E4B-it-Q4_K_M.gguf", sizeBytes: 5_405_170_144, sha256: "d35a3aa7a6d47de237fd488bb6f7f3efd62908d828f85a63da0ee93acdbefe9f"),
                CatalogVariant(quant: "Q5_K_M", fileName: "google_gemma-4-E4B-it-Q5_K_M.gguf", sizeBytes: 5_820_883_424, sha256: "1c57b87a06a7c0fd1b9fa8f5d5e505b720c15099648e0dcdc78acd857f72a7cc"),
                CatalogVariant(quant: "Q6_K", fileName: "google_gemma-4-E4B-it-Q6_K.gguf", sizeBytes: 6_329_954_784, sha256: "bea1c94443c91fff61a722d9da5cd3f1cf0196d1e914798ee89d3c00ea365df9"),
                CatalogVariant(quant: "Q8_0", fileName: "google_gemma-4-E4B-it-Q8_0.gguf", sizeBytes: 8_031_242_720, sha256: "6a6eba0d36a051b5d924211a889c1436717006e7c5d413830c47caa1d46cb598")
            ],
            projector: CatalogProjector(repo: "ggml-org/gemma-4-E4B-it-GGUF", fileName: "mmproj-gemma-4-E4B-it-Q8_0.gguf",
                                        sizeBytes: 559_874_816, sha256: "197f49a93027f9843772bd24a6a9e0be2a32a788de5a3def330e9c585d86edd1")
        ),
        CatalogModel(
            id: "granite-4.2-3b",
            name: "Granite 4.2 3B",
            developer: "IBM",
            repo: "ibm-granite/granite-4.2-3b-GGUF",
            license: "Apache 2.0",
            released: "August 2026",
            summary: "Compact IBM reasoning model that tops independent rankings for models under 4B.",
            qualityScore: 60,
            tags: ["Reasoning", "Efficient"],
            facts: ArchitectureFacts(
                architecture: "granite", layers: 40, kvElementsFull: 40_960, kvElementsSliding: 0,
                slidingWindow: 0, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 2_560, vocabSize: 100_352, trainContext: 131_072,
                parameters: 3.7, activeParameters: 3.7, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "Q4_0", fileName: "granite-4.2-3b-Q4_0.gguf", sizeBytes: 2_129_118_752, sha256: "d34a4a7c0b230d3f544eca502beb7e04efc3a0ebd59e2f2df50058f23cc20711"),
                CatalogVariant(quant: "Q4_K_M", fileName: "granite-4.2-3b-Q4_K_M.gguf", sizeBytes: 2_244_011_552, sha256: "e0406663965846ae22a403456eb826ccce5f450840491f71952f18a7cb78e7d5"),
                CatalogVariant(quant: "Q5_K_M", fileName: "granite-4.2-3b-Q5_K_M.gguf", sizeBytes: 2_613_634_592, sha256: "982e797413f842329266a00c2a85ce540bb5c1b65ac4646276bfb9d2886c5efe"),
                CatalogVariant(quant: "Q6_K", fileName: "granite-4.2-3b-Q6_K.gguf", sizeBytes: 3_006_359_072, sha256: "2e08e2790489162105be79b7f26a81fde28ea30119fa6df12594acd59f12dd96"),
                CatalogVariant(quant: "Q8_0", fileName: "granite-4.2-3b-Q8_0.gguf", sizeBytes: 3_892_651_552, sha256: "fbe986738041418e26de9e123ba740cb654931f85bf572a71bd01f9e6b85e53d")
            ]
        ),
        CatalogModel(
            id: "lfm3-1.7b",
            name: "LFM3 1.7B",
            developer: "Liquid AI",
            repo: "LiquidAI/LFM3-1.7B-GGUF",
            license: "LFM Open License 1.0",
            released: "October 2026",
            summary: "Liquid AI tri-hybrid model under 2 GB with a 262K context. Extremely fast; best for quick tasks and drafts.",
            qualityScore: 55,
            tags: ["Fastest", "Reasoning"],
            facts: ArchitectureFacts(
                architecture: "lfm3", layers: 24, kvElementsFull: 6_144, kvElementsSliding: 5_120,
                slidingWindow: 256, kvLoraRank: 0, recurrentStateBytes: 745_472,
                embeddingLength: 2_048, vocabSize: 128_000, trainContext: 262_144,
                parameters: 1.7, activeParameters: 1.7, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "QAD-Q4_0", fileName: "LFM3-1.7B-QAD-Q4_0.gguf", sizeBytes: 1_049_615_680, sha256: "43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452"),
                CatalogVariant(quant: "Q4_K_M", fileName: "LFM3-1.7B-Q4_K_M.gguf", sizeBytes: 1_099_627_808, sha256: "3793e1e6e2266919d6e015287221b41100175a98eddaba92e111aed3b05c93c4"),
                CatalogVariant(quant: "Q5_K_M", fileName: "LFM3-1.7B-Q5_K_M.gguf", sizeBytes: 1_258_663_200, sha256: "41e51fb0be5f472d323055f2734d986d5a2429570973508fa6322f3f07f6d7f3"),
                CatalogVariant(quant: "Q6_K", fileName: "LFM3-1.7B-Q6_K.gguf", sizeBytes: 1_427_638_304, sha256: "54e1bd947c77167823d45bf495f1c3e2d226ca7fb242f83cfa141ee3a6ab55c6"),
                CatalogVariant(quant: "Q8_0", fileName: "LFM3-1.7B-Q8_0.gguf", sizeBytes: 1_846_238_496, sha256: "8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6")
            ]
        ),
        CatalogModel(
            id: "gemma-4-e2b-it",
            name: "Gemma 4 E2B IT",
            developer: "Google DeepMind",
            repo: "bartowski/google_gemma-4-E2B-it-GGUF",
            license: "Apache 2.0",
            released: "April 2026",
            summary: "The smallest Gemma 4 (2.3B effective parameters) for the quickest responses.",
            qualityScore: 54,
            tags: ["Fastest", "Efficient"],
            facts: ArchitectureFacts(
                architecture: "gemma4", layers: 35, kvElementsFull: 3_072, kvElementsSliding: 6_144,
                slidingWindow: 512, kvLoraRank: 0, recurrentStateBytes: 0,
                embeddingLength: 1_536, vocabSize: 262_144, trainContext: 131_072,
                parameters: 5.1, activeParameters: 2.3, thinkingToggle: true),
            variants: [
                CatalogVariant(quant: "IQ4_XS", fileName: "google_gemma-4-E2B-it-IQ4_XS.gguf", sizeBytes: 3_324_311_008, sha256: "41326b0d673997e4791153a96f6e452bc70460a760ed92994c24ca187ae8c6c2"),
                CatalogVariant(quant: "Q4_0", fileName: "google_gemma-4-E2B-it-Q4_0.gguf", sizeBytes: 3_378_740_704, sha256: "2d9a803a627ee94230dc23681008ae340d9785a2374e2a6a0c8d69c7ee7ea47e"),
                CatalogVariant(quant: "Q4_K_M", fileName: "google_gemma-4-E2B-it-Q4_K_M.gguf", sizeBytes: 3_462_680_032, sha256: "923c4c86177d2ee173a7f5b4fa3d0ac65f5962ab15e6d6a5bc250aec4fd7bf7e"),
                CatalogVariant(quant: "Q5_K_M", fileName: "google_gemma-4-E2B-it-Q5_K_M.gguf", sizeBytes: 3_658_384_864, sha256: "e0400afe4c2cc8069238bff9f6e990cd4e087f76aa8fc35a6f076874d0d6dac7"),
                CatalogVariant(quant: "Q6_K", fileName: "google_gemma-4-E2B-it-Q6_K.gguf", sizeBytes: 3_898_486_240, sha256: "d7ea8cdd30d8e15bf11e5a37e8c141a600ad161d847165591fe86ab0288fb9d4"),
                CatalogVariant(quant: "Q8_0", fileName: "google_gemma-4-E2B-it-Q8_0.gguf", sizeBytes: 4_967_497_184, sha256: "bb145c0e8c2ede3b6992b881f7eefe6b33275eeb9998f450b5c72f4eb1d78732")
            ],
            projector: CatalogProjector(repo: "ggml-org/gemma-4-E2B-it-GGUF", fileName: "mmproj-gemma-4-E2B-it-Q8_0.gguf",
                                        sizeBytes: 557_368_064, sha256: "9406f99c16d68cda4f1f0552192dcc99021ea1fc6d2fd50b1dc3ccf30d04b292")
        )
    ]
}
