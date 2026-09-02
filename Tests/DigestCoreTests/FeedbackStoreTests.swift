import Foundation
import GRDB
import Security
import Testing
@testable import DigestCore

@Suite struct FeedbackStoreTests {
    func digest(_ date: String, paperIDs: [String], title: String = "T", partial: Bool = false) -> Digest {
        Digest(title: title, summary: "s", clusters: [],
               papers: paperIDs.map { DigestPaper(id: $0, clusterID: "", essence: "e", detail: "d", whyItMatters: "w",
                                                  caveats: "", figureIndex: 0, mermaid: "", title: "t", authors: [], score: 7, tags: [],
                                                  links: PaperLinks(abs: nil, html: nil, pdf: nil), figure: nil, modelOmitted: false) },
               hfSection: [], trendNotes: "", date: date, runID: "r1", generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
               partial: partial, empty: paperIDs.isEmpty, counts: RunCounts(), promptVersion: 1, model: "claude-opus-5-5", costUSD: 1)
    }

    func storeWithRun(papers ids: [String]) async throws -> Store {
        let store = try tempStore()
        try await store.upsertPapers(try ids.map { try samplePaper($0) }, runID: nil)
        try await store.startRun(id: "r1", startedAt: Date(), force: false, since: nil, stages: [.fetch])
        return store
    }

