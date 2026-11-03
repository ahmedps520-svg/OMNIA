import Foundation

/// Minimal, allocation-conscious reader for the GGUF container format (v2/v3).
///
/// OMNIA reads GGUF metadata in three places:
///  - verifying downloaded/imported files before they are registered,
///  - estimating runtime memory (layer count, KV heads, head size, sliding window…),
///  - inspecting remote files on Hugging Face via HTTP range requests *before* downloading.
///
/// The parser works on a prefix of the file. When the prefix ends before the metadata
/// section does, it throws `GGUFError.needMoreData` so callers can fetch a larger prefix.
enum GGUFError: LocalizedError, Equatable {
    case notGGUF
    case unsupportedVersion(UInt32)
    case needMoreData(minimum: Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notGGUF: "The file is not a GGUF model (missing GGUF signature)."
        case .unsupportedVersion(let v): "Unsupported GGUF version \(v)."
        case .needMoreData: "The GGUF header is larger than the bytes read so far."
        case .malformed(let reason): "The GGUF header is malformed: \(reason)."
        }
    }
}

enum GGUFValueType: UInt32, Sendable {
    case uint8 = 0, int8 = 1, uint16 = 2, int16 = 3, uint32 = 4, int32 = 5
    case float32 = 6, bool = 7, string = 8, array = 9, uint64 = 10, int64 = 11, float64 = 12

    var fixedSize: Int? {
        switch self {
        case .uint8, .int8, .bool: 1
        case .uint16, .int16: 2
        case .uint32, .int32, .float32: 4
        case .uint64, .int64, .float64: 8
        case .string, .array: nil
        }
    }
}

enum GGUFValue: Hashable, Sendable {
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case bool(Bool)
    case string(String)
    /// Arrays keep their element count always; element values only when small enough to be useful.
    case array(elementType: GGUFValueType, count: Int, values: [GGUFValue]?)

    var intValue: Int? {
        switch self {
        case .int(let v): Int(exactly: v)
        case .uint(let v): Int(exactly: v)
        case .float(let v): Int(exactly: v.rounded())
        case .bool(let v): v ? 1 : 0
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .int(let v): Double(v)
        case .uint(let v): Double(v)
        case .float(let v): v
        default: nil
        }
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let v): v != 0
        case .uint(let v): v != 0
        default: nil
        }
    }

    var arrayCount: Int? {
        if case .array(_, let count, _) = self { return count }
        return nil
    }

    var intArray: [Int]? {
        guard case .array(_, _, let values?) = self else { return nil }
        let ints = values.compactMap(\.intValue)
        return ints.count == values.count ? ints : nil
    }

    var boolArray: [Bool]? {
        guard case .array(_, _, let values?) = self else { return nil }
        let bools = values.compactMap(\.boolValue)
        return bools.count == values.count ? bools : nil
    }
}

struct GGUFTensorSummary: Hashable, Sendable {
    var count: Int = 0
    var totalElements: UInt64 = 0
    /// Elements in mixture-of-experts tensors (names containing "_exps").
    var expertElements: UInt64 = 0
}

struct GGUFHeader: Sendable {
    let version: UInt32
    let tensorCount: UInt64
    let metadata: [String: GGUFValue]
    /// Present when the prefix also covered the tensor-info table.
    let tensors: GGUFTensorSummary?
    /// Bytes consumed by the fixed header and the metadata section.
    let metadataByteCount: Int
}

struct GGUFParser {
    static let magic: [UInt8] = [0x47, 0x47, 0x55, 0x46] // "GGUF"

    /// Arrays up to this length keep their numeric/bool values (per-layer hyper-parameters).
    private static let maxStoredArrayCount = 4096
    /// Strings longer than this are skipped (chat templates are well below it).
    private static let maxStoredStringBytes = 256 * 1024

