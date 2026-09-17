import Foundation
import GRDB

/// Chat conversations and messages (migration v4).
extension Store {
    static let generalConversationID = "general"

    /// Get-or-create the conversation for a digest date (`yyyy-MM-dd`); `nil` -> the `general` conversation.
    /// Ids are deterministic (`digest-<date>` / `general`), so the date and id conflicts coincide.
    public func conversation(forDigestDate date: String?) async throws -> String {
        let id = date.map { "digest-\($0)" } ?? Store.generalConversationID
        let title = date ?? "General"
        let now = Date()
        return try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO conversations (id, digest_date, title, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT DO NOTHING
                """, arguments: [id, date, title, now, now])
            return id
        }
    }

    /// Messages of a conversation, oldest first.
    public func messages(conversationID: String) async throws -> [ChatMessage] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY created_at, id",
                             arguments: [conversationID]).map(Store.chatMessage(from:))
        }
    }

    /// Persists a message and returns it with the assigned id. The conversation must exist.
    @discardableResult
    public func appendMessage(_ m: ChatMessage) async throws -> ChatMessage {
        let quotes = m.quotes.isEmpty ? nil : try Store.chatJSON(m.quotes)
        let toolCalls = m.toolCalls.isEmpty ? nil : try Store.chatJSON(m.toolCalls)
        return try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, content, quotes_json, tool_calls_json, model, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [m.conversationID, m.role.rawValue, m.content, quotes, toolCalls, m.model, m.createdAt])
            var saved = m
            saved.id = db.lastInsertedRowID
            try db.execute(sql: "UPDATE conversations SET updated_at = MAX(updated_at, ?) WHERE id = ?",
                           arguments: [m.createdAt, m.conversationID])
            return saved
        }
    }

    /// Full-text search over message content (prefix match on every word), best match first.
    public func searchChat(_ q: String, limit: Int) async throws -> [ChatMessage] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: q) else { return [] }
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT m.* FROM chat_messages m JOIN chat_messages_fts f ON f.rowid = m.id
                WHERE chat_messages_fts MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit]).map(Store.chatMessage(from:))
        }
    }

    private static func chatJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func chatMessage(from row: Row) throws -> ChatMessage {
        guard let id: Int64 = row["id"], let conversationID: String = row["conversation_id"],
              let roleRaw: String = row["role"], let role = ChatMessage.Role(rawValue: roleRaw),
              let content: String = row["content"], let createdAt: Date = row["created_at"] else {
            throw StoreError.corruptRow("chat_messages")
        }
        func decode<T: Decodable>(_ column: String, as: T.Type) throws -> T? {
            guard let json: String = row[column] else { return nil }
            do {
                return try JSONDecoder().decode(T.self, from: Data(json.utf8))
            } catch {
                throw StoreError.corruptRow("chat_messages.\(column): \(error.localizedDescription)")
            }
        }
        return ChatMessage(id: id, conversationID: conversationID, role: role, content: content,
                           quotes: try decode("quotes_json", as: [Quote].self) ?? [],
                           toolCalls: try decode("tool_calls_json", as: [ChatToolCall].self) ?? [],
                           model: row["model"], createdAt: createdAt)
    }
}
