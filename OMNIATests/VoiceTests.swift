import Foundation
import Testing
@testable import OMNIA

/// Dictation and reading aloud need a microphone and speakers, so these check the text and voice
/// choices around them.
@Suite("Voice")
struct VoiceTests {
    @Test func readsMarkdownAsPlainSentences() {
        let markdown = """
        # Getting Started

        Install **OMNIA** and *open* it. Use `swift build` for the [package](https://swift.org/x).
        """
        #expect(SpeechText.from(markdown: markdown) == "Getting Started.\n\nInstall OMNIA and open it. Use swift build for the package.")
    }

    @Test func skipsCodeBlocksAndEquations() {
        let markdown = """
        Run this:
        ```swift
        print("hi")
        ```
        The area is:
        $$
        A = \\pi r^2
        $$
        Done.
        """
        #expect(SpeechText.from(markdown: markdown) == "Run this:\nCode omitted.\nThe area is:\nEquation omitted.\nDone.")
    }

    @Test func readsListsAndTablesWithPauses() {
        let markdown = """
        - First item
        - [x] Done item
        2. Second step
        > Quoted **text**

        | Model | Size |
        |:---|---:|
        | Gemma | 4 GB |

        ---
        """
        #expect(SpeechText.from(markdown: markdown) == "First item.\nDone item.\n2. Second step.\nQuoted text\n\nModel, Size.\nGemma, 4 GB.")
    }

    @Test func readsWebAddressesAsSites() {
        let text = "See https://www.apple.com/ipad/. Read <https://docs.swift.org/guide> and ![chart](a.png)[^1]."
        #expect(SpeechText.from(markdown: text) == "See apple.com. Read docs.swift.org and chart.")
    }

    @Test func leavesCodeAndArithmeticAlone() {
        let text = "**Note:** set `my_var` or my_other_var to _two_; 2 * 3 * 4 = 24, `a*b*c` and \\*stars\\*."
        #expect(SpeechText.from(markdown: text) == "Note: set my_var or my_other_var to two; 2 * 3 * 4 = 24, a*b*c and *stars*.")
    }

    @Test func picksTheBestVoiceForTheLanguage() {
        let voices = [
            SpeechPlayer.Voice(identifier: "us", language: "en-US", quality: 1),
            SpeechPlayer.Voice(identifier: "gb", language: "en-GB", quality: 1),
            SpeechPlayer.Voice(identifier: "gb-enhanced", language: "en-GB", quality: 2),
            SpeechPlayer.Voice(identifier: "ca", language: "fr-CA", quality: 1),
            SpeechPlayer.Voice(identifier: "fr", language: "fr-FR", quality: 1),
            SpeechPlayer.Voice(identifier: "cn", language: "zh-CN", quality: 1),
            SpeechPlayer.Voice(identifier: "tw", language: "zh-TW", quality: 1)
        ]
        let standard = voices.filter { $0.quality == 1 }
        // Quality first, then the user's own variant, then the language's main one.
        #expect(SpeechPlayer.bestVoice(for: "en", preferring: "en-US", among: voices)?.identifier == "gb-enhanced")
        #expect(SpeechPlayer.bestVoice(for: "en", preferring: "en-GB", among: standard)?.identifier == "gb")
        #expect(SpeechPlayer.bestVoice(for: "en", preferring: "en-US", among: standard)?.identifier == "us")
        #expect(SpeechPlayer.bestVoice(for: "fr", preferring: "en-US", among: voices)?.identifier == "fr")
        // The script decides between Chinese voices.
        #expect(SpeechPlayer.bestVoice(for: "zh-Hant", preferring: "en-US", among: voices)?.identifier == "tw")
        #expect(SpeechPlayer.bestVoice(for: "zh-Hans", preferring: "en-US", among: voices)?.identifier == "cn")
        #expect(SpeechPlayer.bestVoice(for: "de", preferring: "en-US", among: voices) == nil)
    }

    @Test func addsDictationToTheDraft() {
        #expect(DictationService.appending("Hello there", to: "") == "Hello there")
        #expect(DictationService.appending(" and more", to: "Some text") == "Some text and more")
        #expect(DictationService.appending("Next line", to: "First line\n") == "First line\nNext line")
        #expect(DictationService.appending("  ", to: "Keep this") == "Keep this")
    }
}
