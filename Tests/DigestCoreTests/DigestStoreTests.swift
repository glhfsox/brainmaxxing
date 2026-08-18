import Foundation
import GRDB
import Testing
@testable import DigestCore

@Suite struct DigestStoreTests {
    func digest(_ date: String, runID: String = "r1", clusters: [String] = [], paperIDs: [String] = [], title: String = "T") -> Digest {
        Digest(title: title, summary: "about attention sinks", clusters: clusters.enumerated().map {
                   DigestCluster(id: "c\($0 + 1)", name: $1, paperIDs: paperIDs, narrative: "n") },
               papers: paperIDs.map { DigestPaper(id: $0, clusterID: "", essence: "e", detail: "quantization detail", whyItMatters: "w",
                                                  caveats: "", figureIndex: 0, mermaid: "", title: "t", authors: [], score: 7, tags: [],
                                                  links: PaperLinks(abs: nil, html: nil, pdf: nil), figure: nil, modelOmitted: false) },
               hfSection: [], trendNotes: "", date: date, runID: runID, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
               partial: false, empty: false, counts: RunCounts(), promptVersion: 1, model: "claude-opus-5-5", costUSD: 1.5)
    }

    @Test func v5KeepsDigestsAsEditionOneAndBackfillsShownPapers() async throws {
        let url = try TestSupport.tempDirectory().appendingPathComponent("digest.sqlite")
        let pool = try DatabasePool(path: url.path)
        try Store.migrator.migrate(pool, upTo: "v4")
        let json = String(decoding: try Digest.encoder.encode(digest("2026-10-20", clusters: ["Agents"], paperIDs: ["p1", "p2"])), as: UTF8.self)
        try await pool.write { db in
            try db.execute(sql: "INSERT INTO runs (id, started_at, status, stages) VALUES ('r1', ?, 'succeeded', 'digest')", arguments: [Date()])
            try db.execute(sql: "INSERT INTO digests (date, run_id, json, partial, empty, cost_usd, created_at) VALUES ('2026-10-20', 'r1', ?, 0, 0, 1.5, ?)",
                           arguments: [json, Date()])
            try db.execute(sql: "INSERT INTO digest_papers (date, paper_id, rank, cluster_id) VALUES ('2026-10-20', 'p1', 1, 'c1'), ('2026-10-20', 'p2', 2, 'c1')")
            try db.execute(sql: "INSERT INTO clusters (date, id, name, narrative) VALUES ('2026-10-20', 'c1', 'Agents', 'n')")
            try db.execute(sql: "INSERT INTO digests_fts (date, text) VALUES ('2026-10-20', 'quantization detail')")
        }
        try pool.close()
        let store = try Store(url: url)
        #expect(try await store.digestList() == [DigestListItem(date: "2026-10-20", edition: 1, title: "T", partial: false, empty: false,
                                                                paperCount: 2, unreadCount: 2)])
        #expect(try await store.digest(date: "2026-10-20")?.papers.map(\.id) == ["p1", "p2"])
        #expect(try await store.recentClusterNames(days: 7, before: "2026-10-21") == ["Agents"])
        #expect(try await store.searchDigests("quantiz").map(\.edition) == [1])
        let shown = try await store.pool.read { db in try String.fetchAll(db, sql: "SELECT paper_id || ' ' || first_shown_date FROM shown_papers ORDER BY paper_id") }
        #expect(shown == ["p1 2026-10-20", "p2 2026-10-20"])
        #expect(try await store.saveDigest(digest("2026-10-20", runID: "r1", paperIDs: ["p3"])) == 1)  // same run -> its edition
    }

    @Test func v2BackfillsLastStageOfV1Runs() async throws {
        let url = try TestSupport.tempDirectory().appendingPathComponent("digest.sqlite")
        let pool = try DatabasePool(path: url.path)
        try Store.migrator.migrate(pool, upTo: "v1")
        try await pool.write { db in
            for (id, status, stages) in [("a", "succeeded", "dedup,digest,fetch,fulltext,select,triage"), ("b", "succeeded", "dedup,fetch"),
                                         ("c", "partial", "dedup,fetch,select,triage"), ("d", "running", "dedup,fetch,select,triage")] {
                try db.execute(sql: "INSERT INTO runs (id, started_at, status, stages) VALUES (?, ?, ?, ?)", arguments: [id, Date(), status, stages])
            }
        }
        try pool.close()
        let store = try Store(url: url)
        #expect(try await store.run(id: "a")?.lastStage == .select)  // v1 runs never wrote a digest
        #expect(try await store.run(id: "b")?.lastStage == .dedup)
        #expect(try await store.run(id: "c")?.lastStage == .select)
        #expect(try await store.run(id: "d")?.lastStage == nil)
        #expect(try await store.lastSuccessfulRun(reaching: .digest) == nil)  // window falls back to the cap
        #expect(try await store.lastSuccessfulRun(reaching: .select)?.id == "a")
    }

    @Test func fullTextFilesAndSearch() async throws {
        let store = try tempStore()
        try await store.upsertPapers([try samplePaper("2610.00001")], runID: nil)
        #expect(try await store.fullText(paperID: "2610.00001") == nil)
        try await store.saveFullText(paperID: "2610.00001", text: "Full body mentions holonomy.", source: .pdf)
        #expect(try await store.fullText(paperID: "2610.00001") == "Full body mentions holonomy.")
        #expect(try await store.fullTextSource(paperID: "2610.00001") == .pdf)
        #expect(FileManager.default.fileExists(atPath: store.home.appendingPathComponent("fulltext/2610.00001.txt").path))
        #expect(try await store.searchPapers("holonomy").map(\.id) == ["2610.00001"])
    }

    @Test func figuresAreReplaced() async throws {
        let store = try tempStore()
        try await store.upsertPapers([try samplePaper("2610.00001")], runID: nil)
        let png = try TestSupport.fixture("fulltext/2610.28632v1.fig1.png")
        try await store.saveFigures(paperID: "2610.00001", [(png, "a"), (png, "b")], source: .html)
        try await store.saveFigures(paperID: "2610.00001", [(png, "c")], source: .html)
        let figures = try await store.figures(paperID: "2610.00001")
        #expect(figures == [Figure(paperID: "2610.00001", index: 1, path: "figures/2610.00001/1.png", caption: "c", source: .html)])
        #expect(!FileManager.default.fileExists(atPath: store.home.appendingPathComponent("figures/2610.00001/2.png").path))
    }

    @Test func digestEditionsFeedRecentClustersAndSearch() async throws {
        let store = try tempStore()
        try await store.startRun(id: "r1", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.startRun(id: "r2", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.saveDigest(digest("2026-10-12", clusters: ["Too old"], paperIDs: ["p0"]))
        try await store.saveDigest(digest("2026-10-18", clusters: ["Reward models", "Sinks"], paperIDs: ["p1", "p2"]))
        try await store.saveDigest(digest("2026-10-20", clusters: ["Agents"], paperIDs: ["p3", "p4"]))
        try await store.saveDigest(digest("2026-10-21", clusters: ["Today"], paperIDs: ["p5", "p6"], title: "first"))
        // Another run the same day adds edition 2; `digest(date:)` is the latest edition.
        #expect(try await store.saveDigest(digest("2026-10-21", runID: "r2", clusters: ["Today again"], paperIDs: ["p7", "p8"], title: "second")) == 2)
        #expect(try await store.digest(date: "2026-10-21")?.title == "second")
        #expect(try await store.latestDigest()?.edition == 2)
        var second = digest("2026-10-21", runID: "r2", clusters: ["Today again"], paperIDs: ["p7", "p8"], title: "second")
        second.edition = 2
        #expect(try await store.digest(date: "2026-10-21") == second)
        #expect(try await store.digest(date: "2026-10-21", edition: 1)?.title == "first")
        // The same run saving again (`run --stage digest`) replaces its own edition.
        #expect(try await store.saveDigest(digest("2026-10-21", runID: "r2", clusters: ["Today again"], paperIDs: ["p7"], title: "redo")) == 2)
        #expect(try await store.digestList().map(\.id) == ["2026-10-21#2", "2026-10-21", "2026-10-20", "2026-10-18", "2026-10-12"])
        #expect(try await store.recentClusterNames(days: 7, before: "2026-10-21") == ["Reward models", "Sinks", "Agents"])
        let hits = try await store.searchDigests("quantiz")
        #expect(Set(hits.map(\.date)) == ["2026-10-12", "2026-10-18", "2026-10-20", "2026-10-21"])
        #expect(Set(hits.filter { $0.date == "2026-10-21" }.map { "\($0.edition) \($0.title)" }) == ["1 first", "2 redo"])
        // Shown stays shown: p8 left edition 2 when it was redone, p5 is in edition 1; neither re-enters the pool.
        try await store.upsertPapers(try ["p5", "p8", "p9"].map { try samplePaper($0) }, runID: nil)
        try await store.saveTriageScores(runID: "r1", ["p5", "p8", "p9"].map { TriageScore(paperID: $0, score: 8, oneLine: "", tags: [], promptVersion: 1) })
        #expect(try await store.selectionPool(windowStart: .distantPast).map(\.paper.id) == ["p9"])
    }

    @Test func selectionPoolRules() async throws {
        let store = try tempStore()
        let t0 = try TestSupport.date("2026-10-15T00:00:00Z")
        try await store.startRun(id: "old", startedAt: t0, force: true, since: nil, stages: .all)
        try await store.startRun(id: "new", startedAt: t0.addingTimeInterval(86_400), force: true, since: nil, stages: .all)
        var stale = try samplePaper("2610.00002")
        stale.published = try TestSupport.date("2026-10-01T00:00:00Z")
        try await store.upsertPapers([try samplePaper("2610.00001"), stale, try samplePaper("2610.00003")], runID: nil)
        try await store.saveTriageScores(runID: "old", [TriageScore(paperID: "2610.00001", score: 5, oneLine: "old", tags: [], promptVersion: 1),
                                                        TriageScore(paperID: "2610.00002", score: 9, oneLine: "", tags: [], promptVersion: 1),
                                                        TriageScore(paperID: "2610.00003", score: 9, oneLine: "", tags: [], promptVersion: 1)])
        try await store.saveTriageScores(runID: "new", [TriageScore(paperID: "2610.00001", score: 8, oneLine: "rescored", tags: [], promptVersion: 2)])
        try await store.saveDigest(digest("2026-10-16", runID: "old", paperIDs: ["2610.00003"]))
        let pool = try await store.selectionPool(windowStart: try TestSupport.date("2026-10-10T00:00:00Z"))
        // Stale paper outside the window, digested paper excluded, newest score wins.
        #expect(pool.map(\.paper.id) == ["2610.00001"])
        #expect(pool.first?.score == 8 && pool.first?.scoredInRunID == "new")

        // Selecting a paper scored by another run copies its newest row into this run.
        try await store.startRun(id: "cur", startedAt: t0.addingTimeInterval(2 * 86_400), force: true, since: nil, stages: .all)
        try await store.markSelected(runID: "cur", orderedIDs: ["2610.00001"])
        let ranked = try await store.rankedPapers(runID: "cur")
        #expect(ranked.map(\.paper.id) == ["2610.00001"])
        #expect(ranked.first?.scoredInRunID == "new" && ranked.first?.oneLine == "rescored" && ranked.first?.rank == 1)
        // The copy is not a score: the pool still attributes the paper to "new"; re-marking replaces the copy.
        #expect(try await store.selectionPool(windowStart: .distantPast).first { $0.paper.id == "2610.00001" }?.scoredInRunID == "new")
        try await store.markSelected(runID: "cur", orderedIDs: [])
        #expect(try await store.rankedPapers(runID: "cur").isEmpty)
        #expect(try await store.untriagedIDs(among: ["2610.00001"]).isEmpty)
    }
}
