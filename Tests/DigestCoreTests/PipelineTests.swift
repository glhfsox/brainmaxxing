import Foundation
import Synchronization
import Testing
@testable import DigestCore

/// Serves parsed fixture papers regardless of `since` (fixture dates are fixed, the test clock is not).
struct FixtureSource: PaperSource {
    let id: SourceID
    let papers: [RawPaper]
    var truncated = false
    func fetch(since: Date, categories: [String]) async throws -> SourceFetch { SourceFetch(papers: papers, truncated: truncated) }
}

struct FailingSource: PaperSource {
    var id = SourceID.openalex
    func fetch(since: Date, categories: [String]) async throws -> SourceFetch { throw ArxivError.badStatus(503) }
}

/// Reads the stored run counts while triage is in progress (stage progress).
final class CountsPeekingLLM: LLMClient {
    let store: Store
    let inner = MockLLM { _, ids in scoreAll(ids) }
    private let seen = Mutex<[RunCounts]>([])
    init(store: Store) { self.store = store }
    var countsSeen: [RunCounts] { seen.withLock { $0 } }
    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        if let counts = try await store.lastRun()?.counts { seen.withLock { $0.append(counts) } }
        return try await inner.complete(request)
    }
}

@Suite struct PipelineTests {
    let fixturePapers: [RawPaper]

    init() throws {
        fixturePapers = try ArxivClient.parse(try TestSupport.fixture("arxiv/query-page0.xml")).filter { $0.version == 1 }
    }

    func pipeline(store: Store, sources: [PaperSource], llm: LLMClient, config: Config = Config()) throws -> Pipeline {
        Pipeline(store: store, sources: sources, llm: llm, prompts: PromptLoader(directory: try testTriagePromptDirectory()), config: config)
    }

    func expectedSelection(_ papers: [RawPaper], config: Config = Config()) -> [String] {
        Triage.select(papers.map { (paper: $0, score: digitScore($0.id)) }, topN: config.topN, minScore: config.minScore)
    }

