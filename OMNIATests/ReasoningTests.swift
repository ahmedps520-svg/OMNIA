import Foundation
import Testing
@testable import OMNIA

/// What keeps reasoning models useful: a moderate effort instead of a template's most thorough
/// level, room to finish the answer after thinking, and a prompt that tells the model its tools.
@Suite("Reasoning and replies")
@MainActor
struct ReasoningTests {
    @Test func effortReachesTheTemplateVariables() {
        let automatic = ReasoningPreference.automatic.templateVariables(effort: .low)
        #expect(automatic["reasoning_effort"] == .string("low"))
        #expect(automatic["reasoning_strength"] == .string("low"))
        #expect(automatic["enable_thinking"] == nil)

        let on = ReasoningPreference.on.templateVariables(effort: .high)
        #expect(on["enable_thinking"] == .bool(true))
        #expect(on["reasoning_effort"] == .string("high"))

        // Off asks for the least thinking from templates that can't switch it off entirely.
        let off = ReasoningPreference.off.templateVariables(effort: .high)
        #expect(off["enable_thinking"] == .bool(false))
        #expect(off["reasoning_effort"] == .string("low"))
    }

    @Test func recognisesTemplatesWithAReasoningControl() {
        #expect(ReasoningPreference.isSupported(by: "{% if enable_thinking %}<think>{% endif %}"))
        #expect(ReasoningPreference.isSupported(by: "{{ 'Reasoning: ' + reasoning_effort }}"))
        #expect(ReasoningPreference.isSupported(by: "{{ reasoning_strength }}"))
        #expect(!ReasoningPreference.isSupported(by: "{{ messages }}"))
    }

    /// Qwen3.8 thinks at "xhigh" unless told otherwise, and raises an error for a level it doesn't know.
    @Test(arguments: ReasoningEffort.allCases)
    func qwen38ThinksAsMuchAsAsked(_ effort: ReasoningEffort) throws {
        let renderer = try ChatTemplateRenderer(source: TemplateFixtures.qwen3827b.template, bosToken: "", eosToken: "")
        let turns = [ChatTurn(role: .system, content: "You are helpful."), ChatTurn(role: .user, content: "Hi")]
        let variables = ReasoningPreference.automatic.templateVariables(effort: effort)
        let rendered = try renderer.render(turns, addGenerationPrompt: true, variables: variables,
                                           tools: ChatTemplateParityTests.tools, date: ChatTemplateParityTests.date)
        #expect(rendered.contains("Reasoning effort is set to xhigh") == (effort == .high))
        #expect(rendered.contains("Reasoning effort is set to low") == (effort == .low))
    }

    /// No catalog template may reject a reasoning setting OMNIA sends.
    @Test(arguments: TemplateFixtures.all)
    func everyTemplateAcceptsEverySetting(_ fixture: TemplateFixture) throws {
        let renderer = try ChatTemplateRenderer(source: fixture.template, bosToken: "<BOS>", eosToken: "<EOS>")
        let turns = [ChatTurn(role: .system, content: "You are helpful."), ChatTurn(role: .user, content: "Hi")]
        for preference in ReasoningPreference.allCases {
            for effort in ReasoningEffort.allCases {
                let rendered = try renderer.render(turns, addGenerationPrompt: true,
                                                   variables: preference.templateVariables(effort: effort),
                                                   tools: ChatTemplateParityTests.tools, date: ChatTemplateParityTests.date)
                #expect(rendered.contains("Hi"), "\(fixture.model) / \(preference) / \(effort)")
            }
        }
    }

    @Test func newSettingsAllowLongRepliesAndBalancedEffort() throws {
        let settings = AppSettings(defaults: try #require(UserDefaults(suiteName: "omnia-tests-\(UUID().uuidString)")))
        #expect(settings.generation.maxOutputTokens == 8192)
        #expect(settings.reasoningEffort == .medium)
    }

    /// Builds 01–04 saved a 2,048-token reply limit, which cut reasoning models off mid-thought.
    @Test func raisesTheOldReplyLimitOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "omnia-tests-\(UUID().uuidString)"))
        var old = GenerationSettings.default
        old.maxOutputTokens = 2048
        defaults.set(try JSONEncoder().encode(old), forKey: "generation")

        let settings = AppSettings(defaults: defaults)
        #expect(settings.generation.maxOutputTokens == 8192)
        #expect(defaults.integer(forKey: AppSettings.revisionKey) == 2)

        // A limit chosen after the update stays, even 2,048.
        settings.generation.maxOutputTokens = 2048
        #expect(AppSettings(defaults: defaults).generation.maxOutputTokens == 2048)
    }

    @Test func keepsAReplyLimitTheUserChose() throws {
        let defaults = try #require(UserDefaults(suiteName: "omnia-tests-\(UUID().uuidString)"))
        var chosen = GenerationSettings.default
        chosen.maxOutputTokens = 4096
        defaults.set(try JSONEncoder().encode(chosen), forKey: "generation")
        #expect(AppSettings(defaults: defaults).generation.maxOutputTokens == 4096)
    }

    @Test func defaultPromptNamesTheToolsAndTheWorkspace() {
        let prompt = ChatService.defaultSystemPrompt(device: "iPad", tools: ["calculator", "run_code"], date: .now)
        #expect(prompt.contains("running entirely on the user's iPad"))
        #expect(prompt.contains("You can call these tools: calculator, run_code."))
        #expect(prompt.contains("Never claim you have no tools."))
        #expect(prompt.contains("fenced code block"))
        #expect(prompt.contains("Swift Playgrounds"))
    }

    @Test func defaultPromptLeavesOutToolsWhenThereAreNone() {
        let prompt = ChatService.defaultSystemPrompt(device: "iPhone", tools: [], date: .now)
        #expect(prompt.contains("iPhone"))
        #expect(!prompt.contains("You can call these tools"))
    }
}

@Suite("Reasoning in a chat", .serialized, .enabled(if: TestModels.available("stories260K.gguf")))
@MainActor
struct ReasoningChatTests {
    @Test func aChatWithoutASystemPromptGetsOMNIAs() async throws {
        let harness = try ChatHarness(replies: ["Hello."])
        _ = try await harness.send("Hi")
        let request = try #require(harness.backend.requests.first)

        #expect(request.maxTokens == 8192)
        let system = try #require(request.turns.first)
        #expect(system.role == .system)
        #expect(system.content.contains("You are OMNIA"))
        // The tools offered in the request are the ones the prompt names.
        for tool in request.tools {
            #expect(system.content.contains(tool.name))
        }
        #expect(!request.tools.isEmpty)
    }

    @Test func aChosenSystemPromptIsKept() async throws {
        let harness = try ChatHarness(replies: ["Arr."])
        harness.store.updateSettings(for: harness.model.id) { $0.systemPrompt = "You are a pirate." }
        _ = try await harness.send("Hi")
        let system = try #require(harness.backend.requests.first?.turns.first)
        #expect(system.content.hasPrefix("You are a pirate."))
        #expect(!system.content.contains("You are OMNIA"))
    }
}
