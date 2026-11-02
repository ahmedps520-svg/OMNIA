import Foundation
import Testing
@testable import OMNIA

// MARK: - GGUF

struct GGUFParserTests {
    /// Builds a minimal GGUF v3 header with the given scalar metadata.
    private func header(_ entries: [(String, UInt32, Data)], tensorCount: UInt64 = 0) -> Data {
        var data = Data("GGUF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(3).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: tensorCount.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt64(entries.count).littleEndian) { Array($0) })
        for (key, type, value) in entries {
            data.append(contentsOf: withUnsafeBytes(of: UInt64(key.utf8.count).littleEndian) { Array($0) })
            data.append(Data(key.utf8))
            data.append(contentsOf: withUnsafeBytes(of: type.littleEndian) { Array($0) })
            data.append(value)
        }
        return data
    }

    private func string(_ text: String) -> Data {
        var data = Data(withUnsafeBytes(of: UInt64(text.utf8.count).littleEndian) { Array($0) })
        data.append(Data(text.utf8))
        return data
    }

    private func u32(_ value: UInt32) -> Data { Data(withUnsafeBytes(of: value.littleEndian) { Array($0) }) }

    @Test func parsesArchitectureFacts() throws {
        let data = header([
            ("general.architecture", 8, string("llama")),
            ("llama.block_count", 4, u32(32)),
            ("llama.context_length", 4, u32(8192)),
            ("llama.embedding_length", 4, u32(4096)),
            ("llama.attention.head_count", 4, u32(32)),
            ("llama.attention.head_count_kv", 4, u32(8)),
            ("general.file_type", 4, u32(15))
        ])
        let parsed = try GGUFParser.parse(data)
        let info = try GGUFModelInfo(header: parsed)
        #expect(info.architecture == "llama")
        #expect(info.blockCount == 32)
        #expect(info.contextLength == 8192)
        #expect(info.headCountKVPerLayer?.count == 32)
        #expect(info.headDimension == 128)
        #expect(info.quantizationLabel == "Q4_K_M")

        let facts = ArchitectureFacts(info: info, fileSize: 4_900_000_000)
        // 32 layers × 8 KV heads × (128 + 128) elements per token.
        #expect(facts.kvElementsFull == 32 * 8 * 256)
        #expect(facts.kvElementsSliding == 0)
    }

    @Test func rejectsNonGGUF() {
        #expect(throws: GGUFError.notGGUF) { try GGUFParser.parse(Data("NOPE0000000000000000000000".utf8)) }
    }

    @Test func asksForMoreDataWhenTruncated() throws {
        let data = header([("general.architecture", 8, string("qwen35"))])
        #expect(throws: (any Error).self) { try GGUFParser.parse(data.prefix(data.count - 3)) }
    }

    @Test func hybridLayersOnlyCountFullAttention() throws {
        let data = header([
            ("general.architecture", 8, string("qwen35")),
            ("qwen35.block_count", 4, u32(32)),
            ("qwen35.attention.head_count", 4, u32(16)),
            ("qwen35.attention.head_count_kv", 4, u32(4)),
            ("qwen35.attention.key_length", 4, u32(256)),
            ("qwen35.attention.value_length", 4, u32(256)),
            ("qwen35.full_attention_interval", 4, u32(4)),
            ("qwen35.ssm.inner_size", 4, u32(4096)),
            ("qwen35.ssm.state_size", 4, u32(128)),
            ("qwen35.ssm.group_count", 4, u32(16)),
            ("qwen35.ssm.conv_kernel", 4, u32(4))
        ])
        let info = try GGUFModelInfo(header: GGUFParser.parse(data))
        let facts = ArchitectureFacts(info: info, fileSize: 6_000_000_000)
        // Every 4th layer is full attention: 8 layers × 4 heads × 512.
        #expect(facts.kvElementsFull == 8 * 4 * 512)
        #expect(facts.recurrentStateBytes > 0)
    }
}

// MARK: - Streaming text

struct UTF8StreamDecoderTests {
    @Test func holdsBackIncompleteSequences() {
        var decoder = UTF8StreamDecoder()
        let emoji = Array("🙂".utf8) // 4 bytes
        #expect(decoder.append(Array(emoji.prefix(2))) == "")
        #expect(decoder.append(Array(emoji.suffix(2)) + Array(" ok".utf8)) == "🙂 ok")
        #expect(decoder.flush() == "")
    }

