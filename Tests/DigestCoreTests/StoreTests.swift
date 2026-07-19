import Foundation
import Testing
@testable import DigestCore

func samplePaper(_ id: String, version: Int = 1, title: String = "A title", abstract: String = "An abstract.", updated: String = "2026-10-20T12:00:00Z") throws -> RawPaper {
    RawPaper(
        id: id, version: version, title: title, abstract: abstract, authors: ["Ada Lovelace"], categories: ["cs.LG", "cs.AI"],
        primaryCategory: "cs.LG", absURL: URL(string: "https://arxiv.org/abs/\(id)v\(version)"),
        pdfURL: URL(string: "https://arxiv.org/pdf/\(id)v\(version)"), published: try TestSupport.date("2026-10-19T12:00:00Z"),
        updated: try TestSupport.date(updated), source: .arxiv)
}

func tempStore() throws -> Store {
    try Store(url: TestSupport.tempDirectory().appendingPathComponent("digest.sqlite"))
}

@Suite struct StoreTests {
    @Test func migratesEmptyFile() async throws {
        let url = try TestSupport.tempDirectory().appendingPathComponent("nested/digest.sqlite")
        let store = try Store(url: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try await store.paperCount() == 0)
        #expect(try await store.lastRun() == nil)
        // Reopening an already-migrated file is a no-op.
        let again = try Store(url: url)
        #expect(try await again.paperCount() == 0)
    }

    @Test func upsertIsIdempotentAndKeepsNewestVersion() async throws {
        let store = try tempStore()
        let p = try samplePaper("2610.00001", version: 2, title: "Second version")
        try await store.upsertPapers([p], runID: nil)
        try await store.upsertPapers([p], runID: nil)
        #expect(try await store.paperCount() == 1)
        #expect(try await store.paper(id: "2610.00001") == p)

        // An older version does not overwrite; a newer one does.
        try await store.upsertPapers([try samplePaper("2610.00001", version: 1, title: "Old")], runID: nil)
        #expect(try await store.paper(id: "2610.00001")?.title == "Second version")
        try await store.upsertPapers([try samplePaper("2610.00001", version: 3, title: "Third")], runID: nil)
        #expect(try await store.paper(id: "2610.00001")?.title == "Third")
        #expect(try await store.paperCount() == 1)
    }

    @Test func ftsSearchHitsTitleAndAbstract() async throws {
        let store = try tempStore()
        try await store.upsertPapers([
            try samplePaper("2610.00001", title: "Sheaf neural networks", abstract: "We study diffusion."),
            try samplePaper("2610.00002", title: "Quantized attention", abstract: "Persistent homology of token embeddings."),
        ], runID: nil)
        #expect(try await store.searchPapers("sheaf").map(\.id) == ["2610.00001"])
        #expect(try await store.searchPapers("homology").map(\.id) == ["2610.00002"])
        #expect(try await store.searchPapers("diffus").map(\.id) == ["2610.00001"])
        #expect(try await store.searchPapers("nothing-like-this").isEmpty)
        // FTS stays in sync on update.
        try await store.upsertPapers([try samplePaper("2610.00001", version: 2, title: "Cellular sheaves", abstract: "Renamed.")], runID: nil)
        #expect(try await store.searchPapers("diffusion").isEmpty)
        #expect(try await store.searchPapers("cellular").map(\.id) == ["2610.00001"])
    }

    @Test func llmCallsAggregateCostToday() async throws {
        let store = try tempStore()
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        let usage = LLMUsage(inputTokens: 1000, outputTokens: 100)
        try await store.startRun(id: "r1", startedAt: now, force: true, since: nil, stages: .all)
        try await store.recordLLMCall(LLMCallRecord(runID: "r1", stage: .triage, model: "claude-haiku-5-5", promptName: "triage", promptVersion: 1, usage: usage, usdEstimate: 0.25, createdAt: now))
        try await store.recordLLMCall(LLMCallRecord(runID: "r1", stage: .triage, model: "claude-haiku-5-5", promptName: "triage", promptVersion: 1, usage: usage, usdEstimate: 0.5, createdAt: now))
        try await store.recordLLMCall(LLMCallRecord(runID: nil, stage: .triage, model: "claude-haiku-5-5", promptName: nil, promptVersion: nil, usage: usage, usdEstimate: 9, createdAt: startOfToday.addingTimeInterval(-3600)))
        #expect(abs(try await store.costSince(startOfToday) - 0.75) < 1e-9)
        #expect(abs((try await store.costByStage(runID: "r1")[.triage] ?? 0) - 0.75) < 1e-9)
        let days = try await store.dailyCosts(since: startOfToday.addingTimeInterval(-86400 * 2))
        #expect(days.count == 2)
        #expect(days.last?.calls == 2)
        #expect(try await store.llmCalls(runID: "r1").count == 2)
        // Chat calls (no run) count toward the day's total and are broken out as chatUSD.
        try await store.recordLLMCall(LLMCallRecord(runID: nil, stage: .chat, model: "claude-sonnet-5-5", promptName: "chat", promptVersion: 1, usage: usage, usdEstimate: 0.125, createdAt: now))
        let withChat = try #require(try await store.dailyCosts(since: startOfToday).last)
        #expect(abs(withChat.usd - 0.875) < 1e-9 && abs(withChat.chatUSD - 0.125) < 1e-9 && withChat.calls == 3)
    }