    /// Parses metadata (and the tensor-info table when `includeTensors` and the prefix allows).
    static func parse(_ data: Data, includeTensors: Bool = true) throws -> GGUFHeader {
        try data.withUnsafeBytes { raw -> GGUFHeader in
            var cursor = Cursor(buffer: raw)
            guard raw.count >= 4 else { throw GGUFError.needMoreData(minimum: 24) }
            guard Array(raw.prefix(4)) == magic else { throw GGUFError.notGGUF }
            cursor.offset = 4
            let version: UInt32 = try cursor.read()
            guard version == 2 || version == 3 else { throw GGUFError.unsupportedVersion(version) }
            let tensorCount: UInt64 = try cursor.read()
            let kvCount: UInt64 = try cursor.read()
            guard kvCount < 1_000_000, tensorCount < 10_000_000 else {
                throw GGUFError.malformed("implausible counts")
            }

            var metadata: [String: GGUFValue] = [:]
            metadata.reserveCapacity(Int(kvCount))
            for _ in 0..<kvCount {
                let key = try cursor.readString(maxStored: 4096) ?? ""
                let rawType: UInt32 = try cursor.read()
                guard let type = GGUFValueType(rawValue: rawType) else {
                    throw GGUFError.malformed("unknown value type \(rawType) for key \(key)")
                }
                metadata[key] = try cursor.readValue(type, depth: 0)
            }
            let metadataEnd = cursor.offset

            var summary: GGUFTensorSummary?
            if includeTensors {
                // The tensor table is optional for our purposes: stop quietly if it is truncated.
                var tensorCursor = cursor
                var s = GGUFTensorSummary()
                var complete = true
                do {
                    for _ in 0..<tensorCount {
                        let name = try tensorCursor.readString(maxStored: 512) ?? ""
                        let nDims: UInt32 = try tensorCursor.read()
                        guard nDims <= 8 else { throw GGUFError.malformed("tensor rank \(nDims)") }
                        var elements: UInt64 = 1
                        for _ in 0..<nDims {
                            let dim: UInt64 = try tensorCursor.read()
                            elements = elements.multipliedReportingOverflow(by: max(dim, 1)).partialValue
                        }
                        let _: UInt32 = try tensorCursor.read() // ggml type
                        let _: UInt64 = try tensorCursor.read() // data offset
                        s.count += 1
                        s.totalElements &+= elements
                        if name.contains("_exps") { s.expertElements &+= elements }
                    }
                } catch GGUFError.needMoreData {
                    complete = false
                }
                if complete { summary = s }
            }

            return GGUFHeader(version: version, tensorCount: tensorCount, metadata: metadata,
                              tensors: summary, metadataByteCount: metadataEnd)
        }
    }

    // MARK: Cursor

    private struct Cursor {
        let buffer: UnsafeRawBufferPointer
        var offset: Int = 0

        mutating func require(_ n: Int) throws {
            if n < 0 || offset + n > buffer.count {
                throw GGUFError.needMoreData(minimum: max(buffer.count * 2, offset + max(n, 0) + 1))
            }
        }

        mutating func read<T: FixedWidthInteger>() throws -> T {
            try require(MemoryLayout<T>.size)
            let v = buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
            offset += MemoryLayout<T>.size
            return T(littleEndian: v)
        }

        mutating func readFloat32() throws -> Float {
            let bits: UInt32 = try read()
            return Float(bitPattern: bits)
        }

        mutating func readFloat64() throws -> Double {
            let bits: UInt64 = try read()
            return Double(bitPattern: bits)
        }

