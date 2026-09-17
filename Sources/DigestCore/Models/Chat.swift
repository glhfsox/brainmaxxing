import Foundation

/// A fragment of a digest the user quoted into the chat.
public struct Quote: Codable, Sendable, Equatable {
    public var paperID: String
    public var title: String
    public var clusterID: String?
    public var text: String

    public init(paperID: String, title: String, clusterID: String?, text: String) {
        self.paperID = paperID
        self.title = title
        self.clusterID = clusterID
        self.text = text
    }
}

/// A tool call made while producing an assistant message, as persisted with that message.
public struct ChatToolCall: Codable, Sendable, Equatable {
    public var name: String
    public var input: JSONValue
    public var resultSummary: String
    public var isError: Bool

    public init(name: String, input: JSONValue, resultSummary: String, isError: Bool) {
        self.name = name
        self.input = input
        self.resultSummary = resultSummary
        self.isError = isError
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, summary }

    /// Assigned by `Store.appendMessage`; the value passed in is ignored.
    public var id: Int64
    public var conversationID: String
    public var role: Role
    public var content: String
    public var quotes: [Quote]
    public var toolCalls: [ChatToolCall]
    public var model: String?
    public var createdAt: Date

    public init(id: Int64 = 0, conversationID: String, role: Role, content: String, quotes: [Quote] = [],
                toolCalls: [ChatToolCall] = [], model: String? = nil, createdAt: Date) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.content = content
        self.quotes = quotes
        self.toolCalls = toolCalls
        self.model = model
        self.createdAt = createdAt
    }
}