    @Test func v3AppliesOnTopOfV2() async throws {
        let url = try TestSupport.tempDirectory().appendingPathComponent("digest.sqlite")
        let pool = try DatabasePool(path: url.path)
        try Store.migrator.migrate(pool, upTo: "v2")
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO papers (id, version, title, abstract, authors, categories, published, updated, source)
                VALUES ('2610.00001', 1, 't', 'a', '[]', '[]', ?, ?, 'arxiv')
                """, arguments: [Date(), Date()])
            try db.execute(sql: "INSERT INTO digests (date, json, partial, empty, cost_usd, created_at) VALUES ('2026-10-21', ?, 0, 0, 0, ?)",
                           arguments: [#"{"title":"Old"}"#, Date()])
            try db.execute(sql: "INSERT INTO digest_papers (date, paper_id, rank, cluster_id) VALUES ('2026-10-21', '2610.00001', 1, 'c1')")
        }
        #expect(try await pool.read { db in try db.tableExists("feedback") } == false)
        try pool.close()

        let store = try Store(url: url)
        #expect(try await store.digestList() == [DigestListItem(date: "2026-10-21", title: "Old", partial: false, empty: false,
                                                                 paperCount: 1, unreadCount: 1)])
        try await store.setFeedback(paperID: "2610.00001", verdict: .up, digestDate: "2026-10-21")
        try await store.setRead(paperID: "2610.00001", read: true)
        #expect(try await store.feedback(paperIDs: ["2610.00001"]) == ["2610.00001": .up])
        #expect(try await store.digestList().first?.unreadCount == 0)
    }

    @Test func digestListNewestFirstWithUnreadCounts() async throws {
        let store = try await storeWithRun(papers: ["a1", "a2", "a3"])
        try await store.saveDigest(digest("2026-10-20", paperIDs: ["a1", "a2"], title: "Monday"))
        try await store.saveDigest(digest("2026-10-21", paperIDs: [], title: "Quiet", partial: true))
        try await store.saveDigest(digest("2026-10-22", paperIDs: ["a2", "a3"], title: "Wednesday"))
        try await store.setRead(paperID: "a2", read: true)
        try await store.setRead(paperID: "a2", read: true)  // idempotent

        #expect(try await store.digestList() == [
            DigestListItem(date: "2026-10-22", title: "Wednesday", partial: false, empty: false, paperCount: 2, unreadCount: 1),
            DigestListItem(date: "2026-10-21", title: "Quiet", partial: true, empty: true, paperCount: 0, unreadCount: 0),
            DigestListItem(date: "2026-10-20", title: "Monday", partial: false, empty: false, paperCount: 2, unreadCount: 1),
        ])
        #expect(try await store.digestList(limit: 1).map(\.date) == ["2026-10-22"])
        #expect(try await store.readPaperIDs(among: ["a1", "a2", "zz"]) == ["a2"])

        try await store.setRead(paperID: "a2", read: false)
        #expect(try await store.readPaperIDs(among: ["a1", "a2"]).isEmpty)
        #expect(try await store.digestList().first?.unreadCount == 2)
        #expect(try await store.paperCountTotal() == 3)
    }

    @Test func feedbackUpsertsAndClears() async throws {
        let store = try await storeWithRun(papers: ["a1", "a2"])
        try await store.setFeedback(paperID: "a1", verdict: .up, digestDate: "2026-10-22")
        try await store.setFeedback(paperID: "a2", verdict: .down, digestDate: nil)
        #expect(try await store.feedback(paperIDs: ["a1", "a2", "zz"]) == ["a1": .up, "a2": .down])

        try await store.setFeedback(paperID: "a1", verdict: .down, digestDate: "2026-10-22")
        try await store.setFeedback(paperID: "a2", verdict: nil, digestDate: nil)
        try await store.setFeedback(paperID: "a2", verdict: nil, digestDate: nil)  // clearing twice is fine
        #expect(try await store.feedback(paperIDs: ["a1", "a2"]) == ["a1": .down])
        #expect(try await store.feedback(paperIDs: []).isEmpty)
    }

    @Test func configSaveRoundTripsSortedAndPretty() throws {
        let home = try TestSupport.tempDirectory().appendingPathComponent("nested", isDirectory: true)
        var config = Config()
        config.categories = ["cs.LG"]
        config.topN = 9
        config.schedule.idleMinutes = 20
        try config.save(home: home)
        #expect(try Config.load(home: home) == config)

        let text = try String(contentsOf: home.appendingPathComponent("config.json"), encoding: .utf8)
        #expect(text.contains("\n  \"categories\""))
        let keys = ["announce_lag_days", "categories", "daily_budget_usd", "top_n", "window_cap_days"]
        let positions = keys.compactMap { text.range(of: "\"\($0)\"")?.lowerBound }
        #expect(positions.count == keys.count && positions == positions.sorted())

        config.topN = 3
        try config.save(home: home)  // overwrite
        #expect(try Config.load(home: home).topN == 3)
    }
}

/// Uses a throwaway service name; never touches `com.brainmaxxing.anthropic`.
@Suite(.serialized) struct KeychainStoreTests {
    @Test func saveUpdateDeleteRoundTrip() throws {
        let service = "com.brainmaxxing.tests.\(UUID().uuidString)"
        defer { try? KeychainStore.delete(service: service) }

        #expect(!KeychainStore.exists(service: service))
        try KeychainStore.save("sk-first", service: service)
        #expect(KeychainStore.exists(service: service))
        #expect(KeychainStore.read(service: service) == "sk-first")

        try KeychainStore.save("sk-second", service: service)  // update in place
        #expect(KeychainStore.read(service: service) == "sk-second")

        try KeychainStore.delete(service: service)
        #expect(!KeychainStore.exists(service: service))
        try KeychainStore.delete(service: service)  // deleting a missing item is not an error
    }

    @Test func nonInteractiveModeNeverPrompts() throws {
        let service = "com.brainmaxxing.tests.\(UUID().uuidString)"
        defer { try? KeychainStore.delete(service: service) }

        #expect(KeychainStore.readQuery(service: service, mode: .interactive)["u_AuthUI"] == nil)
        #expect(KeychainStore.readQuery(service: service, mode: .nonInteractive)["u_AuthUI"] as? String
            == "u_AuthUIF")
        #expect(try KeychainStore.read(service: service, mode: .nonInteractive) == nil)  // missing item: nil, not an error
        try KeychainStore.save("sk-own", service: service)  // created by this process: readable without a dialog
        #expect(try KeychainStore.read(service: service, mode: .nonInteractive) == "sk-own")

        for status in [errSecInteractionNotAllowed, errSecAuthFailed] {
            #expect(throws: LLMError.keychainInteractionRequired) { try KeychainStore.check(status, mode: .nonInteractive) }
            #expect(throws: Never.self) { try KeychainStore.check(status, mode: .interactive) }
        }
        #expect(throws: Never.self) { try KeychainStore.check(errSecItemNotFound, mode: .nonInteractive) }
    }
}