        /// Reads a GGUF string. Returns nil (but still advances) when longer than `maxStored`.
        mutating func readString(maxStored: Int) throws -> String? {
            let length: UInt64 = try read()
            guard length < UInt64(Int32.max) else { throw GGUFError.malformed("string length \(length)") }
            let n = Int(length)
            try require(n)
            defer { offset += n }
            guard n <= maxStored else { return nil }
            let slice = UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + n)])
            return String(decoding: slice, as: UTF8.self)
        }

        mutating func skipString() throws {
            let length: UInt64 = try read()
            guard length < UInt64(Int32.max) else { throw GGUFError.malformed("string length \(length)") }
            try require(Int(length))
            offset += Int(length)
        }

        mutating func readValue(_ type: GGUFValueType, depth: Int) throws -> GGUFValue {
            switch type {
            case .uint8: return .uint(UInt64(try read() as UInt8))
            case .int8: return .int(Int64(try read() as Int8))
            case .uint16: return .uint(UInt64(try read() as UInt16))
            case .int16: return .int(Int64(try read() as Int16))
            case .uint32: return .uint(UInt64(try read() as UInt32))
            case .int32: return .int(Int64(try read() as Int32))
            case .uint64: return .uint(try read() as UInt64)
            case .int64: return .int(try read() as Int64)
            case .float32: return .float(Double(try readFloat32()))
            case .float64: return .float(try readFloat64())
            case .bool: return .bool((try read() as UInt8) != 0)
            case .string:
                if let s = try readString(maxStored: GGUFParser.maxStoredStringBytes) { return .string(s) }
                return .string("")
            case .array:
                guard depth < 2 else { throw GGUFError.malformed("nested arrays too deep") }
                let rawElementType: UInt32 = try read()
                guard let elementType = GGUFValueType(rawValue: rawElementType) else {
                    throw GGUFError.malformed("unknown array element type \(rawElementType)")
                }
                let count64: UInt64 = try read()
                guard count64 < UInt64(Int32.max) else { throw GGUFError.malformed("array length \(count64)") }
                let count = Int(count64)

                if let size = elementType.fixedSize {
                    if count <= GGUFParser.maxStoredArrayCount {
                        var values: [GGUFValue] = []
                        values.reserveCapacity(count)
                        for _ in 0..<count { values.append(try readValue(elementType, depth: depth + 1)) }
                        return .array(elementType: elementType, count: count, values: values)
                    }
                    let bytes = count.multipliedReportingOverflow(by: size)
                    guard !bytes.overflow else { throw GGUFError.malformed("array too large") }
                    try require(bytes.partialValue)
                    offset += bytes.partialValue
                    return .array(elementType: elementType, count: count, values: nil)
                }

                if elementType == .string {
                    // Vocabularies hold >100k strings: skip them, keep only the count.
                    for _ in 0..<count { try skipString() }
                    return .array(elementType: elementType, count: count, values: nil)
                }

                var values: [GGUFValue] = []
                for _ in 0..<count { values.append(try readValue(elementType, depth: depth + 1)) }
                return .array(elementType: elementType, count: count, values: count <= 64 ? values : nil)
            }
        }
    }
}

// MARK: - Model summary

/// The subset of GGUF metadata OMNIA needs for compatibility checks and memory planning.
struct GGUFModelInfo: Codable, Hashable, Sendable {
    var ggufVersion: Int
    var architecture: String
    var name: String?
    var sizeLabel: String?
    var license: String?
    var fileType: Int?
    var contextLength: Int?
    var embeddingLength: Int?
    var blockCount: Int?
    var headCount: Int?
    /// Per-layer KV head counts. Zero marks a non-attention (recurrent / convolution) layer.
    var headCountKVPerLayer: [Int]?
    var keyLength: Int?
    var valueLength: Int?
    /// Head sizes of sliding-window layers when they differ (Gemma 4).
    var keyLengthSWA: Int?
    var valueLengthSWA: Int?
    var slidingWindow: Int?
    /// Per-layer flag: true when the layer uses sliding-window attention.
    var slidingWindowLayers: [Bool]?
    /// Trailing layers that reuse an earlier layer's KV cache (Gemma 3n / Gemma 4 E-models).
    var sharedKVLayers: Int?
    /// Hybrid linear-attention models: every Nth layer is full attention (Qwen3.5 family).
    var fullAttentionInterval: Int?
    var ssmInnerSize: Int?
    var ssmStateSize: Int?
    var ssmGroupCount: Int?
    var ssmConvKernel: Int?
    var shortConvCache: Int?
    var kvLoraRank: Int?
    var expertCount: Int?
    var expertUsedCount: Int?
    var isRecurrentOrHybrid: Bool
    var vocabSize: Int?
    var addsBOS: Bool?
    var chatTemplate: String?
    var parameterCount: UInt64?
    var expertParameterCount: UInt64?

