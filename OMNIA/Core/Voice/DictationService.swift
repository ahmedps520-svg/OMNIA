import AVFoundation
import Observation
import Speech

/// Dictation into the message field, recognized on device with iOS 26's SpeechAnalyzer: the
/// newer SpeechTranscriber where the hardware supports it, otherwise DictationTranscriber.
/// Audio goes from the microphone straight to the recognizer and is never stored. There's one
/// microphone, so one composer (in any window) dictates at a time.
@MainActor
@Observable
final class DictationService {
    enum Failure: LocalizedError {
        case microphoneDenied
        case languageUnsupported
        case modelUnavailable
        case noMicrophone

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "OMNIA isn't allowed to use the microphone. Turn it on in Settings › Privacy & Security › Microphone."
            case .languageUnsupported: "On-device dictation doesn't support your language yet."
            case .modelUnavailable: "The speech model isn't ready. Connect to the internet once so iOS can download it."
            case .noMicrophone: "No microphone is available."
            }
        }
    }

    enum State: Equatable {
        case idle
        /// Asking for the microphone, downloading the speech model or starting the recognizer.
        case preparing
        case recording
        /// Recognizing the last words after the microphone stopped.
        case finishing
    }

    private(set) var state = State.idle
    /// The composer dictating.
    private(set) var owner: UUID?
    /// Progress of iOS downloading the speech model, the first time a language is used.
    private(set) var modelDownload: Progress?

    private let engine = AVAudioEngine()
    /// Reading aloud stops while dictating: the microphone would hear it.
    private let player: SpeechPlayer
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var resultsTask: Task<Void, Never>?
    @ObservationIgnored private var watchers: [Task<Void, Never>] = []
    @ObservationIgnored private var tapInstalled = false
    /// Text recognized so far: the finished part, then the part still being recognized.
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var volatile = ""
    @ObservationIgnored private var onText: ((String) -> Void)?

    init(player: SpeechPlayer) {
        self.player = player
    }

    func isDictating(for owner: UUID) -> Bool {
        self.owner == owner && state != .idle
    }

    /// Starts dictating for `owner`, which gets everything recognized so far each time it changes
    /// (the last call has the final text). Takes the microphone from another composer using it.
    func start(for owner: UUID, locale requested: Locale = .current, onText: @escaping (String) -> Void) async throws {
        if state == .recording { await stop() }
        guard state == .idle else { return }
        state = .preparing
        self.owner = owner
        do {
            player.stop()
            guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
            try ensureWanted(by: owner)
            let module = try await Self.transcriber(for: requested)
            // No request means the model is installed; the first use of a language downloads it.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                modelDownload = request.progress
                defer { modelDownload = nil }
                try await request.downloadAndInstall()
            }
            try ensureWanted(by: owner)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw Failure.modelUnavailable
            }
            finalized = ""
            volatile = ""
            self.onText = onText
            try await listen(with: module, format: format)
            try ensureWanted(by: owner)
            state = .recording
            watchForInterruptions()
        } catch {
            await cancel()
            throw error
        }
    }

    /// Stops listening and waits for the last words to be recognized. While starting, stops the start.
    func stop() async {
        switch state {
        case .preparing:
            // `start` notices and cleans up when its current step returns.
            owner = nil
        case .recording:
            state = .finishing
            stopMicrophone()
            inputBuilder?.finish()
            inputBuilder = nil
            do {
                try await analyzer?.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer?.cancelAndFinishNow()
            }
            await resultsTask?.value
            resultsTask = nil
            analyzer = nil
            finish()
        case .idle, .finishing:
            break
        }
    }

    // MARK: Session

    private static func transcriber(for locale: Locale) async throws -> any SpeechModule {
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                     reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return DictationTranscriber(locale: supported, preset: .progressiveShortDictation)
        }
        throw Failure.languageUnsupported
    }

    private func listen(with module: any SpeechModule, format: AVAudioFormat) async throws {
        let analyzer = SpeechAnalyzer(modules: [module])
        let (input, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.analyzer = analyzer
        inputBuilder = builder
        resultsTask = results(of: module)
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)
        let microphone = engine.inputNode.outputFormat(forBus: 0)
        guard microphone.sampleRate > 0, microphone.channelCount > 0 else { throw Failure.noMicrophone }
        Self.installTap(on: engine.inputNode, format: microphone,
                        converter: AnalyzerBufferConverter(outputFormat: format), builder: builder)
        tapInstalled = true
        engine.prepare()
        try engine.start()
    }

    private func results(of module: any SpeechModule) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                if let transcriber = module as? SpeechTranscriber {
                    for try await result in transcriber.results {
                        self?.received(String(result.text.characters), isFinal: result.isFinal)
                    }
                } else if let transcriber = module as? DictationTranscriber {
                    for try await result in transcriber.results {
                        self?.received(String(result.text.characters), isFinal: result.isFinal)
                    }
                }
            } catch {
                // The session has ended.
            }
        }
    }

    private func received(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        onText?(finalized + volatile)
    }

    /// Thrown out of `start` when it was stopped, or its composer went away, during a step.
    private func ensureWanted(by owner: UUID) throws {
        guard self.owner == owner else { throw CancellationError() }
    }

    /// Ends the session at once, without waiting for the last words.
    private func cancel() async {
        stopMicrophone()
        inputBuilder?.finish()
        inputBuilder = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        finish()
    }

    private func stopMicrophone() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }

    private func finish() {
        watchers.forEach { $0.cancel() }
        watchers = []
        onText = nil
        owner = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A call or an alarm takes the microphone, and a new audio route (AirPods connecting) stops
    /// the engine: dictation ends with them, keeping what was recognized.
    private func watchForInterruptions() {
        let center = NotificationCenter.default
        watchers = [
            Task { [weak self] in
                for await note in center.notifications(named: AVAudioSession.interruptionNotification) {
                    let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                    if raw.flatMap({ AVAudioSession.InterruptionType(rawValue: $0) }) == .began {
                        await self?.stop()
                        return
                    }
                }
            },
            Task { [weak self] in
                for await _ in center.notifications(named: .AVAudioEngineConfigurationChange) {
                    if self?.engine.isRunning == false {
                        await self?.stop()
                        return
                    }
                }
            }
        ]
    }

    /// Not main-actor isolated: AVAudioEngine calls the tap on a real-time audio thread.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               converter: AnalyzerBufferConverter,
                                               builder: AsyncStream<AnalyzerInput>.Continuation) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard buffer.frameLength > 0, let converted = try? converter.convert(buffer) else { return }
            builder.yield(AnalyzerInput(buffer: converted))
        }
    }

    // MARK: Text

    /// The draft with dictated text added: on its own line after a paragraph, after a space otherwise.
    nonisolated static func appending(_ dictated: String, to draft: String) -> String {
        let dictated = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictated.isEmpty else { return draft }
        guard let last = draft.last else { return dictated }
        return last.isWhitespace ? draft + dictated : draft + " " + dictated
    }
}

/// Converts microphone buffers to the recognizer's format. The analyzer never converts audio
/// itself, and raw microphone buffers crash it. One converter per recording, used only by the tap.
final class AnalyzerBufferConverter: @unchecked Sendable {
    enum Failure: Error {
        case cannotCreateConverter, cannotAllocate, conversionFailed
    }

    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        if inputFormat == outputFormat {
            // Tap buffers are reused by the engine: hand on a copy.
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { throw Failure.cannotAllocate }
            return copy
        }
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { throw Failure.cannotCreateConverter }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw Failure.cannotAllocate }
        let feeder = OneShotFeeder(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = feeder.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        if status == .error {
            if let error { throw error }
            throw Failure.conversionFailed
        }
        return output
    }
}

/// Hands the converter one buffer (its input block may be @Sendable, so it can't mutate a var).
private final class OneShotFeeder: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