    @Test func pipelineStageSetsExcludeChat() {
        #expect(Set<Stage>.all == Set(Stage.pipelineStages) && !Set<Stage>.all.contains(.chat))
        #expect(Stage.digest.throughHere == .all)
        #expect(Stage.allCases.filter { !Stage.pipelineStages.contains($0) } == [.chat])
    }

    @Test func latestTriageIgnoresCarryOverCopies() async throws {
        let store = try tempStore()
        let t0 = try TestSupport.date("2026-10-20T03:00:00Z")
        try await store.upsertPapers([try samplePaper("2610.00001")], runID: nil)
        #expect(try await store.latestTriage(paperID: "2610.00001") == nil)
        try await store.startRun(id: "old", startedAt: t0, force: true, since: nil, stages: .all)
        try await store.saveTriageScores(runID: "old", [TriageScore(paperID: "2610.00001", score: 6, oneLine: "first", tags: ["a"], promptVersion: 1)])
        try await store.startRun(id: "mid", startedAt: t0.addingTimeInterval(86_400), force: true, since: nil, stages: .all)
        try await store.saveTriageScores(runID: "mid", [TriageScore(paperID: "2610.00001", score: 8, oneLine: "rescored", tags: ["b"], promptVersion: 2)])
        // A later run carries the score over when selecting the paper; the original row is still the answer.
        try await store.startRun(id: "new", startedAt: t0.addingTimeInterval(2 * 86_400), force: true, since: nil, stages: .all)
        try await store.markSelected(runID: "new", orderedIDs: ["2610.00001"])
        #expect(try await store.rankedPapers(runID: "new").first?.scoredInRunID == "mid")
        #expect(try await store.latestTriage(paperID: "2610.00001")
                == TriageScore(paperID: "2610.00001", score: 8, oneLine: "rescored", tags: ["b"], promptVersion: 2))
    }

    @Test func runLifecycleAndRankedPapers() async throws {
        let store = try tempStore()
        let start = try TestSupport.date("2026-10-21T03:00:00Z")
        try await store.startRun(id: "r1", startedAt: start, force: false, since: nil, stages: [.fetch, .triage])
        #expect(try await store.lastRun()?.status == .running)
        #expect(try await store.lastSuccessfulRun() == nil)
        try await store.upsertPapers([try samplePaper("2610.00001"), try samplePaper("2610.00002")], runID: "r1")
        try await store.saveTriageScores(runID: "r1", [
            TriageScore(paperID: "2610.00001", score: 4, oneLine: "meh", tags: ["x"], promptVersion: 1),
            TriageScore(paperID: "2610.00002", score: 9, oneLine: "great", tags: ["rl"], promptVersion: 1),
        ])
        try await store.markSelected(runID: "r1", orderedIDs: ["2610.00002"])
        var counts = RunCounts()
        counts.fetched = 2
        try await store.finishRun("r1", status: .succeeded, partial: false, counts: counts, promptVersions: ["triage": 1], errorSummary: nil, finishedAt: start.addingTimeInterval(60))
        let run = try #require(try await store.lastSuccessfulRun())
        #expect(run.counts.fetched == 2)
        #expect(run.promptVersions == ["triage": 1])
        let ranked = try await store.rankedPapers(runID: "r1")
        #expect(ranked.map(\.paper.id) == ["2610.00002", "2610.00001"])
        #expect(ranked.first?.rank == 1)
        #expect(ranked.first?.tags == ["rl"])
        #expect(try await store.rankedPapers(runID: "r1", selectedOnly: true).count == 1)
    }

    @Test func untriagedIDsIgnoresWhichRunScoredThem() async throws {
        let store = try tempStore()
        try await store.startRun(id: "r1", startedAt: Date(), force: true, since: nil, stages: .all)
        let ids = (1...3).map { String(format: "2610.%05d", $0) }
        try await store.upsertPapers(try ids.map { try samplePaper($0) }, runID: "r1")
        #expect(try await store.untriagedIDs(among: ids) == Set(ids))
        try await store.saveTriageScores(runID: "r1", [TriageScore(paperID: ids[0], score: 0, oneLine: "", tags: [], promptVersion: 1)])
        #expect(try await store.untriagedIDs(among: ids + [ids[1]]) == [ids[1], ids[2]])
        #expect(try await store.untriagedIDs(among: []).isEmpty)
        // More ids than one query chunk.
        let many = (0..<1200).map { String(format: "2611.%05d", $0) } + [ids[0]]
        #expect(try await store.untriagedIDs(among: many).count == 1200)
    }

    @Test func updateRunCountsAndLegacyCountsJSON() async throws {
        let store = try tempStore()
        try await store.startRun(id: "r1", startedAt: Date(), force: true, since: nil, stages: .all)
        var counts = RunCounts()
        counts.fetched = 7
        counts.new = 3
        try await store.updateRunCounts("r1", counts: counts)
        #expect(try await store.lastRun()?.counts == counts)
        #expect(try await store.lastRun()?.status == .running)
        // Rows written before `new` existed still decode.
        let legacy = try JSONDecoder().decode(RunCounts.self, from: Data(#"{"fetched":5,"deduped":5,"triaged":5,"unscored":0,"selected":2,"fulltext":0,"written":0}"#.utf8))
        #expect(legacy.fetched == 5 && legacy.new == 0 && legacy.selected == 2)
    }
}
