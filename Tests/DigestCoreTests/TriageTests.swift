import Foundation
import Testing
@testable import DigestCore

@Suite struct TriageTests {
    func papers(_ n: Int) throws -> [RawPaper] {
        try (0..<n).reversed().map { try samplePaper(String(format: "2610.%05d", $0)) }
    }

    @Test func batchesOf25SortedById() throws {
        let batches = Triage.batches(try papers(60))
        #expect(batches.map(\.count) == [25, 25, 10])
        let ids = batches.flatMap { $0 }.map(\.id)
        #expect(ids == ids.sorted())
        #expect(Triage.batches([]).isEmpty)
    }

    @Test func userTurnBytesAreDeterministicWithFixedKeyOrder() throws {
        var a = try samplePaper("2610.00002", title: "Second \"quoted\" / slash", abstract: "Line\nbreak ünïcode")
        a.categories = ["cs.AI", "cs.LG", "stat.ML"]
        a.primaryCategory = "cs.LG"
        a.authors = ["A1", "A2", "A3", "A4", "A5", "A6", "A7"]
        var b = try samplePaper("2610.00001", title: "First")
        b.authors = ["B1", "B2", "B3", "B4", "B5", "B6"]
        let json = try Triage.userTurnJSON([a, b])
        let expected = #"[{"id":"2610.00001","title":"First","abstract":"An abstract.","categories":["cs.LG","cs.AI"],"authors":["B1","B2","B3","B4","B5","B6"]},"#
            + #"{"id":"2610.00002","title":"Second \"quoted\" / slash","abstract":"Line\nbreak ünïcode","categories":["cs.LG","cs.AI","stat.ML"],"authors":["A1","A2","A3","A4","A5","A6","et al."]}]"#
        #expect(json == expected)
        #expect(try Triage.userTurnJSON([b, a]) == json)
        // Valid JSON.
        #expect((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])?.count == 2)
    }

    @Test func requestUsesPromptFileAndForcedNonStrictTool() throws {
        let prompt = try testTriagePrompt()
        let system = try Triage.systemText(prompt, config: Config(interestProfile: "likes RL", language: "en"))
        #expect(system == "Reader: likes RL\nExamples: (none yet)\nLanguage: en")
        let r = try Triage.request(batch: try papers(2), prompt: prompt, system: system, model: "claude-haiku-5-5")
        #expect(r.system == [LLMTextBlock(text: system, cache: true)])
        #expect(r.toolChoice == .tool("triage_result"))
        #expect(r.tools.first?.strict == false)
        #expect(r.tools.first?.description == "Triage batch.")
        #expect(r.promptName == "triage" && r.promptVersion == 1 && r.stage == .triage)
    }

    @Test func validationEnforcesLimitsAndLeavesMissingUnscored() throws {
        let batch = try papers(3)  // ids 2610.00000 ... 00002
        let result = TriageResult(results: [
            TriageItem(id: "2610.00002", oneLine: "  " + String(repeating: "x", count: 250) + " ", tags: [" RL ", "Agents", "", "a", "b", "c", "d"], score: 14),
            TriageItem(id: "2610.00000", oneLine: "ok", tags: [], score: -3),
            TriageItem(id: "2610.00000", oneLine: "duplicate", tags: [], score: 9),
            TriageItem(id: "9999.99999", oneLine: "not in batch", tags: [], score: 10),
        ])
        let (items, missing) = Triage.validate(result, batch: batch)
        #expect(missing == ["2610.00001"])
        #expect(items.map(\.id).sorted() == ["2610.00000", "2610.00002"])
        let top = try #require(items.first { $0.id == "2610.00002" })
        #expect(top.score == 10)
        #expect(top.oneLine.count == 200)
        #expect(top.tags == ["rl", "agents", "a", "b", "c"])
        #expect(items.first { $0.id == "2610.00000" }?.score == 0)
        #expect(items.first { $0.id == "2610.00000" }?.oneLine == "ok")
    }

