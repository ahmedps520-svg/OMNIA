import Foundation
import OrderedCollections

/// A tool OMNIA runs for the model.
protocol ChatTool: Sendable {
    var definition: ToolDefinition { get }
    /// SF Symbol shown next to the tool's steps.
    var symbol: String { get }
    /// "Calculating", "Searching your documents"… shown while the tool runs.
    var activity: String { get }
    func run(_ arguments: ToolArguments) async throws -> String
}

enum ToolError: LocalizedError {
    case missingArgument(String)
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): "The required argument “\(name)” is missing."
        case .unknownTool(let name): "There is no tool called “\(name)”."
        }
    }
}

/// One tool call made while writing a reply, as stored with the message.
struct ToolStep: Codable, Hashable, Identifiable, Sendable {
    /// The call's ID, echoed back to the model with the result.
    var id: String
    /// Which generation round of the reply made the call (calls in one round run together).
    var round: Int
    var name: String
    var argumentsJSON: String
    var result: String
    var failed: Bool
    var duration: Double
    /// What the model wrote before the call, e.g. "Let me check that."
    var preface: String?

    var call: ToolCall {
        ToolCall(id: id, name: name, arguments: (try? JSONValue.parse(argumentsJSON, lenient: true))?.objectValue ?? [:])
    }

    private static let presentation: [String: (symbol: String, title: String)] = [
        "calculator": ("function", "Calculated"),
        "current_datetime": ("calendar.badge.clock", "Checked the date and time"),
        "search_documents": ("doc.text.magnifyingglass", "Searched your documents"),
        "web_search": ("magnifyingglass", "Searched the web"),
        "open_url": ("safari", "Read a web page"),
        "run_code": ("play.rectangle", "Ran code")
    ]

    var symbol: String { failed ? "exclamationmark.triangle" : Self.presentation[name]?.symbol ?? "wrench.and.screwdriver" }
    var title: String { Self.presentation[name]?.title ?? "Used \(name)" }

    /// The most telling argument, e.g. the expression or the search terms.
    var subject: String? {
        let arguments = call.arguments
        for key in ["expression", "query", "url", "language", "timezone"] {
            if let text = arguments[key]?.stringValue, !text.isEmpty { return text }
        }
        return arguments.values.lazy.compactMap(\.stringValue).first
    }
}

enum ToolRunner {
    /// Results longer than this are cut so one tool can't fill the context window.
    static let resultLimit = 6_000

    static func run(_ call: ToolCall, round: Int, preface: String, tools: [any ChatTool]) async -> ToolStep {
        let started = ContinuousClock.now
        var result: String
        var failed = false
        if let tool = tools.first(where: { $0.definition.name == call.name }) {
            do {
                result = try await tool.run(call.arguments)
            } catch {
                result = "Error: \(error.localizedDescription)"
                failed = true
            }
        } else {
            result = "Error: \(ToolError.unknownTool(call.name).localizedDescription) Available tools: \(tools.map(\.definition.name).joined(separator: ", "))."
            failed = true
        }
        if result.count > resultLimit {
            result = String(result.prefix(resultLimit)) + "\n[Result shortened to \(resultLimit) characters.]"
        }
        return ToolStep(id: call.id, round: round, name: call.name, argumentsJSON: call.argumentsJSON, result: result,
                        failed: failed, duration: started.secondsElapsed, preface: preface.isEmpty ? nil : preface)
    }

    static func string(_ name: String, in arguments: ToolArguments) throws -> String {
        guard let value = arguments[name] else { throw ToolError.missingArgument(name) }
        switch value {
        case .string(let text): return text
        case .int, .double, .bool: return value.serialized
        default: throw ToolError.missingArgument(name)
        }
    }
}

// MARK: - Built-in tools

struct CalculatorTool: ChatTool {
    let symbol = "function"
    let activity = "Calculating"
    let definition = ToolDefinition(
        name: "calculator",
        description: "Evaluates an arithmetic expression exactly. Supports + - * / % ** ( ), sqrt, abs, round, floor, ceil, sin, cos, tan, log, ln, exp, min, max, pi and e.",
        parameters: ToolDefinition.schema([("expression", "string", "The expression, e.g. (17 * 23) / 4")], required: ["expression"]))

    func run(_ arguments: ToolArguments) async throws -> String {
        let expression = try ToolRunner.string("expression", in: arguments)
        return Calculator.format(try Calculator.evaluate(expression))
    }
}

struct DateTimeTool: ChatTool {
    let symbol = "calendar.badge.clock"
    let activity = "Checking the date and time"
    let definition = ToolDefinition(
        name: "current_datetime",
        description: "Returns the current date, time and time zone on the user's device.",
        parameters: ToolDefinition.schema([("timezone", "string", "Optional IANA time zone, e.g. Europe/London. Defaults to the device's.")],
                                          required: []))
    var now: @Sendable () -> Date = { Date() }

    func run(_ arguments: ToolArguments) async throws -> String {
        var zone = TimeZone.current
        if let requested = arguments["timezone"]?.stringValue, !requested.isEmpty {
            guard let named = TimeZone(identifier: requested) else { return "Unknown time zone “\(requested)”." }
            zone = named
        }
        let date = now()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEEE, d MMMM yyyy, HH:mm"
        let seconds = zone.secondsFromGMT(for: date)
        let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
        let iso = ISO8601DateFormatter()
        iso.timeZone = zone
        return "\(formatter.string(from: date)) (\(zone.identifier), \(offset)). ISO 8601: \(iso.string(from: date))"
    }
}

/// Searches the documents attached to the conversation. The chunks are prepared before the reply
/// starts, so the tool needs no database access while running. With meaning vectors and an
/// `embed` function it also finds passages that answer the query in other words.
struct DocumentSearchTool: ChatTool {
    let symbol = "doc.text.magnifyingglass"
    let activity = "Searching your documents"
    let indexed: IndexedChunks
    let embed: (@Sendable (String) async -> [Float]?)?
    let definition = ToolDefinition(
        name: "search_documents",
        description: "Searches the documents the user attached to this conversation and returns the most relevant passages.",
        parameters: ToolDefinition.schema([("query", "string", "What to look for")], required: ["query"]))

    init(indexed: IndexedChunks, embed: (@Sendable (String) async -> [Float]?)? = nil) {
        self.indexed = indexed
        self.embed = embed
    }

    /// Keyword search only.
    init(chunks: [DocumentChunk]) {
        self.init(indexed: IndexedChunks(chunks: chunks))
    }

    func run(_ arguments: ToolArguments) async throws -> String {
        let query = try ToolRunner.string("query", in: arguments)
        let vector = await embed?(query)
        let found = Retrieval.search(query, in: indexed.chunks, similarities: vector.map(indexed.similarities),
                                     limit: 5, characterBudget: 5_000)
        guard !found.isEmpty else { return "No matching passages." }
        return found.map { "[\($0.documentTitle), part \($0.index + 1)]\n\($0.text)" }.joined(separator: "\n\n")
    }
}
