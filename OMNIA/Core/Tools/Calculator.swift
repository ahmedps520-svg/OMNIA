import Foundation

/// Evaluates arithmetic the way models write it (Python-like syntax), without `NSExpression`,
/// which raises Objective-C exceptions on malformed input.
///
/// Supports `+ - * / % ^ **`, parentheses, unary signs, scientific notation, the constants
/// `pi` / `π` / `e`, and the functions `sqrt cbrt abs round floor ceil sin cos tan asin acos
/// atan ln log log2 log10 exp min max pow`. Trigonometry is in radians.
enum Calculator {
    enum Failure: LocalizedError, Equatable {
        case empty
        case unexpected(String)
        case unknownName(String)
        case divisionByZero
        case undefined
        case tooLong

        var errorDescription: String? {
            switch self {
            case .empty: "The expression is empty."
            case .unexpected(let token): "Unexpected \(token) in the expression."
            case .unknownName(let name): "Unknown function or constant “\(name)”."
            case .divisionByZero: "Division by zero."
            case .undefined: "The result is undefined (for example, the square root of a negative number)."
            case .tooLong: "The expression is too long."
            }
        }
    }

    static func evaluate(_ expression: String) throws -> Double {
        guard expression.count <= 2_000 else { throw Failure.tooLong }
        var parser = Parser(tokens: try tokenize(expression))
        guard !parser.tokens.isEmpty else { throw Failure.empty }
        let value = try parser.expression()
        if let extra = parser.peek { throw Failure.unexpected(extra.description) }
        guard value.isFinite else { throw value.isNaN ? Failure.undefined : Failure.divisionByZero }
        return value
    }