    @Test func passesASCIIThrough() {
        var decoder = UTF8StreamDecoder()
        #expect(decoder.append(Array("Hello".utf8)) == "Hello")
    }
}

// MARK: - Reasoning

struct ReasoningParserTests {
    @Test func thinkTags() {
        let parsed = ReasoningParser.parse("<think>Plan the answer.</think>\n\nThe answer is 4.")
        #expect(parsed.reasoning == "Plan the answer.")
        #expect(parsed.content == "The answer is 4.")
        #expect(!parsed.isReasoning)
    }

    @Test func templateOpenedThinkBlockStreams() {
        let partial = ReasoningParser.parse("Still working it out", opensInReasoning: true)
        #expect(partial.isReasoning)
        #expect(partial.content.isEmpty)
        let done = ReasoningParser.parse("Worked it out</think>Done.", opensInReasoning: true)
        #expect(done.reasoning == "Worked it out")
        #expect(done.content == "Done.")
    }

    @Test func gemmaThoughtChannel() {
        let parsed = ReasoningParser.parse("<|channel>thought\nCheck units.<channel|>It is 12 km.")
        #expect(parsed.reasoning == "Check units.")
        #expect(parsed.content == "It is 12 km.")
    }

    @Test func harmonyChannels() {
        let raw = "<|channel|>analysis<|message|>User wants a haiku.<|end|><|start|>assistant<|channel|>final<|message|>Quiet silicon"
        let parsed = ReasoningParser.parse(raw)
        #expect(parsed.reasoning == "User wants a haiku.")
        #expect(parsed.content == "Quiet silicon")
    }

    @Test func addressedMessages() {
        let raw = " to=self<|message|>Think first.<|eom|><|start|>assistant<|message|>Answer.<|eot|>"
        let parsed = ReasoningParser.parse(raw)
        #expect(parsed.reasoning == "Think first.")
        #expect(parsed.content == "Answer.")
    }

    @Test func plainTextIsContent() {
        let parsed = ReasoningParser.parse("Just an answer.")
        #expect(parsed.reasoning == nil)
        #expect(parsed.content == "Just an answer.")
    }
}

// MARK: - Markdown

struct MarkdownParserTests {
    @Test func parsesCommonBlocks() {
        let text = """
        # Title

        A paragraph with **bold** text.

        - one
        - two

        ```swift
        let x = 1
        ```

        | A | B |
        |---|--:|
        | 1 | 2 |
        """
        let blocks = MarkdownParser.parse(text)
        #expect(blocks.count == 5)
        #expect(blocks[0] == .heading(level: 1, text: "Title"))
        if case let .list(items) = blocks[2] { #expect(items.count == 2) } else { Issue.record("expected list") }
        #expect(blocks[3] == .code(language: "swift", code: "let x = 1", isClosed: true))
        if case let .table(header, alignments, rows) = blocks[4] {
            #expect(header == ["A", "B"])
            #expect(alignments == [.leading, .trailing])
            #expect(rows == [["1", "2"]])
        } else {
            Issue.record("expected table")
        }
    }

    @Test func unclosedFenceWhileStreaming() {
        let blocks = MarkdownParser.parse("```python\nprint(1)")
        #expect(blocks == [.code(language: "python", code: "print(1)", isClosed: false)])
    }
}

// MARK: - Memory planning

struct MemoryPlannerTests {
    private let facts = ArchitectureFacts(architecture: "llama", layers: 32, kvElementsFull: 32 * 8 * 256,
                                          embeddingLength: 4096, vocabSize: 128_256, trainContext: 131_072,
                                          parameters: 8.0)

