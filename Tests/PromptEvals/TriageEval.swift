import DigestCore
import Foundation
import Testing

/// Triage eval: each golden day is triaged twice with the pinned prompt through the production
/// `Triage.run` (same batching, request builder, validation and storage), then compared with the golden scores
/// and with itself.
@Suite(.serialized) struct TriageEval {
    static let topK = 15
    static let minJaccard = 0.7

    @Test(.enabled(if: PromptEvals.enabled, "set PROMPT_EVALS=1 to run live prompt evals"))
    func triageAgainstGolden() async throws {
        let env = try EvalEnv.shared.get()
        let prompt = try PromptEvals.prompts().load("triage")
        let days = try GoldenDay.all()
        try #require(!days.isEmpty, "no golden days under \(PromptEvals.golden.path)")
        let spentBefore = try await env.spentUSD()

        for day in days {
            let config = day.appConfig(triageModel: prompt.model)
            let golden = Dictionary(day.triage.map { ($0.id, $0.score) }, uniquingKeysWith: { a, _ in a })
            try await env.store.upsertPapers(day.papers, runID: nil)

            var runs: [[String: TriageScore]] = []
            for r in 1...2 {
                let runID = "eval-triage-v\(prompt.version)-\(day.date)-r\(r)-\(UUID().uuidString.prefix(8))"
                try await env.store.startRun(id: runID, startedAt: Date(), force: true, since: nil, stages: [.triage])
                let outcome = try await Triage.run(papers: day.papers, prompt: prompt, config: config, llm: env.llm,
                                                   store: env.store, runID: runID)
                if let error = outcome.error { Issue.record("run \(r) on \(day.date): \(error.localizedDescription)") }
                runs.append(Dictionary(outcome.scores.map { ($0.paperID, $0) }, uniquingKeysWith: { a, _ in a }))
                print("[eval] triage v\(prompt.version) \(day.date) run \(r): scored \(outcome.scores.count)/\(day.papers.count), unscored \(outcome.unscored)")
            }

            let s1 = runs[0].mapValues(\.score), s2 = runs[1].mapValues(\.score)
            let top1 = EvalMetrics.topK(s1, papers: day.papers, k: Self.topK)
            let top2 = EvalMetrics.topK(s2, papers: day.papers, k: Self.topK)
            let topGolden = EvalMetrics.topK(golden, papers: day.papers, k: Self.topK)
            let jaccardRuns = EvalMetrics.jaccard(top1, top2)
            let oneLines = runs.flatMap { $0.values.map(\.oneLine) }

            var lines = [
                "[eval] triage v\(prompt.version) | \(day.date) | \(day.papers.count) papers | language \(config.language)",
                "[eval]   MAE vs golden          run1 \(EvalMetrics.f(EvalMetrics.mae(s1, golden)))  run2 \(EvalMetrics.f(EvalMetrics.mae(s2, golden)))",
                "[eval]   mean score             run1 \(EvalMetrics.f(EvalMetrics.mean(s1.values.map(Double.init)), 2))  run2 \(EvalMetrics.f(EvalMetrics.mean(s2.values.map(Double.init)), 2))  golden \(EvalMetrics.f(EvalMetrics.mean(golden.values.map(Double.init)), 2))",
                "[eval]   top-\(Self.topK) Jaccard         run1~run2 \(EvalMetrics.f(jaccardRuns))  run1~golden \(EvalMetrics.f(EvalMetrics.jaccard(top1, topGolden)))  run2~golden \(EvalMetrics.f(EvalMetrics.jaccard(top2, topGolden)))",
                "[eval]   run1~run2 within +/-1    \(EvalMetrics.f(EvalMetrics.agreement(s1, s2, tolerance: 1)))  exact \(EvalMetrics.f(EvalMetrics.agreement(s1, s2, tolerance: 0)))",
                "[eval]   vs golden within +/-1    run1 \(EvalMetrics.f(EvalMetrics.agreement(s1, golden, tolerance: 1)))  run2 \(EvalMetrics.f(EvalMetrics.agreement(s2, golden, tolerance: 1)))",
            ]
            if config.language == "ru" {
                lines.append("[eval]   one_line with Cyrillic \(EvalMetrics.f(EvalMetrics.cyrillicShare(oneLines))) (\(oneLines.filter(EvalMetrics.containsCyrillic).count)/\(oneLines.count))")
            }
            // A few one-liners to judge by eye: run 1's top 3 and 3 low scorers.
            let ranked = day.papers.compactMap { runs[0][$0.id] }.sorted { ($0.score, $1.paperID) > ($1.score, $0.paperID) }
            for s in ranked.prefix(3) + ranked.suffix(3) {
                lines.append("[eval]   sample \(s.score) \(s.paperID): \(s.oneLine)")
            }
            print(lines.joined(separator: "\n"))

            #expect(jaccardRuns >= Self.minJaccard, "top-\(Self.topK) Jaccard between runs on \(day.date) is \(jaccardRuns)")
        }
        let spent = try await env.spentUSD() - spentBefore
        print("[eval] triage v\(prompt.version) cost $\(EvalMetrics.f(spent, 4)) | eval process total $\(EvalMetrics.f(try await env.spentUSD(), 4)) of cap $\(EvalMetrics.f(PromptEvals.budgetUSD, 2))")
    }
}
