import Foundation
import GRDB
import Testing
@testable import DigestCore

@Suite struct ChatStoreTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func v4AppliesOnTopOfV3() async throws {
        let url = try TestSupport.tempDirectory().appendingPathComponent("digest.sqlite")
        let pool = try DatabasePool(path: url.path)
        try Store.migrator.migrate(pool, upTo: "v3")
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO digests (date, json, partial, empty, cost_usd, created_at) VALUES ('2026-10-21', ?, 0, 0, 0, ?)",
                           arguments: [#"{"title":"Old"}"#, Date()])
        }
        #expect(try await pool.read { db in try db.tableExists("chat_messages") } == false)
        try pool.close()

        let store = try Store(url: url)
        #expect(try await store.digestList().map(\.date) == ["2026-10-21"])
        let conv = try await store.conversation(forDigestDate: "2026-10-21")
        try await store.appendMessage(ChatMessage(conversationID: conv, role: .user, content: "hello", createdAt: t0))
        #expect(try await store.messages(conversationID: conv).map(\.content) == ["hello"])
    }

    @Test func conversationGetOrCreate() async throws {
        let store = try tempStore()
        let a = try await store.conversation(forDigestDate: "2026-10-22")
        let b = try await store.conversation(forDigestDate: "2026-10-22")
        let c = try await store.conversation(forDigestDate: "2026-10-21")
        let g1 = try await store.conversation(forDigestDate: nil)
        let g2 = try await store.conversation(forDigestDate: nil)
        #expect(a == b)
        #expect(a != c)
        #expect(g1 == "general" && g2 == "general")
        #expect(try await store.pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") } == 3)
        #expect(try await store.pool.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM conversations WHERE digest_date IS NULL")
        } == "general")
    }

    @Test func appendAssignsIDsAndKeepsOrderPerConversation() async throws {
        let store = try tempStore()
        let day = try await store.conversation(forDigestDate: "2026-10-22")
        let general = try await store.conversation(forDigestDate: nil)
        let m1 = try await store.appendMessage(ChatMessage(id: 999, conversationID: day, role: .user, content: "q1", createdAt: t0))
        let m2 = try await store.appendMessage(ChatMessage(conversationID: day, role: .assistant, content: "a1",
                                                           model: "claude-sonnet-5-5", createdAt: t0))  // same timestamp: id breaks the tie
        try await store.appendMessage(ChatMessage(conversationID: general, role: .user, content: "other", createdAt: t0))
        let m3 = try await store.appendMessage(ChatMessage(conversationID: day, role: .summary, content: "s",
                                                           createdAt: t0.addingTimeInterval(60)))
        #expect(m1.id != 999 && m1.id < m2.id && m2.id < m3.id)

        let msgs = try await store.messages(conversationID: day)
        #expect(msgs == [m1, m2, m3])
        #expect(msgs.map(\.role) == [.user, .assistant, .summary])
        #expect(msgs[1].model == "claude-sonnet-5-5")
        #expect(try await store.messages(conversationID: general).map(\.content) == ["other"])
        #expect(try await store.messages(conversationID: "nope").isEmpty)
    }

    @Test func quotesAndToolCallsRoundTrip() async throws {
        let store = try tempStore()
        let conv = try await store.conversation(forDigestDate: "2026-10-22")
        let quotes = [Quote(paperID: "2610.00001", title: "Sparse MoE", clusterID: "c1", text: "routing collapses"),
                      Quote(paperID: "2610.00002", title: "No cluster", clusterID: nil, text: "x")]
        let calls = [ChatToolCall(name: "search_papers",
                                  input: .object(["query": .string("moe"), "limit": .number(5), "recent": .bool(true),
                                                  "cats": .array([.string("cs.LG")]), "none": .null]),
                                  resultSummary: "3 papers", isError: false),
                     ChatToolCall(name: "get_paper", input: .object([:]), resultSummary: "not found", isError: true)]
        let saved = try await store.appendMessage(ChatMessage(conversationID: conv, role: .assistant, content: "answer",
                                                              quotes: quotes, toolCalls: calls, model: "m", createdAt: t0))
        let loaded = try await store.messages(conversationID: conv)
        #expect(loaded == [saved])
        #expect(loaded.first?.quotes == quotes)
        #expect(loaded.first?.toolCalls == calls)
    }

    @Test func searchChatFindsMessageContent() async throws {
        let store = try tempStore()
        let conv = try await store.conversation(forDigestDate: nil)
        let hit = try await store.appendMessage(ChatMessage(conversationID: conv, role: .user,
                                                            content: "How does speculative decoding interact with MoE routing?", createdAt: t0))
        try await store.appendMessage(ChatMessage(conversationID: conv, role: .assistant, content: "Unrelated text about diffusion.", createdAt: t0))
        #expect(try await store.searchChat("speculative rout", limit: 10) == [hit])
        #expect(try await store.searchChat("transformers", limit: 10).isEmpty)
        #expect(try await store.searchChat("   ", limit: 10).isEmpty)
    }

    @Test func roleCheckAndForeignKeyAreEnforced() async throws {
        let store = try tempStore()
        await #expect(throws: (any Error).self) {
            try await store.appendMessage(ChatMessage(conversationID: "missing", role: .user, content: "x", createdAt: self.t0))
        }
        await #expect(throws: (any Error).self) {
            try await store.pool.write { db in
                try db.execute(sql: "INSERT INTO conversations (id, title, created_at, updated_at) VALUES ('c', 't', ?, ?)", arguments: [Date(), Date()])
                try db.execute(sql: "INSERT INTO chat_messages (conversation_id, role, content, created_at) VALUES ('c', 'system', 'x', ?)", arguments: [Date()])
            }
        }
    }
}
