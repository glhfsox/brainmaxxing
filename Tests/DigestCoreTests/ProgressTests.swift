import Foundation
import Synchronization
import Testing
@testable import DigestCore

/// Collects progress reports from any task.
final class ProgressLog: Sendable {
    private let state = Mutex<[RunProgress]>([])
    var all: [RunProgress] { state.withLock { $0 } }
    func append(_ p: RunProgress) { state.withLock { $0.append(p) } }
    func stage(_ stage: Stage) -> [RunProgress] { all.filter { $0.stage == stage } }
}

@Suite struct RunProgressTests {
    // Numbers stay below 1000 so the locale's grouping separator never shows up.
    @Test(arguments: [
        (RunProgress(stage: .fetch, done: 0, topic: "arXiv, OpenAlex"), "Fetching arXiv, OpenAlex..."),
        (RunProgress(stage: .fetch, done: 412, topic: "arXiv"), "Fetching arXiv: 412 papers so far"),
        (RunProgress(stage: .dedup, done: 400), "Deduplicating 400 papers..."),
        (RunProgress(stage: .triage, done: 0, total: 300, topic: "cs.LG"), "Triaged 0 of 300 new papers; now cs.LG"),
        (RunProgress(stage: .triage, done: 50, total: 300, topic: "cs.CV", theme: "diffusion, video"),
         "Triaged 50 of 300 new papers; now cs.CV; last batch: diffusion, video"),
        (RunProgress(stage: .select, done: 40), "Ranking 40 scored papers..."),
        (RunProgress(stage: .fulltext, done: 2, total: 12, theme: "Attention again"), "Reading full text 3 of 12: Attention again"),
        (RunProgress(stage: .digest, done: 0, total: 12, topic: "claude-opus-5-5"), "Writing the digest for 12 papers with claude-opus-5-5..."),
    ])
    func sentence(_ progress: RunProgress, _ expected: String) {
        #expect(progress.sentence == expected)
    }

    @Test func storeRoundTrip() async throws {
        let store = try tempStore()
        let progress = RunProgress(stage: .triage, done: 25, total: 60, topic: "cs.LG", theme: "agents, rl",
                                   updatedAt: Date(timeIntervalSince1970: 1_800_000_000.25))
        try await store.startRun(id: "r1", startedAt: Date(), force: true, since: nil, stages: .all)
        #expect(try await store.run(id: "r1")?.progress == nil)
        try await store.updateRunProgress("r1", progress: progress)
        #expect(try await store.run(id: "r1")?.progress == progress)
        #expect(try await store.lastRun()?.progress == progress)
    }

    @Test func shortTitle() {
        #expect(Pipeline.shortTitle("Short") == "Short")
        let long = String(repeating: "a", count: 120)
        #expect(Pipeline.shortTitle(long) == String(repeating: "a", count: 77) + "...")
    }

    @Test func triageReportsTopicAndPreviousBatchTags() async throws {
        let store = try tempStore()
        // 30 papers -> batches of 25 and 5. The first batch is mostly cs.CV; in the second, three papers have no
        // primary category and fall back to their first category, cs.LG, which outnumbers the two cs.CV ones.
        let papers = try (0..<30).map { i in
            var p = try samplePaper(String(format: "2610.%05d", i))
            switch i {
            case ..<20, 25..<27: p.primaryCategory = "cs.CV"
            case ..<25: p.primaryCategory = "cs.LG"
            default: p.primaryCategory = nil
            }
            return p
        }
        try await store.startRun(id: "r", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.upsertPapers(papers, runID: "r")
        let llm = MockLLM { call, ids in
            TriageResult(results: ids.map { id in
                TriageItem(id: id, oneLine: "why", tags: call == 0 ? ["Video", "diffusion", "agents", "video"] : ["other"], score: 5)
            })
        }
        let log = ProgressLog()
        let outcome = try await Triage.run(papers: papers, prompt: try testTriagePrompt(), config: Config(), llm: llm, store: store, runID: "r",
                                           progress: { log.append($0) })
        #expect(outcome.scores.count == 30)
        let reports = log.all
        #expect(reports.map(\.done) == [0, 25])
        #expect(reports.allSatisfy { $0.stage == .triage && $0.total == 30 })
        #expect(reports.map(\.topic) == ["cs.CV", "cs.LG"])
        #expect(reports[0].theme == nil)
        #expect(reports[1].theme == "video, diffusion, agents")
    }

    @Test func pipelineReportsEveryStage() async throws {
        let store = try tempStore()
        // The four digest papers (scores 9, 8, 7, 1) plus 30 score-0 papers: 34 new papers, two triage batches.
        let filler = try (0..<30).map { i in
            var p = try samplePaper(String(format: "2610.%04d0", 100 + i), title: "Filler \(i)")
            p.published = Date().addingTimeInterval(-86_400)
            return p
        }
        let papers = try digestPapers() + filler
        let log = ProgressLog()
        let pipeline = Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: papers)], llm: StagedLLM(),
                                prompts: PromptLoader(directory: try testPromptDirectory()), config: Config(), fullText: FakeFullText(),
                                onProgress: { log.append($0) })
        let report = try await pipeline.run(force: true)
        #expect(report.counts.new == 34)

        #expect(log.stage(.fetch).first == RunProgress(stage: .fetch, done: 0, topic: "arXiv", updatedAt: log.stage(.fetch)[0].updatedAt))
        #expect(log.stage(.fetch).last?.done == 34)
        #expect(log.stage(.dedup).map(\.done) == [34])
        let triage = log.stage(.triage)
        #expect(triage.map(\.done) == [0, 25])
        #expect(triage.allSatisfy { $0.total == 34 && $0.topic == "cs.LG" })
        #expect(triage.map(\.theme) == [nil, "tag"])
        let fulltext = log.stage(.fulltext)
        #expect(fulltext.count == report.counts.selected)
        #expect(fulltext.first?.theme == "Paper 2610.00019")
        #expect(fulltext.allSatisfy { $0.total == report.counts.selected })
        let digest = try #require(log.stage(.digest).first)
        #expect(digest.topic == Config().models.digest && digest.total == report.counts.selected && digest.done == 0)

        let stored = try #require(try await store.run(id: report.runID)?.progress)
        #expect(stored.stage == .digest)
        #expect(stored == log.all.last)
    }
}