    @Test func kvCacheScalesWithContextAndPrecision() {
        let f16 = MemoryPlanner.kvCacheBytes(facts, context: 8192, kv: .f16)
        let q8 = MemoryPlanner.kvCacheBytes(facts, context: 8192, kv: .q8_0)
        #expect(f16 == UInt64(32 * 8 * 256 * 8192 * 2))   // 1 GiB
        #expect(q8 < f16 && q8 > f16 / 2)
        #expect(MemoryPlanner.kvCacheBytes(facts, context: 16_384, kv: .f16) == f16 * 2)
    }

    @Test func planQuantizesCacheBeforeShorteningContext() {
        let size: UInt64 = 4_900_000_000
        let f16 = MemoryPlanner.estimate(facts, fileSize: size, context: 32_768, kv: .f16)
        // Room for the Q8 cache at 32K but not the F16 one.
        let allowance = MemoryAllowance(resident: f16.total - 512 << 20, footprint: .max)
        let plan = MemoryPlanner.plan(facts, fileSize: size, requestedContext: 32_768, kvChoice: .automatic,
                                      profile: .iPadQuality, allowance: allowance)
        #expect(plan.fits)
        #expect(plan.contextLength == 32_768)
        #expect(plan.kvType == .q8_0)
    }

    @Test func refusesModelsThatCannotFit() {
        let allowance = MemoryAllowance(resident: 2 << 30, footprint: 2 << 30)
        let plan = MemoryPlanner.plan(facts, fileSize: 9_000_000_000, requestedContext: nil, kvChoice: .automatic,
                                      profile: .iPhoneEfficiency, allowance: allowance)
        #expect(!plan.fits)
    }

    @Test func slidingWindowLayersStopGrowing() {
        let windowed = ArchitectureFacts(architecture: "gemma4", layers: 48, kvElementsFull: 8_192, kvElementsSliding: 163_840,
                                         slidingWindow: 1024, embeddingLength: 3840, vocabSize: 262_144,
                                         trainContext: 131_072, parameters: 12)
        let short = MemoryPlanner.kvCacheBytes(windowed, context: 16_384, kv: .f16)
        let long = MemoryPlanner.kvCacheBytes(windowed, context: 32_768, kv: .f16)
        // Doubling the context only doubles the global-layer part.
        #expect(long - short == UInt64(8_192 * 16_384 * 2))
    }
}

// MARK: - Quantization labels

struct QuantizationTests {
    @Test func extractsLabelsFromFileNames() {
        #expect(QuantizationInfo.label(fromFileName: "Qwen_Qwen3.5-9B-Q4_K_M.gguf") == "Q4_K_M")
        #expect(QuantizationInfo.label(fromFileName: "Qwen3.8-27B-UD-IQ3_XXS.gguf") == "IQ3_XXS")
        #expect(QuantizationInfo.label(fromFileName: "gpt-oss-20b-MXFP4.gguf") == "MXFP4")
        #expect(QuantizationInfo.label(fromFileName: "model-Q8_0.gguf") == "Q8_0")
    }

    @Test func penaltyGrowsAsBitsShrink() {
        #expect(QuantizationInfo.qualityPenalty(bitsPerWeight: 8.5) == 0)
        #expect(QuantizationInfo.qualityPenalty(bitsPerWeight: 4.85) < QuantizationInfo.qualityPenalty(bitsPerWeight: 3.1))
    }
}

// MARK: - Retrieval

struct RetrievalTests {
    @Test func findsRelevantChunk() {
        let text = (1...20).map { "Paragraph \($0) talks about weather and gardens." }.joined(separator: "\n\n")
            + "\n\nThe launch code for the rocket engine is stored in the vault."
        let chunks = Retrieval.chunk(text, title: "Doc", targetCharacters: 200, overlap: 0)
        let hits = Retrieval.search("rocket engine vault", in: chunks, limit: 1, characterBudget: 1_000)
        #expect(hits.first?.text.contains("rocket engine") == true)
    }
}
