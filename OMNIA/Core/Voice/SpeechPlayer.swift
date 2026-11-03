import AVFoundation
import NaturalLanguage
import Observation

/// Reads replies aloud with the system's speech synthesizer, on device, in the best installed
/// voice for the reply's language, or the voice chosen in Settings › Accessibility › Spoken Content.
/// Reading goes on with the screen locked.
@MainActor
@Observable
final class SpeechPlayer: NSObject {
    /// A synthesizer voice, as `bestVoice` weighs it.
    struct Voice: Equatable, Sendable {
        let identifier: String
        let language: String
        let quality: Int
    }

    /// The message being read aloud.
    private(set) var speakingID: UUID?

    /// Set by AppServices. Dictation stops before a reply is read: the microphone would hear it.
    @ObservationIgnored weak var dictation: DictationService?
    private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var utterance: ObjectIdentifier?
    @ObservationIgnored private var sessionActive = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Reads a Markdown reply aloud, stopping whatever was being read.
    func speak(_ markdown: String, id: UUID) async {
        stop()
        let text = SpeechText.from(markdown: markdown)
        guard !text.isEmpty else { return }
        speakingID = id
        if let dictation, dictation.state != .idle { await dictation.stop() }
        // Stopped, or another reply started, while dictation finished.
        guard speakingID == id else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        sessionActive = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: text)
        utterance.prefersAssistiveTechnologySettings = true
        self.utterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stop() {
        utterance = nil
        speakingID = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    fileprivate func ended(_ key: ObjectIdentifier) {
        if key == utterance {
            utterance = nil
            speakingID = nil
        }
        // Another reply may be reading already.
        guard utterance == nil, sessionActive else { return }
        sessionActive = false
        // Dictation, when it stopped the reading, has the audio session now.
        guard (dictation?.state ?? .idle) == .idle else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Voice

    /// The voice for reading `text`: its language as detected (the user's when unsure).
    private static func voice(for text: String) -> AVSpeechSynthesisVoice? {
        let preferred = AVSpeechSynthesisVoice.currentLanguageCode()
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        let detected = recognizer.languageHypotheses(withMaximum: 1).first { $0.value >= 0.5 }?.key.rawValue
        let language = detected ?? preferred
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .map { Voice(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue) }
        if let best = bestVoice(for: language, preferring: preferred, among: voices),
           let voice = AVSpeechSynthesisVoice(identifier: best.identifier) {
            return voice
        }
        return AVSpeechSynthesisVoice(language: language)
    }

    /// The best of `voices` for `language` ("en", "zh-Hant"…): the highest quality, then the
    /// user's own variant (British English for a British user), then the language's main one.
    nonisolated static func bestVoice(for language: String, preferring preferred: String, among voices: [Voice]) -> Voice? {
        let wanted = writtenLanguage(language)
        let parts = Locale.Language(identifier: language).maximalIdentifier.split(separator: "-")
        let main = parts.count >= 3 ? "\(parts[0])-\(parts[2])" : language
        func rank(_ voice: Voice) -> (Int, Int, Int) {
            (voice.quality, voice.language == preferred ? 1 : 0, voice.language == main ? 1 : 0)
        }
        return voices
            .filter { writtenLanguage($0.language) == wanted }
            .max { rank($0) < rank($1) }
    }

    /// Language and script, which decide whether a voice can read a text: "zh-Hant" for zh-TW,
    /// "en-Latn" for en-GB.
    nonisolated static func writtenLanguage(_ identifier: String) -> String {
        Locale.Language(identifier: identifier).maximalIdentifier.split(separator: "-").prefix(2).joined(separator: "-")
    }
}

extension SpeechPlayer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(key) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.ended(key) }
    }
}
