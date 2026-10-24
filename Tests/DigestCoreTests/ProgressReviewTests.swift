import Foundation
import Synchronization
import Testing
@testable import DigestCore

/// Progress report points below `Pipeline`, cancellation, `run --stage digest`.
@Suite struct ProgressReviewTests {
    /// The arXiv page loop reports through the task-local, also from a `TaskGroup` child (how `Pipeline` fetches).
    @Test func arxivPagesReportThroughTaskLocalInGroupChild() async throws {
        let store = try tempStore()
        try await store.startRun(id: "r", startedAt: Date(), force: true, since: nil, stages: .all)
        let log = ProgressLog()
        let reporter = ProgressReporter(store: store, runID: "r", onProgress: { log.append($0) })
        let transport = MockTransport([.init(status: 200, body: try TestSupport.fixture("arxiv/query-page0.xml")),
                                       .init(status: 200, body: try TestSupport.fixture("arxiv/query-page1.xml"))])
        let client = ArxivClient(transport: transport, rateLimiter: RateLimiter(minInterval: 3, sleep: { _ in }), pageSize: 100, maxPages: 2,
                                 sleep: { _ in })
        let since = try TestSupport.date("2026-10-20T16:00:00Z")
        let kept = await RunContext.$progress.withValue(reporter) {
            await withTaskGroup(of: Int.self) { group in
                group.addTask { (try? await client.fetch(since: since, categories: ["cs.LG"]).papers.count) ?? -1 }
                return await group.reduce(0, +)
            }
        }
        #expect(kept == 101)
        #expect(log.stage(.fetch).map(\.done) == [64, 101])
        #expect(try await store.run(id: "r")?.progress?.done == 101)
    }

    /// Cancels the run from inside the first triage call; triage then launches no further batch and the run still ends
    /// as stopped.
    final class CancellingLLM: LLMClient {
        let run = Mutex<Task<RunReport, any Error>?>(nil)
        func complete(_ request: LLMRequest) async throws -> LLMResponse {
            while run.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(1)) }
            run.withLock { $0?.cancel() }
            throw CancellationError()
        }
    }

    @Test func progressAfterCancellationStillEndsRunAsStopped() async throws {
        let store = try tempStore()
        let filler = try (0..<30).map { i in
            var p = try samplePaper(String(format: "2610.%04d0", 100 + i), title: "Filler \(i)")
            p.published = Date().addingTimeInterval(-86_400)
            return p
        }
        let llm = CancellingLLM()
        let log = ProgressLog()
        let pipeline = Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try digestPapers() + filler)], llm: llm,
                                prompts: PromptLoader(directory: try testPromptDirectory()), config: Config(), fullText: FakeFullText(),
                                onProgress: { log.append($0) })
        let task = Task { try await pipeline.run(force: true) }
        llm.run.withLock { $0 = task }
        await #expect(throws: PipelineError.self) { _ = try await task.value }

        #expect(log.stage(.triage).count == 2)  // the second batch's report runs in the cancelled task
        let record = try #require(try await store.lastRun())
        #expect(record.status == .partial && record.partial && record.finishedAt != nil)
        #expect(record.errors.values.contains("stopped by user"))
    }

    /// `run --stage digest` reports full text and digest under the old run id and leaves its earlier counts alone.
    @Test func rerunDigestReportsWithoutTouchingEarlierCounts() async throws {
        let store = try tempStore()
        let stopping = StagedLLM { _, _ in throw LLMError.budgetExceeded(spentUSD: 3.9, capUSD: 4) }
        let prompts = PromptLoader(directory: try testPromptDirectory())
        let first = try await Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try digestPapers())], llm: stopping,
                                       prompts: prompts, config: Config(), fullText: FakeFullText()).run(force: true)
        let before = try #require(try await store.run(id: first.runID))

        let log = ProgressLog()
        let rerun = try await Pipeline(store: store, sources: [], llm: StagedLLM(), prompts: prompts, config: Config(), fullText: FakeFullText(),
                                       onProgress: { log.append($0) }).rerunDigest()
        #expect(rerun.runID == first.runID)
        #expect(Set(log.all.map(\.stage)).isSubset(of: [.fulltext, .digest]))
        #expect(log.stage(.digest).count == 1)
        let after = try #require(try await store.run(id: first.runID))
        #expect(after.progress == log.all.last)
        for path: KeyPath<RunCounts, Int> in [\.fetched, \.deduped, \.new, \.triaged, \.selected] {
            #expect(after.counts[keyPath: path] == before.counts[keyPath: path])
        }
    }
}
