import Foundation
import SwiftData

enum MessageState: String, Codable {
    case complete, streaming, interrupted, failed
}

/// A file the user attached to a message: its extracted text, or for an image (kind `.image`)
/// only its name and size; the picture itself is kept in `Message.images`.
struct AttachmentRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var kind: DocumentKind
    var byteSize: Int
    var text: String
}

@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var modelID: String?
    var modelName: String?
    var systemPrompt: String?
    var personaID: UUID?
    var overridesData: Data?
    var documentIDs: [UUID] = []
    var thinkingEnabled: Bool?
    /// nil follows Settings › Tools.
    var toolsEnabled: Bool?
    /// The model may search the web and read pages; nil follows Settings › Workspace.
    var webAccessEnabled: Bool?
    /// "json" for JSON mode; nil for normal text.
    var responseFormatRaw: String?
    var folder: Folder?
    @Relationship(deleteRule: .cascade, inverse: \Message.conversation)
    var messages: [Message] = []

    init(title: String = "New Conversation", modelID: String?, modelName: String?, systemPrompt: String? = nil) {
        id = UUID()
        self.title = title
        createdAt = .now
        updatedAt = .now
        isPinned = false
        self.modelID = modelID
        self.modelName = modelName
        self.systemPrompt = systemPrompt
    }

    var orderedMessages: [Message] { messages.sorted { $0.position < $1.position } }

    var overrides: GenerationOverrides? {
        get { overridesData.flatMap { try? JSONDecoder().decode(GenerationOverrides.self, from: $0) } }
        set { overridesData = newValue.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) } }
    }

    var lastActivity: Date { updatedAt }

    /// Replies must be a JSON object.
    var jsonMode: Bool {
        get { responseFormatRaw == "json" }
        set { responseFormatRaw = newValue ? "json" : nil }
    }

    var preview: String {
        orderedMessages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content.titleSnippet(limit: 90)
            ?? orderedMessages.last?.content.titleSnippet(limit: 90) ?? ""
    }
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var content: String
    var reasoning: String?
    var createdAt: Date
    var position: Int
    var modelID: String?
    var modelName: String?
    var statsData: Data?
    var stateRaw: String
    var errorMessage: String?
    @Attribute(.externalStorage) var attachmentsData: Data?
    /// Tools the model called while writing this reply (JSON-encoded `[ToolStep]`).
    @Attribute(.externalStorage) var toolStepsData: Data?
    /// Attached images (JPEG) by attachment ID, as a binary property list. Kept apart from
    /// `attachmentsData` so listing attachments never decodes megabytes of pictures.
    @Attribute(.externalStorage) var imagesData: Data?
    var conversation: Conversation?

    init(role: ChatRole, content: String, position: Int, modelID: String? = nil, modelName: String? = nil,
         state: MessageState = .complete) {
        id = UUID()
        roleRaw = role.rawValue
        self.content = content
        createdAt = .now
        self.position = position
        self.modelID = modelID
        self.modelName = modelName
        stateRaw = state.rawValue
    }

    var role: ChatRole { ChatRole(rawValue: roleRaw) ?? .user }

    var state: MessageState {
        get { MessageState(rawValue: stateRaw) ?? .complete }
        set { stateRaw = newValue.rawValue }
    }

    var stats: GenerationStats? {
        get { statsData.flatMap { try? JSONDecoder().decode(GenerationStats.self, from: $0) } }
        set { statsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var attachments: [AttachmentRecord] {
        get { attachmentsData.flatMap { try? JSONDecoder().decode([AttachmentRecord].self, from: $0) } ?? [] }
        set { attachmentsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var toolSteps: [ToolStep] {
        get { toolStepsData.flatMap { try? JSONDecoder().decode([ToolStep].self, from: $0) } ?? [] }
        set { toolStepsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var images: [UUID: Data] {
        get {
            guard let imagesData, let stored = try? PropertyListDecoder().decode([String: Data].self, from: imagesData) else { return [:] }
            return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        }
        set {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let stored = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            imagesData = newValue.isEmpty ? nil : try? encoder.encode(stored)
        }
    }

    /// The images attached to this message, in attachment order.
    var orderedImages: [AttachedImage] {
        let attached = attachments.filter { $0.kind == .image }
        guard !attached.isEmpty else { return [] }
        let stored = images
        return attached.compactMap { attachment in stored[attachment.id].map { AttachedImage(attachment: attachment, data: $0) } }
    }
}

/// A picture attached to a message, with its attachment record.
struct AttachedImage: Identifiable {
    let attachment: AttachmentRecord
    let data: Data
    var id: UUID { attachment.id }
}

@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    @Relationship(deleteRule: .nullify, inverse: \Conversation.folder)
    var conversations: [Conversation] = []

    init(name: String) {
        id = UUID()
        self.name = name
        createdAt = .now
    }
}

@Model
final class PromptTemplate {
    @Attribute(.unique) var id: UUID
    var title: String
    var body: String
    var category: String
    var createdAt: Date
    var isBuiltIn: Bool

    init(title: String, body: String, category: String, isBuiltIn: Bool = false) {
        id = UUID()
        self.title = title
        self.body = body
        self.category = category
        createdAt = .now
        self.isBuiltIn = isBuiltIn
    }
}

/// A named assistant personality: a system prompt plus optional sampling preferences.
@Model
final class Persona {
    @Attribute(.unique) var id: UUID
    var name: String
    var symbol: String
    var systemPrompt: String
    var temperature: Double?
    var createdAt: Date
    var isBuiltIn: Bool

    init(name: String, symbol: String, systemPrompt: String, temperature: Double? = nil, isBuiltIn: Bool = false) {
        id = UUID()
        self.name = name
        self.symbol = symbol
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        createdAt = .now
        self.isBuiltIn = isBuiltIn
    }
}

/// A document in the local knowledge library. Text is extracted once and stored on device.
@Model
final class KnowledgeDocument {
    @Attribute(.unique) var id: UUID
    var title: String
    var fileName: String
    var kindRaw: String
    @Attribute(.externalStorage) var textData: Data
    var byteSize: Int
    var characterCount: Int
    var createdAt: Date
    /// Embedding vectors of the document's chunks (see `EmbeddingVectors`), the embedding model
    /// that made them and how many there are; nil until `SemanticIndex` indexes the document.
    @Attribute(.externalStorage) var embeddingsData: Data?
    var embeddingModelID: String?
    var embeddingCount: Int?

    init(title: String, fileName: String, kind: DocumentKind, text: String, byteSize: Int) {
        id = UUID()
        self.title = title
        self.fileName = fileName
        kindRaw = kind.rawValue
        textData = Data(text.utf8)
        self.byteSize = byteSize
        characterCount = text.count
        createdAt = .now
    }

    var kind: DocumentKind { DocumentKind(rawValue: kindRaw) ?? .text }
    var text: String { String(decoding: textData, as: UTF8.self) }
}

/// One measured inference on this device (chat turn, comparison or benchmark).
@Model
final class InferenceRecord {
    var id: UUID
    var date: Date
    var modelID: String
    var modelName: String
    var kindRaw: String
    var promptTokens: Int
    var generatedTokens: Int
    var timeToFirstToken: Double
    var promptTokensPerSecond: Double
    var tokensPerSecond: Double
    var contextSize: Int
    var stopReasonRaw: String

    enum Kind: String { case chat, compare, benchmark }

    init(stats: GenerationStats, kind: Kind) {
        id = UUID()
        date = .now
        modelID = stats.modelID
        modelName = stats.modelName
        kindRaw = kind.rawValue
        promptTokens = stats.promptTokens
        generatedTokens = stats.generatedTokens
        timeToFirstToken = stats.timeToFirstToken
        promptTokensPerSecond = stats.promptTokensPerSecond
        tokensPerSecond = stats.tokensPerSecond
        contextSize = stats.contextSize
        stopReasonRaw = stats.stopReason.rawValue
    }

    init(benchmark: BenchmarkMeasurement, modelID: String, modelName: String, contextSize: Int) {
        id = UUID()
        date = .now
        self.modelID = modelID
        self.modelName = modelName
        kindRaw = Kind.benchmark.rawValue
        promptTokens = benchmark.promptTokens
        generatedTokens = benchmark.generatedTokens
        timeToFirstToken = benchmark.timeToFirstToken
        promptTokensPerSecond = benchmark.promptTokensPerSecond
        tokensPerSecond = benchmark.tokensPerSecond
        self.contextSize = contextSize
        stopReasonRaw = StopReason.maxTokens.rawValue
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .chat }
}

@Model
final class ComparisonRecord {
    @Attribute(.unique) var id: UUID
    var date: Date
    var prompt: String
    var systemPrompt: String?
    var leftModelID: String
    var leftModelName: String
    var leftResponse: String
    var leftStatsData: Data?
    var rightModelID: String
    var rightModelName: String
    var rightResponse: String
    var rightStatsData: Data?

    init(prompt: String, systemPrompt: String?, left: (id: String, name: String), right: (id: String, name: String)) {
        id = UUID()
        date = .now
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        leftModelID = left.id
        leftModelName = left.name
        leftResponse = ""
        rightModelID = right.id
        rightModelName = right.name
        rightResponse = ""
    }

    var leftStats: GenerationStats? {
        get { leftStatsData.flatMap { try? JSONDecoder().decode(GenerationStats.self, from: $0) } }
        set { leftStatsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var rightStats: GenerationStats? {
        get { rightStatsData.flatMap { try? JSONDecoder().decode(GenerationStats.self, from: $0) } }
        set { rightStatsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}

enum PersistenceSchema {
    static let models: [any PersistentModel.Type] = [
        Conversation.self, Message.self, Folder.self, PromptTemplate.self, Persona.self,
        KnowledgeDocument.self, InferenceRecord.self, ComparisonRecord.self
    ]

    @MainActor
    static func makeContainer() -> ModelContainer {
        let schema = Schema(models)
        // Local-only store: no CloudKit, no sync. Conversations never leave the device.
        let configuration = ModelConfiguration("OMNIA", schema: schema, isStoredInMemoryOnly: false,
                                               allowsSave: true, groupContainer: .none, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A store that can't be opened (e.g. after an incompatible schema change in development)
            // must not brick the app: fall back to an in-memory store and surface the problem.
            PersistenceSchema.loadError = error.localizedDescription
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [memory])
        }
    }

    @MainActor static var loadError: String?
}
