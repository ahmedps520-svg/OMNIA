import Foundation

/// Keeps a `<think>` block within a number of tokens. Templates of the Qwen3.5 family only switch
/// thinking on or off, so the model alone decides how long it thinks (often thousands of tokens);
/// with a budget, OMNIA ends the block itself the way Qwen's own guide caps thinking, and the
/// model goes on to answer. Templates that take an effort level (`reasoning_effort`) aren't
/// budgeted: they steer the length themselves.
struct ReasoningBudget: Equatable, Sendable {
    /// What OMNIA writes to end the block: a sentence that turns the model to its answer, then
    /// the closing marker.
    static let closing = "\n\nConsidering the limited time by the user, I have to give the solution based on the thinking directly now.\n</think>\n\n"

    /// Tokens the block may take.
    let limit: Int
    private(set) var inReasoning: Bool
    /// Tokens written inside the block so far.
    private(set) var spent = 0
    /// The block has ended, by the model or by OMNIA.
    private(set) var ended = false
    /// Still watching the start of the reply for the model to open a block itself.
    private var watchingStart: Bool
    private var start = ""
    private var recent = ""

    /// `inReasoning`: the prompt already opened the block (the template wrote `<think>`, or a
    /// continued reply stopped inside it). `replyStarted`: text was written before this request,
    /// so a block can no longer open.
    init(limit: Int, inReasoning: Bool, replyStarted: Bool = false) {
        self.limit = max(1, limit)
        self.inReasoning = inReasoning
        watchingStart = !inReasoning && !replyStarted
    }

    /// Spent and still open: OMNIA should end the block now.
    var isExhausted: Bool { inReasoning && !ended && spent >= limit }

    /// Takes one token's text (possibly empty, when it ends inside a UTF-8 sequence).
    mutating func observe(_ text: String) {
        guard !ended else { return }
        if !inReasoning {
            guard watchingStart else { return }
            start += text
            let trimmed = String(start.drop { $0.isWhitespace })
            if trimmed.hasPrefix("<think>") {
                inReasoning = true
                watchingStart = false
                recent = String(trimmed.dropFirst("<think>".count))
            } else if !"<think>".hasPrefix(trimmed) {
                // The reply began with something else: no block in this reply.
                watchingStart = false
            }
            return
        }
        spent += 1
        recent = String((recent + text).suffix(24))
        if recent.contains("</think>") {
            ended = true
        }
    }

    /// OMNIA wrote `closing`.
    mutating func end() {
        ended = true
    }
}

extension ReasoningEffort {
    /// Most tokens a `<think>` block may take for templates without an effort setting of their
    /// own; nil for no limit.
    var thinkingBudget: Int? {
        switch self {
        case .low: 1_024
        case .medium: 4_096
        case .high: nil
        }
    }
}
