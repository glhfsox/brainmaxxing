import Foundation
import MCP

/// Conversions between the MCP SDK's `Value` and our `JSONValue` (tool inputs, schemas).
extension JSONValue {
    public init(_ value: Value) {
        switch value {
        case .null: self = .null
        case let .bool(b): self = .bool(b)
        case let .int(i): self = .number(Double(i))
        case let .double(d): self = .number(d)
        case let .string(s): self = .string(s)
        case let .data(_, data): self = .string(data.base64EncodedString())
        case let .array(a): self = .array(a.map(JSONValue.init))
        case let .object(o): self = .object(o.mapValues(JSONValue.init))
        }
    }
}

extension Value {
    public init(_ json: JSONValue) {
        switch json {
        case .null: self = .null
        case let .bool(b): self = .bool(b)
        case let .number(n):
            if n.rounded() == n, abs(n) < 9.0e15 { self = .int(Int(n)) } else { self = .double(n) }
        case let .string(s): self = .string(s)
        case let .array(a): self = .array(a.map(Value.init))
        case let .object(o): self = .object(o.mapValues(Value.init))
        }
    }
}
