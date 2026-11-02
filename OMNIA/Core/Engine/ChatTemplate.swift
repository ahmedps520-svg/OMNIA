import Foundation
import Jinja

/// Values passed to a model's chat template beyond the messages themselves.
enum TemplateValue: Hashable, Sendable {
    case bool(Bool)
    case string(String)
}

/// How much a reasoning model should think. Each template spells this differently.
enum ReasoningPreference: String, CaseIterable, Identifiable, Codable, Sendable {
    case automatic, off, on
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Model default"
        case .off: "Off"
        case .on: "On"
        }
    }

    /// Template variables understood by current model families:
    /// `enable_thinking` (Qwen3.5, Gemma 4, Granite 4.2, LFM), `reasoning_effort` (gpt-oss, Granite)
    /// and `reasoning_strength` (Muse Glimmer).
    var templateVariables: [String: TemplateValue] {
        switch self {
        case .automatic: [:]
        case .off: ["enable_thinking": .bool(false), "reasoning_effort": .string("low"), "reasoning_strength": .string("low")]
        case .on: ["enable_thinking": .bool(true), "reasoning_effort": .string("high"), "reasoning_strength": .string("high")]
        }
    }
}

/// Renders a model's own Jinja chat template (the `tokenizer.chat_template` stored in its GGUF),
/// the same way llama.cpp's server does with `--jinja`. This is what makes newer formats such as
/// Gemma 4's turn markers or reasoning switches work exactly as their authors intended.
struct ChatTemplateRenderer: Sendable {
    private let template: Template
    private let bosToken: String
    private let eosToken: String

    init(source: String, bosToken: String, eosToken: String) throws {
        template = try Template(source, with: .init(lstripBlocks: true, trimBlocks: true))
        self.bosToken = bosToken
        self.eosToken = eosToken
    }

    func render(_ turns: [ChatTurn], addGenerationPrompt: Bool, variables: [String: TemplateValue]) throws -> String {
        var messages: [Value] = []
        for turn in turns {
            let message: [String: Any?] = ["role": turn.role.rawValue, "content": turn.content]
            messages.append(try Value(any: message))
        }
        var context: [String: Value] = [
            "messages": .array(messages),
            "add_generation_prompt": .boolean(addGenerationPrompt),
            "bos_token": .string(bosToken),
            "eos_token": .string(eosToken)
        ]
        for (key, value) in variables {
            switch value {
            case .bool(let flag): context[key] = .boolean(flag)
            case .string(let text): context[key] = .string(text)
            }
        }
        return try template.render(context)
    }
}
