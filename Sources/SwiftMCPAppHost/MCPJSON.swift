import Foundation

/// A JSON value: message parameters, tool arguments, tool results and host context.
public enum MCPJSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MCPJSON])
    case object([String: MCPJSON])

    public subscript(key: String) -> MCPJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [MCPJSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: MCPJSON]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Encodes to compact JSON text with sorted keys.
    public func jsonString() -> String {
        guard let data = try? MCPJSON.encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes JSON text. Returns nil if it isn't valid JSON.
    public static func parse(_ text: String) -> MCPJSON? {
        try? JSONDecoder().decode(MCPJSON.self, from: Data(text.utf8))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

extension MCPJSON: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([MCPJSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: MCPJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Whole numbers are written without a fraction, so JSON-RPC ids round-trip as integers.
            if n.isFinite, n.rounded() == n, abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension MCPJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: MCPJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, MCPJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
