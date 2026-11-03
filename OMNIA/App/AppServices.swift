import Foundation
import SwiftData

/// Composition root: creates every service once and wires them together.
/// UI code reads the observable services from the SwiftUI environment.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let settings: AppSettings
    let device: DeviceProfile
    let monitor: PerformanceMonitor
    let connectivity: ConnectivityMonitor
    let store: ModelStore
    let downloads: DownloadManager
    let downloadActivities: DownloadActivities
    let importer: ModelImporter
    let engine: InferenceEngine
    let container: ModelContainer
    let semanticIndex: SemanticIndex
    let python: PythonRuntime
    let codeRunner: CodeRunner
    let webReader: WebReader
    let browser: BrowserSession
    let speech: SpeechPlayer
    let dictation: DictationService
    let chat: ChatService
    let compare: CompareService
    let navigator = AppNavigator()

    private var started = false

    private init() {
        settings = AppSettings.shared
        device = DeviceProfile.detect()
        monitor = PerformanceMonitor()
        connectivity = ConnectivityMonitor()
        store = ModelStore()
        container = PersistenceSchema.makeContainer()
        semanticIndex = SemanticIndex(container: container)
        downloads = DownloadManager(store: store, semanticIndex: semanticIndex, settings: settings)
        downloadActivities = DownloadActivities(downloads: downloads)
        importer = ModelImporter(store: store)
        engine = InferenceEngine(store: store, settings: settings, device: device, monitor: monitor)
        python = PythonRuntime(settings: settings)
        codeRunner = CodeRunner(python: python)
        webReader = WebReader(settings: settings)
        browser = BrowserSession(settings: settings)
        let speech = SpeechPlayer()
        let dictation = DictationService(player: speech)
        speech.dictation = dictation
        self.speech = speech
        self.dictation = dictation
        chat = ChatService(engine: engine, store: store, settings: settings, container: container, semanticIndex: semanticIndex,
                           codeRunner: codeRunner, webReader: webReader)
        compare = CompareService(engine: engine, store: store, settings: settings, container: container)

        downloads.onInstalled = { [weak self] model in
            guard let self else { return }
            if self.settings.defaultModelID == nil { self.settings.defaultModelID = model.id }
            self.engine.post("arrow.down.circle", "\(model.displayName) is downloaded, verified and ready offline.")
        }
        chat.onReplyCompleted = { [weak self] reply in
            guard let self, self.settings.readRepliesAloud else { return }
            let content = reply.content, id = reply.id
            Task { await self.speech.speak(content, id: id) }
        }
        downloads.onProjectorInstalled = { [weak self] models in
            guard let self, let first = models.first else { return }
            let name = models.count == 1 ? first.displayName : "\(models.count) models"
            self.engine.post("photo", "\(name) can now read photos and screenshots.")
        }
    }

    /// Starts a chat from outside the windows (Siri, Shortcuts) and shows it.
    func startChat(_ text: String, attachments: [AttachmentRecord] = []) {
        guard let conversation = chat.send(text, attachments: attachments, in: nil, modelID: nil) else { return }
        navigator.show(conversation.id)
    }

    /// The Hugging Face client honours Offline-only mode at the moment of use.
    var huggingFace: HuggingFaceClient { HuggingFaceClient(offlineOnly: settings.offlineOnly) }

    var profile: OptimizationProfile { engine.profile }

    func start() {
        guard !started else { return }
        started = true
        monitor.start()
        connectivity.start()
        downloadActivities.start()
        store.reconcile()
        store.refreshSystemModels()
        if PersistenceSchema.loadError == nil {
            SeedData.installIfNeeded(in: container.mainContext)
        }
        recoverInterruptedReplies()
        if let id = settings.defaultModelID, store.model(id: id) == nil {
            settings.defaultModelID = store.sortedByRecentUse.first?.id
        }
        // Documents added while the embedding model was away (or before it was installed).
        semanticIndex.scheduleIndexing()
    }

    /// Replies still marked as streaming were cut off when OMNIA was terminated:
    /// mark them interrupted so they offer Continue.
    private func recoverInterruptedReplies() {
        let streaming = MessageState.streaming.rawValue
        let descriptor = FetchDescriptor<Message>(predicate: #Predicate { $0.stateRaw == streaming })
        guard let messages = try? container.mainContext.fetch(descriptor), !messages.isEmpty else { return }
        for message in messages {
            message.state = .interrupted
            if message.errorMessage == nil {
                message.errorMessage = "OMNIA was closed while this reply was being written. Tap Continue to resume."
            }
        }
        try? container.mainContext.save()
    }
}