    /// The result as a model-friendly string: integers without a fraction, otherwise up to
    /// 12 significant digits.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(format: "%.12g", value)
    }

    // MARK: Tokens

    enum Token: Equatable, CustomStringConvertible {
        case number(Double)
        case name(String)
        case symbol(Character)
        case power

        var description: String {
            switch self {
            case .number(let value): format(value)
            case .name(let name): "“\(name)”"
            case .symbol(let symbol): "“\(symbol)”"
            case .power: "“**”"
            }
        }
    }

    static func tokenize(_ text: String) throws -> [Token] {
        var tokens: [Token] = []
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
            } else if character.isNumber || (character == "." && index + 1 < characters.count && characters[index + 1].isNumber) {
                var end = index
                while end < characters.count, characters[end].isNumber || characters[end] == "." || characters[end] == "_" { end += 1 }
                // Exponent: 1e-3, 2.5E+8
                if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                    var exponentEnd = end + 1
                    if exponentEnd < characters.count, characters[exponentEnd] == "+" || characters[exponentEnd] == "-" { exponentEnd += 1 }
                    if exponentEnd < characters.count, characters[exponentEnd].isNumber {
                        end = exponentEnd
                        while end < characters.count, characters[end].isNumber { end += 1 }
                    }
                }
                let literal = String(characters[index..<end]).replacingOccurrences(of: "_", with: "")
                guard let value = Double(literal) else { throw Failure.unexpected("“\(literal)”") }
                tokens.append(.number(value))
                index = end
            } else if character.isLetter || character == "π" || character == "_" {
                var end = index
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" || characters[end] == "π" { end += 1 }
                tokens.append(.name(String(characters[index..<end]).lowercased()))
                index = end
            } else if character == "*" && index + 1 < characters.count && characters[index + 1] == "*" {
                tokens.append(.power)
                index += 2
            } else if "+-*/%^(),×÷−".contains(character) {
                switch character {
                case "×": tokens.append(.symbol("*"))
                case "÷": tokens.append(.symbol("/"))
                case "−": tokens.append(.symbol("-"))
                case "^": tokens.append(.power)
                default: tokens.append(.symbol(character))
                }
                index += 1
            } else {
                throw Failure.unexpected("“\(character)”")
            }
        }
        return tokens
    }

    // MARK: Grammar
    //
    // expression := term (("+" | "-") term)*
    // term       := unary (("*" | "/" | "%") unary)*
    // unary      := ("+" | "-") unary | power
    // power      := primary ("**" unary)?          right-associative, binds tighter than unary minus
    // primary    := number | name | name "(" arguments ")" | "(" expression ")"

    struct Parser {
        let tokens: [Token]
        var position = 0

        var peek: Token? { position < tokens.count ? tokens[position] : nil }

        mutating func next() -> Token? {
            defer { position += 1 }
            return peek
        }

        mutating func expression() throws -> Double {
            var value = try term()
            while let token = peek, token == .symbol("+") || token == .symbol("-") {
                position += 1
                let rhs = try term()
                value = token == .symbol("+") ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() throws -> Double {
            var value = try unary()
            while let token = peek, token == .symbol("*") || token == .symbol("/") || token == .symbol("%") {
                position += 1
                let rhs = try unary()
                switch token {
                case .symbol("*"):
                    value *= rhs
                case .symbol("/"):
                    guard rhs != 0 else { throw Failure.divisionByZero }
                    value /= rhs
                default:
                    guard rhs != 0 else { throw Failure.divisionByZero }
                    // Python semantics: the result takes the sign of the divisor.
                    let remainder = value.truncatingRemainder(dividingBy: rhs)
                    value = remainder != 0 && (remainder < 0) != (rhs < 0) ? remainder + rhs : remainder
                }
            }
            return value
        }

        mutating func unary() throws -> Double {
            if peek == .symbol("-") {
                position += 1
                return -(try unary())
            }
            if peek == .symbol("+") {
                position += 1
                return try unary()
            }
            return try power()
        }

        mutating func power() throws -> Double {
            let base = try primary()
            if peek == .power {
                position += 1
                let exponent = try unary()
                let result = Foundation.pow(base, exponent)
                guard !result.isNaN else { throw Failure.undefined }
                return result
            }
            return base
        }

        mutating func primary() throws -> Double {
            guard let token = next() else { throw Failure.unexpected("end of expression") }
            switch token {
            case .number(let value):
                return value
            case .symbol("("):
                let value = try expression()
                guard next() == .symbol(")") else { throw Failure.unexpected("missing “)”") }
                return value
            case .name(let name):
                if peek == .symbol("(") {
                    position += 1
                    var arguments: [Double] = []
                    if peek != .symbol(")") {
                        arguments.append(try expression())
                        while peek == .symbol(",") {
                            position += 1
                            arguments.append(try expression())
                        }
                    }
                    guard next() == .symbol(")") else { throw Failure.unexpected("missing “)”") }
                    return try call(name, arguments)
                }
                switch name {
                case "pi", "π": return Double.pi
                case "e": return M_E
                case "tau": return 2 * Double.pi
                default: throw Failure.unknownName(name)
                }
            default:
                throw Failure.unexpected(token.description)
            }
        }

        private func call(_ name: String, _ arguments: [Double]) throws -> Double {
            func one() throws -> Double {
                guard arguments.count == 1 else { throw Failure.unexpected("\(arguments.count) arguments to \(name)()") }
                return arguments[0]
            }
            let result: Double
            switch name {
            case "sqrt": result = Foundation.sqrt(try one())
            case "cbrt": result = Foundation.cbrt(try one())
            case "abs": result = Swift.abs(try one())
            case "floor": result = Foundation.floor(try one())
            case "ceil": result = Foundation.ceil(try one())
            case "round":
                guard (1...2).contains(arguments.count) else { throw Failure.unexpected("\(arguments.count) arguments to round()") }
                let scale = arguments.count == 2 ? Foundation.pow(10, arguments[1].rounded()) : 1
                result = (arguments[0] * scale).rounded() / scale
            case "sin": result = Foundation.sin(try one())
            case "cos": result = Foundation.cos(try one())
            case "tan": result = Foundation.tan(try one())
            case "asin": result = Foundation.asin(try one())
            case "acos": result = Foundation.acos(try one())
            case "atan": result = Foundation.atan(try one())
            case "ln": result = Foundation.log(try one())
            case "log":
                if arguments.count == 2 {
                    result = Foundation.log(arguments[0]) / Foundation.log(arguments[1])
                } else {
                    result = Foundation.log10(try one())
                }
            case "log10": result = Foundation.log10(try one())
            case "log2": result = Foundation.log2(try one())
            case "exp": result = Foundation.exp(try one())
            case "pow":
                guard arguments.count == 2 else { throw Failure.unexpected("\(arguments.count) arguments to pow()") }
                result = Foundation.pow(arguments[0], arguments[1])
            case "min":
                guard let value = arguments.min() else { throw Failure.unexpected("min() with no arguments") }
                result = value
            case "max":
                guard let value = arguments.max() else { throw Failure.unexpected("max() with no arguments") }
                result = value
            default:
                throw Failure.unknownName(name)
            }
            guard !result.isNaN else { throw Failure.undefined }
            return result
        }
    }
}