    init(header: GGUFHeader) throws {
        let md = header.metadata
        guard let arch = md["general.architecture"]?.stringValue, !arch.isEmpty else {
            throw GGUFError.malformed("missing general.architecture")
        }
        func value(_ suffix: String) -> GGUFValue? { md["\(arch).\(suffix)"] }

        ggufVersion = Int(header.version)
        architecture = arch
        name = md["general.name"]?.stringValue
        sizeLabel = md["general.size_label"]?.stringValue
        license = md["general.license"]?.stringValue
        fileType = md["general.file_type"]?.intValue
        contextLength = value("context_length")?.intValue
        embeddingLength = value("embedding_length")?.intValue
        blockCount = value("block_count")?.intValue

        let headValue = value("attention.head_count")
        headCount = headValue?.intValue ?? headValue?.intArray?.max()

        let layers = blockCount ?? 0
        if let kv = value("attention.head_count_kv") {
            if let perLayer = kv.intArray {
                headCountKVPerLayer = perLayer
            } else if let scalar = kv.intValue, layers > 0 {
                headCountKVPerLayer = Array(repeating: scalar, count: layers)
            }
        } else if let heads = headCount, layers > 0 {
            headCountKVPerLayer = Array(repeating: heads, count: layers) // MHA: KV heads == heads
        }

        keyLength = value("attention.key_length")?.intValue
        valueLength = value("attention.value_length")?.intValue
        slidingWindow = value("attention.sliding_window")?.intValue
        if let pattern = value("attention.sliding_window_pattern") {
            if let flags = pattern.boolArray, flags.count == layers {
                slidingWindowLayers = flags
            } else if let period = pattern.intValue, period > 1, layers > 0 {
                slidingWindowLayers = (0..<layers).map { ($0 + 1) % period != 0 }
            }
        }
        if slidingWindowLayers == nil, slidingWindow != nil, layers > 0,
           let period = GGUFModelInfo.defaultSWAPeriod[arch] {
            // llama.cpp hard-codes the local/global interleave for these architectures.
            slidingWindowLayers = (0..<layers).map { ($0 + 1) % period != 0 }
        }

        keyLengthSWA = value("attention.key_length_swa")?.intValue
        valueLengthSWA = value("attention.value_length_swa")?.intValue
        sharedKVLayers = value("attention.shared_kv_layers")?.intValue
        fullAttentionInterval = value("full_attention_interval")?.intValue
        ssmInnerSize = value("ssm.inner_size")?.intValue
        ssmStateSize = value("ssm.state_size")?.intValue
        ssmGroupCount = value("ssm.group_count")?.intValue
        ssmConvKernel = value("ssm.conv_kernel")?.intValue
        shortConvCache = value("shortconv.l_cache")?.intValue
        kvLoraRank = value("attention.kv_lora_rank")?.intValue
        expertCount = value("expert_count")?.intValue
        expertUsedCount = value("expert_used_count")?.intValue
        isRecurrentOrHybrid = md.keys.contains { $0.hasPrefix("\(arch).ssm.") || $0.hasPrefix("\(arch).shortconv.") || $0.hasPrefix("\(arch).rwkv.") || $0.hasPrefix("\(arch).wkv.") }
            || (headCountKVPerLayer?.contains(0) ?? false)
        vocabSize = md["tokenizer.ggml.tokens"]?.arrayCount
        addsBOS = md["tokenizer.ggml.add_bos_token"]?.boolValue
        chatTemplate = md["tokenizer.chat_template"]?.stringValue
        parameterCount = header.tensors?.totalElements
        expertParameterCount = header.tensors.map { $0.expertElements }
    }

    /// Every Nth layer is global attention; the rest use the sliding window.
    static let defaultSWAPeriod: [String: Int] = [
        "gemma2": 2, "gemma3": 6, "gemma3n": 5, "cohere2": 4, "gpt-oss": 2,
        "llama4": 4, "exaone4": 4
    ]

    var quantizationLabel: String? { fileType.flatMap { GGUFModelInfo.fileTypeNames[$0] } }

    var headDimension: Int? {
        if let k = keyLength { return k }
        if let e = embeddingLength, let h = headCount, h > 0 { return e / h }
        return nil
    }

    var attentionLayerCount: Int { headCountKVPerLayer?.filter { $0 > 0 }.count ?? (blockCount ?? 0) }

