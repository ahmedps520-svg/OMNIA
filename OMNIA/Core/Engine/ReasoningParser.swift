import Foundation

/// A model reply split into its reasoning and its answer.
struct ParsedReply: Equatable, Sendable {
    var reasoning: String?
    var content: String
    /// True while the model is still inside its reasoning (no answer text yet).
    var isReasoning: Bool

    static let empty = ParsedReply(reasoning: nil, content: "", isReasoning: false)
}

/// Separates reasoning from the answer for the reasoning formats in current open models:
/// `<think>…</think>` (Qwen3.5 family, Granite 4.2, LFM), Gemma 4 thought channels
/// (`<|channel>thought…<channel|>`), gpt-oss Harmony channels (analysis / final) and
/// Muse Glimmer's `to=self` messages. Works on partial text while streaming.
enum ReasoningParser {
    static func parse(_ raw: String, opensInReasoning: Bool = false) -> ParsedReply {
        if raw.contains("<|channel|>") { return parseHarmony(raw) }
        if raw.contains("<|message|>") { return parseAddressedMessages(raw) }
        if raw.contains("<|channel>") || raw.contains("<channel|>") { return parseGemmaChannels(raw) }
        return parseThinkTags(raw, opensInReasoning: opensInReasoning)
    }

    // MARK: <think> … </think>

    static func parseThinkTags(_ raw: String, opensInReasoning: Bool) -> ParsedReply {
        var remaining = Substring(raw)
        var reasoning = ""
        var content = ""
        // A closing tag with no opening tag means the template opened the block in the prompt.
        var inReasoning = opensInReasoning || (raw.contains("</think>") && !raw.contains("<think>"))
        while !remaining.isEmpty {
            if inReasoning {
                if let close = remaining.range(of: "</think>") {
                    reasoning += remaining[..<close.lowerBound]
                    remaining = remaining[close.upperBound...]
                    inReasoning = false
                } else {
                    reasoning += remaining
                    remaining = ""
                }
            } else {
                if let open = remaining.range(of: "<think>") {
                    content += remaining[..<open.lowerBound]
                    remaining = remaining[open.upperBound...]
                    inReasoning = true
                } else {
                    content += remaining
                    remaining = ""
                }
            }
        }
        return finish(reasoning: reasoning, content: content, inReasoning: inReasoning)
    }

    // MARK: Gemma 4: <|channel>thought … <channel|>

    static func parseGemmaChannels(_ raw: String) -> ParsedReply {
        var remaining = Substring(raw)
        var reasoning = ""
        var content = ""
        var inReasoning = false
        while !remaining.isEmpty {
            if inReasoning {
                if let close = remaining.range(of: "<channel|>") {
                    reasoning += remaining[..<close.lowerBound]
                    remaining = remaining[close.upperBound...]
                    inReasoning = false
                } else {
                    reasoning += remaining
                    remaining = ""
                }
            } else if let open = remaining.range(of: "<|channel>") {
                content += remaining[..<open.lowerBound]
                remaining = remaining[open.upperBound...]
                inReasoning = true
                // Drop the channel name ("thought") that follows the marker.
                if remaining.hasPrefix("thought") { remaining = remaining.dropFirst("thought".count) }
            } else {
                content += remaining.replacingOccurrences(of: "<channel|>", with: "")
                remaining = ""
            }
        }
        return finish(reasoning: reasoning, content: content, inReasoning: inReasoning)
    }

    // MARK: gpt-oss Harmony: <|channel|>analysis<|message|>…<|end|>

    static func parseHarmony(_ raw: String) -> ParsedReply {
        var reasoning = ""
        var content = ""
        var inReasoning = false
        for segment in raw.components(separatedBy: "<|start|>") {
            guard let channelMarker = segment.range(of: "<|channel|>") else {
                if !segment.contains("<|") { content += segment }
                continue
            }
            let afterChannel = segment[channelMarker.upperBound...]
            guard let messageMarker = afterChannel.range(of: "<|message|>") else {
                // Header still streaming.
                inReasoning = !afterChannel.hasPrefix("final")
                continue
            }
            let channel = afterChannel[..<messageMarker.lowerBound].trimmingCharacters(in: .whitespaces)
            // Calls to functions (tools) are shown as tool steps, not as reasoning.
            if segment[..<channelMarker.lowerBound].contains("to=functions") || channel.contains("to=functions") {
                continue
            }
            var body = afterChannel[messageMarker.upperBound...]
            var terminated = false
            for terminator in ["<|end|>", "<|return|>", "<|call|>"] {
                if let end = body.range(of: terminator) {
                    body = body[..<end.lowerBound]
                    terminated = true
                    break
                }
            }
            if channel.hasPrefix("final") {
                content += body
                inReasoning = false
            } else {
                reasoning += (reasoning.isEmpty ? "" : "\n\n") + body
                inReasoning = !terminated
            }
        }
        return finish(reasoning: reasoning, content: content, inReasoning: inReasoning && content.isEmpty)
    }

    // MARK: Muse Glimmer: <|start|>assistant to=self<|message|>…<|eom|>

    static func parseAddressedMessages(_ raw: String) -> ParsedReply {
        var reasoning = ""
        var content = ""
        var inReasoning = false
        for segment in raw.components(separatedBy: "<|start|>") where !segment.isEmpty {
            guard let messageMarker = segment.range(of: "<|message|>") else {
                inReasoning = segment.contains("to=self")
                continue
            }
            let header = segment[..<messageMarker.lowerBound]
            var body = segment[messageMarker.upperBound...]
            var terminated = false
            for terminator in ["<|eom|>", "<|eot|>"] {
                if let end = body.range(of: terminator) {
                    body = body[..<end.lowerBound]
                    terminated = true
                    break
                }
            }
            if header.contains("to=self") {
                reasoning += (reasoning.isEmpty ? "" : "\n\n") + body
                inReasoning = !terminated
            } else if !header.contains("to=") || header.contains("to=user") {
                content += body
                inReasoning = false
            }
        }
        return finish(reasoning: reasoning, content: content, inReasoning: inReasoning && content.isEmpty)
    }

    // MARK: Cleanup

    /// Control tokens that occasionally leak into rendered text.
    private static let leakedTokens = [
        "<|im_end|>", "<|im_start|>assistant", "<|eot_id|>", "<end_of_turn>", "<turn|>", "<|turn>model",
        "<|end|>", "<|return|>", "<|eot|>", "<|eom|>", "<|endoftext|>", "<|end_of_text|>", "</s>"
    ]

    static func clean(_ text: String) -> String {
        var result = text
        for token in leakedTokens where result.contains(token) {
            result = result.replacingOccurrences(of: token, with: "")
        }
        return result
    }

    private static func finish(reasoning: String, content: String, inReasoning: Bool) -> ParsedReply {
        let cleanedReasoning = clean(reasoning).trimmingCharacters(in: .whitespacesAndNewlines)
        var cleanedContent = clean(content)
        while cleanedContent.first?.isNewline == true || cleanedContent.first == " " {
            cleanedContent.removeFirst()
        }
        return ParsedReply(
            reasoning: cleanedReasoning.isEmpty && !inReasoning ? nil : cleanedReasoning,
            content: cleanedContent,
            isReasoning: inReasoning
        )
    }
}