    @Test func selectionTopNMinScoreAndTieBreak() throws {
        let older = try samplePaper("2610.00001", updated: "2026-10-19T00:00:00Z")
        let newer = try samplePaper("2610.00002", updated: "2026-10-20T00:00:00Z")
        let best = try samplePaper("2610.00003")
        let low = try samplePaper("2610.00004")
        let sameAsNewer = try samplePaper("2610.00000", updated: "2026-10-20T00:00:00Z")
        let scored = [(older, 7), (newer, 7), (best, 9), (low, 5), (sameAsNewer, 7)].map { (paper: $0.0, score: $0.1) }
        #expect(Triage.select(scored, topN: 15, minScore: 6) == ["2610.00003", "2610.00000", "2610.00002", "2610.00001"])
        #expect(Triage.select(scored, topN: 2, minScore: 6) == ["2610.00003", "2610.00000"])
        #expect(Triage.select(scored, topN: 15, minScore: 8) == ["2610.00003"])
        #expect(Triage.select(scored, topN: 15, minScore: 11).isEmpty)
    }

    @Test func runStoresScoresAndCountsUnscored() async throws {
        let store = try tempStore()
        let input = try papers(30)
        try await store.startRun(id: "r", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.upsertPapers(input, runID: "r")
        let llm = MockLLM { _, ids in
            TriageResult(results: scoreAll(ids).results.filter { $0.id != "2610.00007" })
        }
        let outcome = try await Triage.run(papers: input, prompt: try testTriagePrompt(), config: Config(), llm: llm, store: store, runID: "r")
        #expect(llm.requests.count == 2)
        #expect(outcome.scores.count == 29)
        #expect(outcome.unscored == 1)
        #expect(!outcome.partial)
        let stored = try await store.rankedPapers(runID: "r")
        #expect(stored.count == 29)
        #expect(!stored.contains { $0.paper.id == "2610.00007" })
        // Both batches send byte-identical system blocks (cacheable prefix).
        #expect(llm.requests[0].system == llm.requests[1].system)
    }

    @Test func maxTokensSplitsBatchAndCountsStillTruncatedHalfUnscored() async throws {
        let store = try tempStore()
        let input = try papers(25)
        try await store.startRun(id: "r", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.upsertPapers(input, runID: "r")
        // The full batch and the 13-paper half run out of tokens; the 12-paper half fits.
        let llm = MockLLM(stopReason: { $0.count > 12 ? "max_tokens" : "tool_use" }) { _, ids in scoreAll(ids) }
        let outcome = try await Triage.run(papers: input, prompt: try testTriagePrompt(), config: Config(), llm: llm, store: store, runID: "r")
        #expect(llm.requests.count == 3)  // 25, then 12 and 13 once each
        #expect(outcome.scores.count == 12)
        #expect(outcome.unscored == 13)
        #expect(!outcome.partial)
        #expect(try await store.rankedPapers(runID: "r").count == 12)
    }

    @Test(arguments: [401, 403])
    func authErrorStopsTheStage(status: Int) async throws {
        let store = try tempStore()
        let input = try papers(60)
        try await store.startRun(id: "r", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.upsertPapers(input, runID: "r")
        let llm = MockLLM { _, _ in throw LLMError.http(status: status, type: "authentication_error", message: "bad key") }
        let outcome = try await Triage.run(papers: input, prompt: try testTriagePrompt(), config: Config(), llm: llm, store: store, runID: "r")
        #expect(llm.requests.count == 1)
        #expect(outcome.partial)
        #expect(outcome.error as? LLMError == .http(status: status, type: "authentication_error", message: "bad key"))
    }

    @Test func otherHTTPErrorSkipsOnlyTheBatch() async throws {
        let store = try tempStore()
        let input = try papers(60)
        try await store.startRun(id: "r", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.upsertPapers(input, runID: "r")
        let llm = MockLLM { index, ids in
            if index == 0 { throw LLMError.http(status: 400, type: "invalid_request_error", message: "no") }
            return scoreAll(ids)
        }
        let outcome = try await Triage.run(papers: input, prompt: try testTriagePrompt(), config: Config(), llm: llm, store: store, runID: "r")
        #expect(llm.requests.count == 3)
        #expect(outcome.scores.count == 35)
        #expect(outcome.partial)
    }
}