    @Test func fixtureRunProducesReportAndRankedList() async throws {
        let store = try tempStore()
        var dup = try #require(fixturePapers.first)
        dup.version = 2
        dup.title = "Revised title"
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let report = try await pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: fixturePapers + [dup])], llm: llm)
            .run(force: true, stages: Stage.select.throughHere)
        #expect(report.counts.fetched == 65)
        #expect(report.counts.deduped == 64)
        #expect(report.counts.triaged == 64)
        #expect(report.counts.unscored == 0)
        #expect(report.counts.selected == 15)
        #expect(!report.partial)
        #expect(report.errors.isEmpty)
        #expect(llm.requests.count == 3)  // 25 + 25 + 14
        #expect(try await store.paper(id: dup.id)?.title == "Revised title")

        let selected = try await store.rankedPapers(runID: report.runID, selectedOnly: true)
        #expect(selected.map(\.paper.id) == expectedSelection(fixturePapers))
        #expect(selected.map(\.rank) == Array(1...15).map(Optional.some))
        let run = try #require(try await store.lastRun())
        #expect(run.status == .succeeded)
        #expect(run.promptVersions == ["triage": 1])
        #expect(run.counts == report.counts)

        // A run through select only is not a complete day (completion is .digest); DigestPipelineTests covers "done today".
        #expect(try await store.lastSuccessfulRun(reaching: Pipeline.completionStage) == nil)
    }

    @Test func budgetHitMidTriageKeepsWhatWasScored() async throws {
        let store = try tempStore()
        let llm = MockLLM { index, ids in
            if index == 1 { throw LLMError.budgetExceeded(spentUSD: 4, capUSD: 4) }
            return scoreAll(ids)
        }
        let report = try await pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: fixturePapers)], llm: llm)
            .run(force: true, stages: Stage.select.throughHere)
        #expect(report.partial)
        #expect(report.counts.triaged == 25)
        #expect(llm.requests.count == 2)  // stops after the refused call
        #expect(report.errors[.triage] as? LLMError == .budgetExceeded(spentUSD: 4, capUSD: 4))
        let firstBatch = Array(Triage.batches(fixturePapers)[0])
        let stored = try await store.rankedPapers(runID: report.runID)
        #expect(Set(stored.map(\.paper.id)) == Set(firstBatch.map(\.id)))
        #expect(report.counts.selected == expectedSelection(firstBatch).count)
        #expect(try await store.lastRun()?.status == .partial)
        #expect(try await store.lastSuccessfulRun() == nil)
    }

    /// arXiv is the primary source: its failure makes the run partial, but what other sources returned is still ranked.
    /// (A secondary-source failure is not partial at all: SecondarySourcesPipelineTests.)
    @Test func failingSourceDoesNotFailRun() async throws {
        let store = try tempStore()
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let report = try await pipeline(store: store, sources: [FailingSource(id: .arxiv), FixtureSource(id: .openalex, papers: fixturePapers)], llm: llm)
            .run(force: true, stages: Stage.select.throughHere)
        #expect(report.counts.fetched == 64)
        #expect(report.counts.triaged == 64)
        #expect(report.errors[.fetch] != nil)
        #expect(report.errors[.triage] == nil)
        #expect(report.partial)
    }

    @Test func fetchOnlyStageMakesNoLLMCalls() async throws {
        let store = try tempStore()
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let report = try await pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: fixturePapers)], llm: llm)
            .run(force: true, stages: Stage.dedup.throughHere)
        #expect(report.counts.deduped == 64)
        #expect(report.counts.triaged == 0)
        #expect(llm.requests.isEmpty)
        #expect(try await store.paperCount() == 64)
        // A fetch-only run does not count as a completed day.
        #expect(try await store.lastSuccessfulRun(reaching: Pipeline.completionStage) == nil)
    }

    // MARK: Window and novelty

    @Test func windowStartWithAndWithoutLastRun() throws {
        let now = try TestSupport.date("2026-10-21T03:00:00Z")
        let config = Config()
        #expect(Pipeline.windowStart(now: now, lastCompleteRunStart: nil, config: config) == (try TestSupport.date("2026-10-14T03:00:00Z")))
        // Last run a day ago: reach back 4 days before it.
        #expect(Pipeline.windowStart(now: now, lastCompleteRunStart: try TestSupport.date("2026-10-20T03:00:00Z"), config: config)
            == (try TestSupport.date("2026-10-16T03:00:00Z")))
        // Last run 5 days ago: the 7-day cap wins over 9 days.
        #expect(Pipeline.windowStart(now: now, lastCompleteRunStart: try TestSupport.date("2026-10-16T03:00:00Z"), config: config)
            == (try TestSupport.date("2026-10-14T03:00:00Z")))
        var lag1 = config
        lag1.announceLagDays = 1
        #expect(Pipeline.windowStart(now: now, lastCompleteRunStart: try TestSupport.date("2026-10-20T03:00:00Z"), config: lag1)
            == (try TestSupport.date("2026-10-19T03:00:00Z")))
    }

    @Test func paperTriagedInRunOneIsFetchedAgainButNotRetriaged() async throws {
        let store = try tempStore()
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let first = try await pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: fixturePapers)], llm: llm)
            .run(force: true, stages: Stage.select.throughHere)
        #expect(first.counts.new == 64 && first.counts.triaged == 64)

        let fresh = try samplePaper("2610.99999")
        let second = try await pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: fixturePapers + [fresh])], llm: llm)
            .run(force: true, stages: Stage.select.throughHere)
        #expect(second.counts.fetched == 65)
        #expect(second.counts.deduped == 65)
        #expect(second.counts.new == 1)
        #expect(second.counts.triaged == 1)
        #expect(llm.requests.count == 3 + 1)
        // Only the fresh paper was scored by this run; carried-over selections keep their original run.
        let listed = try await store.rankedPapers(runID: second.runID)
        #expect(listed.filter { $0.scoredInRunID == second.runID }.map(\.paper.id) == ["2610.99999"])
        #expect(listed.filter { $0.scoredInRunID != second.runID }.allSatisfy { $0.selected && $0.scoredInRunID == first.runID })
        #expect(try await store.lastRun()?.counts.new == 1)
    }

    @Test func paperLeftOverFromPartialRunIsTriagedNextRun() async throws {
        let store = try tempStore()
        let stopping = MockLLM { index, ids in
            if index == 1 { throw LLMError.budgetExceeded(spentUSD: 4, capUSD: 4) }
            return scoreAll(ids)
        }
        let first = try await pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: fixturePapers)], llm: stopping)
            .run(force: true, stages: Stage.select.throughHere)
        #expect(first.partial && first.counts.triaged == 25)

        let llm = MockLLM { _, ids in scoreAll(ids) }
        let second = try await pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: fixturePapers)], llm: llm)
            .run(force: false, stages: Stage.select.throughHere)
        #expect(second.counts.new == 39)
        #expect(second.counts.triaged == 39)
        let firstBatch = Set(Triage.batches(fixturePapers)[0].map(\.id))
        let rescored = Set(try await store.rankedPapers(runID: second.runID).filter { $0.scoredInRunID == second.runID }.map(\.paper.id))
        #expect(rescored.isDisjoint(with: firstBatch))
        #expect(rescored.count == 39)
    }

    @Test func truncatedWindowMarksRunPartial() async throws {
        let store = try tempStore()
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let source = FixtureSource(id: .arxiv, papers: fixturePapers, truncated: true)
        let report = try await pipeline(store: store, sources: [source], llm: llm).run(force: true, stages: Stage.select.throughHere)
        #expect(report.partial)
        guard case let .windowTruncated(id, oldest)? = report.errors[.fetch] as? PipelineError else {
            Issue.record("expected windowTruncated, got \(String(describing: report.errors[.fetch]))")
            return
        }
        #expect(id == .arxiv)
        #expect(oldest == fixturePapers.map(\.updated).min())
        #expect(report.counts.triaged == 64)  // what was fetched is still ranked
        #expect(try await store.lastRun()?.status == .partial)
        #expect(try await store.lastSuccessfulRun(reaching: Pipeline.completionStage) == nil)  // `since` does not advance
    }

    @Test func runCountsAreStoredAfterEachStage() async throws {
        let store = try tempStore()
        let llm = CountsPeekingLLM(store: store)
        _ = try await pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: fixturePapers)], llm: llm)
            .run(force: true, stages: Stage.select.throughHere)
        let during = try #require(llm.countsSeen.first)
        #expect(during.fetched == 64 && during.deduped == 64 && during.new == 64)
        #expect(during.triaged == 0)
    }
}
