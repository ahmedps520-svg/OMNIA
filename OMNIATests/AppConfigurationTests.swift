import Foundation
import Testing
@testable import OMNIA

/// What the built app declares (its Info.plist merges a file with generated keys), and the device
/// report's arithmetic.
@Suite("App configuration")
struct AppConfigurationTests {
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }

    @Test func opensSeveralWindows() {
        let manifest = info["UIApplicationSceneManifest"] as? [String: Any]
        #expect(manifest?["UIApplicationSupportsMultipleScenes"] as? Bool == true)
    }

    @Test func explainsTheMicrophoneAndReadsAloudWhenLocked() {
        #expect((info["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
        #expect((info["UIBackgroundModes"] as? [String])?.contains("audio") == true)
    }

    @Test func reportsMedianSpeeds() throws {
        func sample(_ speed: Double, prompt: Int = 100, context: Int = 4096) -> DeviceReport.Speeds.Sample {
            DeviceReport.Speeds.Sample(tokensPerSecond: speed, promptTokensPerSecond: speed * 10,
                                       timeToFirstToken: 1 / speed, promptTokens: prompt, contextSize: context)
        }
        #expect(DeviceReport.Speeds([]) == nil)
        let odd = try #require(DeviceReport.Speeds([sample(30), sample(10), sample(20, context: 8192)]))
        #expect(odd.replies == 3)
        #expect(odd.medianTokensPerSecond == 20)
        #expect(odd.medianPromptTokensPerSecond == 200)
        #expect(odd.largestContext == 8192)
        let even = try #require(DeviceReport.Speeds([sample(10), sample(40), sample(20), sample(30)]))
        #expect(even.medianTokensPerSecond == 25)
        // JSON can't hold NaN or infinity: those are left out.
        #expect(DeviceReport.Speeds.median([.nan, 4, .infinity, 2]) == 3)
        #expect(DeviceReport.Speeds.median([.nan]) == 0)
    }
}