    /// Active parameters per token for mixture-of-experts models; total for dense models.
    var activeParameterCount: UInt64? {
        guard let total = parameterCount else { return nil }
        guard let experts = expertParameterCount, experts > 0,
              let n = expertCount, let used = expertUsedCount, n > 0 else { return total }
        let dense = total - min(total, experts)
        return dense + UInt64(Double(experts) * Double(used) / Double(n))
    }

    /// The chat template exposes a reasoning switch (`enable_thinking`, `reasoning_effort`, `reasoning_strength`).
    var supportsThinkingToggle: Bool {
        guard let template = chatTemplate else { return false }
        return template.contains("enable_thinking") || template.contains("reasoning_effort") || template.contains("reasoning_strength")
    }

    static let fileTypeNames: [Int: String] = [
        0: "F32", 1: "F16", 2: "Q4_0", 3: "Q4_1", 7: "Q8_0", 8: "Q5_0", 9: "Q5_1",
        10: "Q2_K", 11: "Q3_K_S", 12: "Q3_K_M", 13: "Q3_K_L", 14: "Q4_K_S", 15: "Q4_K_M",
        16: "Q5_K_S", 17: "Q5_K_M", 18: "Q6_K", 19: "IQ2_XXS", 20: "IQ2_XS", 21: "Q2_K_S",
        22: "IQ3_XS", 23: "IQ3_XXS", 24: "IQ1_S", 25: "IQ4_NL", 26: "IQ3_S", 27: "IQ3_M",
        28: "IQ2_S", 29: "IQ2_M", 30: "IQ4_XS", 31: "IQ1_M", 32: "BF16", 36: "TQ1_0",
        37: "TQ2_0", 38: "MXFP4", 39: "NVFP4", 40: "Q1_0", 41: "Q2_0"
    ]
}

// MARK: - Reading prefixes

enum GGUFInspector {
    /// Prefix sizes tried in order. Vocabulary arrays make headers of 2–12 MB common.
    static let prefixSchedule = [4 << 20, 16 << 20, 48 << 20, 128 << 20]

    /// Reads and parses the header of a local GGUF file, growing the prefix as needed.
    static func inspect(fileAt url: URL) throws -> (header: GGUFHeader, info: GGUFModelInfo) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
        var lastError: Error = GGUFError.notGGUF
        for size in prefixSchedule {
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: min(size, fileSize)) ?? Data()
            do {
                let header = try GGUFParser.parse(data)
                return (header, try GGUFModelInfo(header: header))
            } catch GGUFError.needMoreData {
                lastError = GGUFError.needMoreData(minimum: size * 2)
                if data.count >= fileSize { throw GGUFError.malformed("file ends inside the header") }
                continue
            }
        }
        throw lastError
    }

    /// Parses the header of a remote file using HTTP range requests.
    static func inspect(remote fetch: (Range<Int>) async throws -> Data) async throws -> (header: GGUFHeader, info: GGUFModelInfo) {
        var data = Data()
        for size in prefixSchedule {
            if data.count < size {
                data.append(try await fetch(data.count..<size))
            }
            do {
                let header = try GGUFParser.parse(data)
                return (header, try GGUFModelInfo(header: header))
            } catch GGUFError.needMoreData {
                continue
            }
        }
        throw GGUFError.needMoreData(minimum: (prefixSchedule.last ?? 0) * 2)
    }

    /// Fast signature check used before any heavier work.
    static func hasGGUFSignature(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 4) else { return false }
        return Array(bytes) == GGUFParser.magic
    }

    /// Whether a file is an image encoder that llama.cpp can pair with a model: an "mmproj"
    /// GGUF (architecture `clip`) with a vision tower.
    static func isImageEncoder(fileAt url: URL) -> Bool {
        guard let inspected = try? inspect(fileAt: url), inspected.info.isEncoder else { return false }
        return inspected.header.metadata["clip.has_vision_encoder"]?.boolValue ?? true
    }
}

extension GGUFModelInfo {
    /// llama.cpp writes image and audio encoders ("mmproj" files) with the `clip` architecture.
    /// They aren't models on their own: they belong to the model they were made for.
    var isEncoder: Bool { architecture == "clip" }
}
