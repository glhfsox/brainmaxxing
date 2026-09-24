import Foundation

/// A tool the chat model may call, as listed by a `ToolProvider`.
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// What a tool returned: the text handed to the model and whether it is an error.
public struct ToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Source of tools for the chat loop. `MCPToolProvider` talks to `DigestMCP`; tests use fakes.
public protocol ToolProvider: Sendable {
    func listTools() async throws -> [ToolSpec]
    func call(_ name: String, input: JSONValue) async throws -> ToolResult
    /// Called once at the start of every user message (the MCP provider's restart budget is per message).
    func beginMessage() async
}

extension ToolProvider {
    public func beginMessage() async {}
}

/// What `ChatSession.send` streams to the UI, in order: deltas and tool events, then exactly one `.done` or `.error`.
public enum ChatEvent: Sendable, Equatable {
    case delta(String)
    case toolCall(name: String, input: JSONValue)
    case toolResult(name: String, summary: String, isError: Bool)
    /// The persisted assistant message.
    case done(ChatMessage)
    case error(String)
}

/// The `compact` tool's input (`schemas/compact.json`).
public struct CompactToolOutput: Codable, Sendable, Equatable {
    public var summary: String
    public init(summary: String) { self.summary = summary }
}

public enum ChatError: LocalizedError, Equatable {
    case toolServerUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .toolServerUnavailable(reason): "the paper tool server is not available: \(reason)"
        }
    }
}
