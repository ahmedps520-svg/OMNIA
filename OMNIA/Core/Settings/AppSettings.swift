import Foundation
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case dark, light, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        case .system: "System"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system: nil
        }
    }
}

enum AccentChoice: String, CaseIterable, Identifiable, Codable {
    case glacier, silver, sage, amber, iris, coral
    var id: String { rawValue }
    var title: String {
        switch self {
        case .glacier: "Glacier"
        case .silver: "Silver"
        case .sage: "Sage"
        case .amber: "Amber"
        case .iris: "Iris"
        case .coral: "Coral"
        }
    }
}

enum AnimationPreference: String, CaseIterable, Identifiable, Codable {
    case full, reduced, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: "Full"
        case .reduced: "Reduced"
        case .off: "Off"
        }
    }
}

enum ChatTypeface: String, CaseIterable, Identifiable, Codable {
    case system, serif, rounded
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "SF Pro"
        case .serif: "New York"
        case .rounded: "SF Rounded"
        }
    }
    var design: Font.Design {
        switch self {
        case .system: .default
        case .serif: .serif
        case .rounded: .rounded
        }
    }
}

enum KVCacheChoice: String, CaseIterable, Identifiable, Codable {
    case automatic, f16, q8_0, q4_0
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .f16: "F16 (highest fidelity)"
        case .q8_0: "Q8_0 (half memory)"
        case .q4_0: "Q4_0 (quarter memory)"
        }
    }
}

enum MemorySafety: String, CaseIterable, Identifiable, Codable {
    case conservative, balanced, maximum
    var id: String { rawValue }
    var title: String {
        switch self {
        case .conservative: "Conservative"
        case .balanced: "Balanced"
        case .maximum: "Maximum"
        }
    }
    /// Fraction of the measured headroom OMNIA lets a model occupy. Never above 1.
    var headroomFraction: Double {
        switch self {
        case .conservative: 0.80
        case .balanced: 0.88
        case .maximum: 0.94
        }
    }
}

enum ProfilePreference: String, CaseIterable, Identifiable, Codable {
    case automatic, quality, efficiency
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .quality: "Maximum quality"
        case .efficiency: "Efficiency"
        }
    }
}

/// Default sampling and runtime parameters. Conversations and models can override them.
struct GenerationSettings: Codable, Hashable {
    var temperature: Double = 0.7
    var topP: Double = 0.95
    var topK: Int = 40
    var minP: Double = 0.05
    var repetitionPenalty: Double = 1.05
    var repetitionLastN: Int = 128
    var maxOutputTokens: Int = 2048
    var seed: UInt32? = nil

    static let `default` = GenerationSettings()

    /// Merges optional overrides on top of this value.
    func applying(_ o: GenerationOverrides?) -> GenerationSettings {
        guard let o else { return self }
        var s = self
        if let v = o.temperature { s.temperature = v }
        if let v = o.topP { s.topP = v }
        if let v = o.topK { s.topK = v }
        if let v = o.minP { s.minP = v }
        if let v = o.repetitionPenalty { s.repetitionPenalty = v }
        if let v = o.maxOutputTokens { s.maxOutputTokens = v }
        return s
    }
}

/// Sparse overrides stored per conversation or per model.
struct GenerationOverrides: Codable, Hashable {
    var temperature: Double?
    var topP: Double?
    var topK: Int?
    var minP: Double?
    var repetitionPenalty: Double?
    var maxOutputTokens: Int?
    var contextLength: Int?

    var isEmpty: Bool {
        temperature == nil && topP == nil && topK == nil && minP == nil
            && repetitionPenalty == nil && maxOutputTokens == nil && contextLength == nil
    }
}

