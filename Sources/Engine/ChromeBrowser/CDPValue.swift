import Foundation

/// CDPValue is private wire vocabulary; browser consumers never depend on protocol JSON.
enum CDPValue: Codable, Sendable, Equatable {
    case object([String: CDPValue]), array([CDPValue]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode([String: CDPValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([CDPValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> Self { object?[key] ?? .null }
    var object: [String: Self]? { if case .object(let value) = self { value } else { nil } }
    var array: [Self]? { if case .array(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var scalar: String? {
        switch self {
        case .string(let value): value
        case .bool(let value): String(value)
        case .number(let value): String(value)
        default: nil
        }
    }
}