/// User preferences, persisted in UserDefaults. Observable so SwiftUI and services react to changes.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults: UserDefaults

    // Appearance
    var appearance: AppearanceMode { didSet { save(appearance.rawValue, "appearance") } }
    var accent: AccentChoice { didSet { save(accent.rawValue, "accent") } }
    var animations: AnimationPreference { didSet { save(animations.rawValue, "animations") } }
    var chatTypeface: ChatTypeface { didSet { save(chatTypeface.rawValue, "chatTypeface") } }
    var chatTextScale: Double { didSet { save(chatTextScale, "chatTextScale") } }
    var showGenerationDetails: Bool { didSet { save(showGenerationDetails, "showGenerationDetails") } }
    var showReasoning: Bool { didSet { save(showReasoning, "showReasoning") } }

    // Inference
    var defaultModelID: String? { didSet { save(defaultModelID, "defaultModelID") } }
    var generation: GenerationSettings { didSet { saveCodable(generation, "generation") } }
    /// 0 means "automatic" (profile default, clamped to what fits in memory).
    var contextLength: Int { didSet { save(contextLength, "contextLength") } }
    var gpuAcceleration: Bool { didSet { save(gpuAcceleration, "gpuAcceleration") } }
    var kvCache: KVCacheChoice { didSet { save(kvCache.rawValue, "kvCache") } }
    var flashAttention: Bool { didSet { save(flashAttention, "flashAttention") } }
    var reusePromptCache: Bool { didSet { save(reusePromptCache, "reusePromptCache") } }
    /// Save each long conversation's model memory so reopening it continues instantly.
    var rememberLongChats: Bool { didSet { save(rememberLongChats, "rememberLongChats") } }
    /// Storage allowed for saved conversation memory, in gigabytes.
    var conversationMemoryLimitGB: Double { didSet { save(conversationMemoryLimitGB, "conversationMemoryLimitGB") } }
    /// New conversations let the model use tools (calculator, date, documents…).
    var toolsEnabledByDefault: Bool { didSet { save(toolsEnabledByDefault, "toolsEnabledByDefault") } }
    /// New conversations let the model search the web and read pages (off unless chosen).
    var webAccessByDefault: Bool { didSet { save(webAccessByDefault, "webAccessByDefault") } }

    // Voice
    /// Each finished reply is read aloud.
    var readRepliesAloud: Bool { didSet { save(readRepliesAloud, "readRepliesAloud") } }

    // Memory & performance
    var memorySafety: MemorySafety { didSet { save(memorySafety.rawValue, "memorySafety") } }
    var profilePreference: ProfilePreference { didSet { save(profilePreference.rawValue, "profilePreference") } }
    /// Minutes of inactivity before loaded models are released. 0 disables.
    var idleUnloadMinutes: Int { didSet { save(idleUnloadMinutes, "idleUnloadMinutes") } }
    var keepModelsLoadedInBackground: Bool { didSet { save(keepModelsLoadedInBackground, "keepModelsLoadedInBackground") } }
    var restoreModelOnForeground: Bool { didSet { save(restoreModelOnForeground, "restoreModelOnForeground") } }
    var thermalProtection: Bool { didSet { save(thermalProtection, "thermalProtection") } }

    // Privacy & network
    var offlineOnly: Bool { didSet { save(offlineOnly, "offlineOnly") } }
    var allowCellularDownloads: Bool { didSet { save(allowCellularDownloads, "allowCellularDownloads") } }

    // State
    var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .dark
        accent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .glacier
        animations = AnimationPreference(rawValue: defaults.string(forKey: "animations") ?? "") ?? .full
        chatTypeface = ChatTypeface(rawValue: defaults.string(forKey: "chatTypeface") ?? "") ?? .system
        chatTextScale = defaults.object(forKey: "chatTextScale") as? Double ?? 1.0
        showGenerationDetails = defaults.object(forKey: "showGenerationDetails") as? Bool ?? true
        showReasoning = defaults.object(forKey: "showReasoning") as? Bool ?? true

        defaultModelID = defaults.string(forKey: "defaultModelID")
        if let data = defaults.data(forKey: "generation"),
           let decoded = try? JSONDecoder().decode(GenerationSettings.self, from: data) {
            generation = decoded
        } else {
            generation = .default
        }
        contextLength = defaults.object(forKey: "contextLength") as? Int ?? 0
        gpuAcceleration = defaults.object(forKey: "gpuAcceleration") as? Bool ?? true
        kvCache = KVCacheChoice(rawValue: defaults.string(forKey: "kvCache") ?? "") ?? .automatic
        flashAttention = defaults.object(forKey: "flashAttention") as? Bool ?? true
        reusePromptCache = defaults.object(forKey: "reusePromptCache") as? Bool ?? true
        rememberLongChats = defaults.object(forKey: "rememberLongChats") as? Bool ?? true
        conversationMemoryLimitGB = defaults.object(forKey: "conversationMemoryLimitGB") as? Double ?? 4
        toolsEnabledByDefault = defaults.object(forKey: "toolsEnabledByDefault") as? Bool ?? true
        webAccessByDefault = defaults.object(forKey: "webAccessByDefault") as? Bool ?? false
        readRepliesAloud = defaults.object(forKey: "readRepliesAloud") as? Bool ?? false

        memorySafety = MemorySafety(rawValue: defaults.string(forKey: "memorySafety") ?? "") ?? .balanced
        profilePreference = ProfilePreference(rawValue: defaults.string(forKey: "profilePreference") ?? "") ?? .automatic
        idleUnloadMinutes = defaults.object(forKey: "idleUnloadMinutes") as? Int ?? -1
        keepModelsLoadedInBackground = defaults.object(forKey: "keepModelsLoadedInBackground") as? Bool ?? false
        restoreModelOnForeground = defaults.object(forKey: "restoreModelOnForeground") as? Bool ?? true
        thermalProtection = defaults.object(forKey: "thermalProtection") as? Bool ?? true

        offlineOnly = defaults.object(forKey: "offlineOnly") as? Bool ?? false
        allowCellularDownloads = defaults.object(forKey: "allowCellularDownloads") as? Bool ?? false
        hasCompletedOnboarding = defaults.object(forKey: "hasCompletedOnboarding") as? Bool ?? false
    }

    func resetGenerationDefaults() {
        generation = .default
        contextLength = 0
        kvCache = .automatic
        flashAttention = true
        gpuAcceleration = true
    }

    private func save(_ value: Any?, _ key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
