import Foundation
import os

public enum PipelineError: LocalizedError {
    case alreadyCompletedToday(runID: String)
    case sourceFailed(SourceID, String)
    case noSourceSucceeded
    /// The source hit its page cap while still inside the window; papers older than `oldestFetched` were not fetched.
    case windowTruncated(source: SourceID, oldestFetched: Date?)
    /// `run --stage digest` found no finished run that reached `select`.
    case noRunToDigest
    /// An error recorded by an earlier invocation of the same run (re-run of the digest stage).
    case earlierStage(String)
    /// An unforced run skipped the digest: an earlier run today failed it with an error a retry would repeat.
    case digestFailedToday(runID: String, reason: String)
    /// The run's task was cancelled (`digest-cli` got SIGTERM / SIGINT); the run is stored as partial.
    case stoppedByUser

    public var errorDescription: String? {
        switch self {
        case let .alreadyCompletedToday(runID): "already completed today (run \(runID)); use --force to run again"
        case let .sourceFailed(source, reason): "source \(source.rawValue) failed: \(reason)"
        case .noSourceSucceeded: "no paper source succeeded"
        case let .windowTruncated(source, oldest):
            "source \(source.rawValue) hit its page cap; window truncated\(oldest.map { " at \($0.formatted(.iso8601))" } ?? "")"
        case .noRunToDigest: "no run has reached the select stage yet; run the pipeline first"
        case let .earlierStage(message): message
        case let .digestFailedToday(runID, reason):
            "digest skipped: run \(runID) failed it today with an error a retry would repeat (\(reason)); use --force to try again"
        case .stoppedByUser: "stopped by user"
        }
    }
}

/// fetch -> dedup -> triage -> select (carry-over pool) -> full text -> digest.
public struct Pipeline: Sendable {
    /// The last stage of a complete run: "done today" and `since` look at succeeded runs that reached it.
    public static let completionStage = Stage.digest

    private let store: Store
    private let sources: [PaperSource]
    private let llm: LLMClient
    private let prompts: PromptLoader
    private let config: Config
    private let fullText: FullTextFetcher?
    private let hfPapers: HFPapersClient?
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "pipeline")

    /// `fullText` nil: every paper goes to the digest with its abstract only (tests, offline runs). `hfPapers` nil: the
    /// digest's `<hf_papers>` is `(none)`. Sources other than arXiv are secondary: their failure never makes the run
    /// partial.
    public init(store: Store, sources: [PaperSource], llm: LLMClient, prompts: PromptLoader, config: Config, fullText: FullTextFetcher? = nil,
                hfPapers: HFPapersClient? = nil) {
        self.store = store
        self.sources = sources
        self.llm = llm
        self.prompts = prompts
        self.config = config
        self.fullText = fullText
        self.hfPapers = hfPapers
    }

    public func run(force: Bool, stages: Set<Stage> = .all, categories: [String]? = nil) async throws -> RunReport {
        let now = Date()
        let lastComplete = try await store.lastSuccessfulRun(reaching: Self.completionStage)
        if !force, let last = lastComplete, Calendar.current.isDate(last.startedAt, inSameDayAs: now) {
            throw PipelineError.alreadyCompletedToday(runID: last.id)
        }
        let since = Self.windowStart(now: now, lastCompleteRunStart: lastComplete?.startedAt, config: config)
        let runID = Self.makeRunID(now)
        try await store.startRun(id: runID, startedAt: now, force: force, since: since, stages: stages)
        Self.log.info("run \(runID, privacy: .public) since \(since, privacy: .public)")

        var report = RunReport(runID: runID)
        var promptVersions: [String: Int] = [:]
        do {
            try await RunContext.$runID.withValue(runID) {
                try await body(&report, &promptVersions, since: since, startedAt: now, stages: stages, categories: categories ?? config.categories,
                               force: force)
            }
        } catch {
            if Task.isCancelled { try await stop(report, promptVersions: promptVersions) }
            try? await store.finishRun(runID, status: .failed, partial: true, counts: report.counts, promptVersions: promptVersions,
                                       errorSummary: error.localizedDescription, finishedAt: Date())
            throw error
        }
        if Task.isCancelled { try await stop(report, promptVersions: promptVersions) }
        return try await finish(report, promptVersions: promptVersions)
    }

    /// `run --stage digest`: full text (only what is missing) and digest again for the latest finished run that
    /// reached `select`, under that run's id and date. Errors of its earlier stages carry over; its digest error doesn't.
    public func rerunDigest() async throws -> RunReport {
        guard let run = try await store.latestRun(reaching: .select) else { throw PipelineError.noRunToDigest }
        var report = RunReport(runID: run.id, counts: run.counts)
        for (stage, message) in run.errors where stage < .fulltext {
            report.errors[stage] = PipelineError.earlierStage(message)
            report.partial = true
        }
        // Fetch-stage warnings carry over; HF ones don't, HF is redone below.
        let hfPrefix = PipelineError.sourceFailed(.hfPapers, "").localizedDescription
        report.warnings = run.warnings.filter { !$0.hasPrefix(hfPrefix) }
        var promptVersions = run.promptVersions
        try await store.reopenRun(run.id)
        Self.log.info("re-running digest for run \(run.id, privacy: .public)")
        do {
            try await RunContext.$runID.withValue(run.id) {
                try await afterSelect(&report, &promptVersions, startedAt: run.startedAt, stages: [.fulltext, .digest], force: true)
            }
        } catch {
            if Task.isCancelled { try await stop(report, promptVersions: promptVersions) }
            try? await store.finishRun(run.id, status: .failed, partial: true, counts: report.counts, promptVersions: promptVersions,
                                       errorSummary: error.localizedDescription, finishedAt: Date())
            throw error
        }
        if Task.isCancelled { try await stop(report, promptVersions: promptVersions) }
        return try await finish(report, promptVersions: promptVersions)
    }

    /// A cancelled run: `stoppedByUser` on the first stage it had not reached, stored as partial, then thrown.
    /// The writes run in an unstructured task, which does not inherit the cancellation GRDB would refuse them for.
    private func stop(_ report: RunReport, promptVersions: [String: Int]) async throws -> Never {
        Self.log.notice("run \(report.runID, privacy: .public) stopped by user")
        var report = report
        report.partial = true
        try await Task { [report] in
            var report = report
            let reached = try await store.run(id: report.runID)?.lastStage
            let stage = Stage.pipelineStages.first { reached == nil || $0 > reached ?? .fetch } ?? .digest
            report.errors[stage] = PipelineError.stoppedByUser
            _ = try await finish(report, promptVersions: promptVersions)
        }.value
        throw PipelineError.stoppedByUser
    }

    private func finish(_ report: RunReport, promptVersions: [String: Int]) async throws -> RunReport {
        var report = report
        report.costByStage = try await store.costByStage(runID: report.runID)
        let lines = report.errors.sorted { $0.key < $1.key }.map { "\($0.key.rawValue): \($0.value.localizedDescription)" } + report.warnings
        let summary = lines.isEmpty ? nil : lines.joined(separator: "; ")
        try await store.finishRun(report.runID, status: report.partial ? .partial : .succeeded, partial: report.partial, counts: report.counts,
                                  promptVersions: promptVersions, errorSummary: summary, finishedAt: Date(),
                                  errors: report.errors.mapValues(\.localizedDescription), warnings: report.warnings)
        return report
    }

    /// `max(now - window_cap_days, lastCompleteRun.startedAt - announce_lag_days)`; the cap alone without a
    /// complete run. The lag re-fetches papers announced after the last run started.
    public static func windowStart(now: Date, lastCompleteRunStart: Date?, config: Config) -> Date {
        let cap = now.addingTimeInterval(-Double(config.windowCapDays) * 86_400)
        guard let last = lastCompleteRunStart else { return cap }
        return max(cap, last.addingTimeInterval(-Double(config.announceLagDays) * 86_400))
    }

    private func body(_ report: inout RunReport, _ promptVersions: inout [String: Int], since: Date, startedAt: Date, stages: Set<Stage>,
                      categories: [String], force: Bool) async throws {
        guard stages.contains(.fetch) else { return }

        // Fetch: a failed source is recorded, never fatal.
        let results = await withTaskGroup(of: (SourceID, Result<SourceFetch, any Error>).self) { group in
            for source in sources {
                group.addTask {
                    do { return (source.id, .success(try await source.fetch(since: since, categories: categories))) }
                    catch { return (source.id, .failure(error)) }
                }
            }
            var all: [(SourceID, Result<SourceFetch, any Error>)] = []
            for await r in group { all.append(r) }
            return all
        }
        var fetched: [RawPaper] = []
        var succeeded = 0
        for (id, result) in results {
            switch result {
            case let .success(result):
                fetched += result.papers
                succeeded += 1
                if id == .openalex {
                    report.counts.openalex = result.papers.count
                    report.counts.openalexMerged = result.merged
                    report.counts.openalexDropped = result.dropped
                    report.counts.openalexCapped = result.capped ? 1 : 0
                }
                if result.truncated {
                    // A truncated window is not a complete run: `since` must not advance past the gap.
                    report.errors[.fetch] = PipelineError.windowTruncated(source: id, oldestFetched: result.papers.map(\.updated).min())
                    report.partial = true
                }
            case let .failure(error):
                Self.log.error("source \(id.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                if id == .arxiv {
                    report.errors[.fetch] = PipelineError.sourceFailed(id, error.localizedDescription)
                    report.partial = true
                } else {
                    // Secondary source: a line in error_summary, never partial.
                    report.warnings.append(PipelineError.sourceFailed(id, error.localizedDescription).localizedDescription)
                }
            }
        }
        if succeeded == 0, !sources.isEmpty { report.errors[.fetch] = report.errors[.fetch] ?? PipelineError.noSourceSucceeded }
        try await dropDOICopies(&fetched, report: &report)
        report.counts.fetched = fetched.count

        // Dedup: arXiv id without version is the key; keep the newest version seen.
        let papers = Self.dedup(fetched)
        report.counts.deduped = papers.count
        try await store.upsertPapers(papers, runID: report.runID)
        // Novelty from the store: the lag overlap is fetched again but never re-scored.
        let untriaged = try await store.untriagedIDs(among: papers.map(\.id))
        let newPapers = papers.filter { untriaged.contains($0.id) }
        report.counts.new = newPapers.count
        try await store.updateRunCounts(report.runID, counts: report.counts)
        try await store.markStageReached(report.runID, stage: .dedup)

        guard stages.contains(.triage) else { return }
        if !newPapers.isEmpty {
            let prompt: Prompt
            do {
                prompt = try prompts.load("triage")
            } catch {
                report.errors[.triage] = error
                report.partial = true
                return
            }
            promptVersions[prompt.name] = prompt.version
            // Read once: the examples are frozen for the run so every batch reuses the cached system prefix.
            let examples = try await store.feedbackExamples(limit: 20)
            let outcome = try await Triage.run(papers: newPapers, prompt: prompt, config: config, llm: llm, store: store, runID: report.runID,
                                               feedbackExamples: examples)
            report.counts.triaged = outcome.scores.count
            report.counts.unscored = outcome.unscored
            if outcome.partial { report.partial = true }
            if let error = outcome.error { report.errors[.triage] = error }
            try await store.updateRunCounts(report.runID, counts: report.counts)
        }
        try await store.markStageReached(report.runID, stage: .triage)

        // Select from the carry-over pool: everything scored and not yet in a digest, inside the
        // window. Runs on whatever was scored, so a partial triage still yields a ranked list.
        guard stages.contains(.select) else { return }
        let pool = try await store.selectionPool(windowStart: since)
        let selected = Triage.select(pool.map { (paper: $0.paper, score: $0.score) }, topN: config.topN, minScore: config.minScore)
        try await store.markSelected(runID: report.runID, orderedIDs: selected)
        report.counts.selected = selected.count
        try await store.updateRunCounts(report.runID, counts: report.counts)
        try await store.markStageReached(report.runID, stage: .select)

        try await afterSelect(&report, &promptVersions, startedAt: startedAt, stages: stages, force: force)
    }

    /// DOI is the secondary dedup key: an OpenAlex row whose DOI an arXiv paper carries, fetched now or stored, is
    /// that paper's journal copy -> dropped, counted as `openalex_merged`. The other direction (arXiv copy of a stored journal
    /// paper) is handled by the selection pool, which skips such journal papers.
    private func dropDOICopies(_ fetched: inout [RawPaper], report: inout RunReport) async throws {
        let journalDOIs = fetched.filter { $0.source == .openalex }.compactMap(\.doi)
        guard !journalDOIs.isEmpty else { return }
        var arxivDOIs = Set(fetched.filter { ArxivClient.isArxivID($0.id) }.compactMap { $0.doi?.lowercased() })
        arxivDOIs.formUnion(try await store.arxivDOIs(among: journalDOIs))
        let before = fetched.count
        fetched.removeAll { $0.source == .openalex && $0.doi.map { arxivDOIs.contains($0.lowercased()) } == true }
        report.counts.openalex -= before - fetched.count
        report.counts.openalexMerged += before - fetched.count
    }

    /// Full text and digest for the run's stored selection. Neither stage can fail the run: the ranked list is
    /// already stored, so a failure here only makes the run partial. Unforced, the digest is skipped when an earlier run
    /// today failed it deterministically.
    private func afterSelect(_ report: inout RunReport, _ promptVersions: inout [String: Int], startedAt: Date, stages: Set<Stage>,
                             force: Bool) async throws {
        guard stages.contains(.fulltext) else { return }
        let selected = try await store.rankedPapers(runID: report.runID, selectedOnly: true)
        report.counts.fulltext = try await fetchFullTexts(selected)
        try await store.updateRunCounts(report.runID, counts: report.counts)
        try await store.markStageReached(report.runID, stage: .fulltext)

        guard stages.contains(.digest) else { return }
        if !force, let failed = try await store.deterministicDigestFailure(onDayOf: startedAt) {
            report.errors[.digest] = PipelineError.digestFailedToday(runID: failed.id, reason: failed.errors[.digest] ?? "unknown error")
            report.partial = true
            return
        }
        // The "nothing new" digest has no HF section.
        let hf = selected.isEmpty ? [] : try await hfSection(excluding: Set(selected.map(\.paper.id)), report: &report, startedAt: startedAt)
        do {
            let digest = try await writeDigest(selected, hf: hf, report: report, promptVersions: &promptVersions, startedAt: startedAt)
            report.counts.written = digest?.papers.filter { !$0.modelOmitted }.count ?? 0
            try await store.updateRunCounts(report.runID, counts: report.counts)
            try await store.markDigestFailure(report.runID, deterministic: nil)
            try await store.markStageReached(report.runID, stage: .digest)
        } catch {
            // A stop is not a digest failure: nothing to mark, `run` stores the run as stopped.
            if Task.isCancelled { throw PipelineError.stoppedByUser }
            Self.log.error("digest stage failed: \(error.localizedDescription, privacy: .public)")
            report.errors[.digest] = error
            report.partial = true
            try await store.markDigestFailure(report.runID, deterministic: Self.isDeterministic(error))
        }
    }

    /// HF Daily Papers for `<hf_papers>`: not in an earlier digest's HF section, not shown in an earlier
    /// digest's main list, not in today's ranked list. Kept papers are stored if absent. A failure is a line in `error_summary`, never partial.
    private func hfSection(excluding selected: Set<String>, report: inout RunReport, startedAt: Date) async throws -> [HFDailyPaper] {
        guard let hfPapers else { return [] }
        do {
            let excluded = try await store.hfSectionIDs(excludingRunID: report.runID)
                .union(try await store.shownPaperIDs()).union(selected)
            let (kept, failure) = await hfPapers.candidates(day: startedAt, excluding: excluded, topK: config.hfTopK)
            if let failure {
                if Task.isCancelled { throw PipelineError.stoppedByUser }
                Self.log.error("HF Daily Papers failed: \(failure.localizedDescription, privacy: .public); keeping \(kept.count)")
                report.warnings.append(PipelineError.sourceFailed(.hfPapers, failure.localizedDescription).localizedDescription)
            }
            try await store.insertPapersIfAbsent(kept.map { $0.rawPaper(listedOn: startedAt) })
            report.counts.hf = kept.count
            try await store.updateRunCounts(report.runID, counts: report.counts)
            return kept
        } catch {
            if Task.isCancelled { throw PipelineError.stoppedByUser }
            Self.log.error("HF Daily Papers failed: \(error.localizedDescription, privacy: .public)")
            report.warnings.append(PipelineError.sourceFailed(.hfPapers, error.localizedDescription).localizedDescription)
            return []
        }
    }

    /// Errors the same input reproduces (no retry the same day) vs. transient ones (transport, 5xx/529, stream
    /// error, budget) that a later fire may get past.
    static func isDeterministic(_ error: Error) -> Bool {
        switch error {
        case is DigestError, is DecodingError: true
        case let error as LLMError:
            if case .invalidToolInput = error { true } else { false }
        default: false
        }
    }

    /// Sequential (every arXiv request waits on the shared 3 s limiter); a paper whose text is already stored is
    /// not fetched again. Failures leave the paper abstract-only and are never fatal. Returns papers with text.
    private func fetchFullTexts(_ papers: [RankedPaper]) async throws -> Int {
        var count = 0
        for ranked in papers {
            let paper = ranked.paper
            // OpenAlex journal papers are abstract-only: `fulltext="none"` in the bundle.
            guard ArxivClient.isArxivID(paper.id) else { continue }
            if try await store.fullTextSource(paperID: paper.id) != nil {
                count += 1
                continue
            }
            guard let fullText else { continue }
            do {
                let result = try await fullText.fetch(paper)
                try await store.saveFullText(paperID: paper.id, text: result.text, source: result.source)
                try await store.saveFigures(paperID: paper.id, result.figures, source: result.source)
                count += 1
            } catch {
                Self.log.warning("no full text for \(paper.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return count
    }

    /// The stored digest, or nil when nothing was selected and the date already has an edition (no empty edition 2).
    private func writeDigest(_ selected: [RankedPaper], hf: [HFDailyPaper], report: RunReport, promptVersions: inout [String: Int],
                             startedAt: Date) async throws -> Digest? {
        let date = LocalDate.string(startedAt)
        var digest: Digest
        if selected.isEmpty, try await store.digest(date: date) != nil {
            return nil
        } else if selected.isEmpty {
            // "Nothing new": no LLM call.
            let (title, summary) = DigestWriter.emptyTitleAndSummary(counts: report.counts, config: config)
            digest = Digest(title: title, summary: summary, clusters: [], papers: [], hfSection: [], trendNotes: "", date: date,
                            runID: report.runID, generatedAt: Date(), partial: report.partial, empty: true, counts: report.counts,
                            promptVersion: nil, model: nil, costUSD: 0)
        } else {
            let prompt = try prompts.load("digest")
            promptVersions[prompt.name] = prompt.version
            if prompt.model != config.models.digest {
                Self.log.notice("digest prompt v\(prompt.version) was written for \(prompt.model, privacy: .public), config uses \(self.config.models.digest, privacy: .public)")
            }
            let papers = try await bundlePapers(selected)
            let bundle = DigestWriter.bundle(date: date, partial: report.partial,
                                             recentClusters: try await store.recentClusterNames(days: 7, before: date), papers: papers, hfPapers: hf)
            let request = try DigestWriter.request(prompt: prompt, system: try DigestWriter.systemText(prompt, config: config),
                                                   bundle: bundle, model: config.models.digest)
            let output = try await DigestWriter.call(request, toolName: prompt.toolName ?? "", llm: llm)
            let (clusters, digestPapers) = DigestWriter.normalize(output, papers: papers)
            digest = Digest(title: output.title.trimmingCharacters(in: .whitespacesAndNewlines),
                            summary: output.summary.trimmingCharacters(in: .whitespacesAndNewlines), clusters: clusters,
                            papers: digestPapers, hfSection: DigestWriter.normalizeHF(output.hfSection, listed: hf),
                            trendNotes: output.trendNotes.trimmingCharacters(in: .whitespacesAndNewlines), date: date,
                            runID: report.runID, generatedAt: Date(), partial: report.partial, empty: false, counts: report.counts,
                            promptVersion: prompt.version, model: config.models.digest, costUSD: 0)
        }
        digest.counts.written = digest.papers.filter { !$0.modelOmitted }.count
        digest.costUSD = try await store.costByStage(runID: report.runID).values.reduce(0, +)
        digest.edition = try await store.saveDigest(digest)
        return digest
    }

    func bundlePapers(_ selected: [RankedPaper]) async throws -> [BundlePaper] {
        var out: [BundlePaper] = []
        for ranked in selected {
            let id = ranked.paper.id
            let source = try await store.fullTextSource(paperID: id)
            let text = source == nil ? nil : try await store.fullText(paperID: id).map { FullText.truncate($0, maxChars: config.fulltextMaxChars) }
            out.append(BundlePaper(ranked: ranked, fullText: text, source: text == nil ? nil : source,
                                   figures: text == nil ? [] : try await store.figures(paperID: id)))
        }
        return out
    }

    static func dedup(_ papers: [RawPaper]) -> [RawPaper] {
        var best: [String: RawPaper] = [:]
        for p in papers {
            if let current = best[p.id], (current.version, current.updated) >= (p.version, p.updated) { continue }
            best[p.id] = p
        }
        return best.values.sorted { $0.id < $1.id }
    }

    static func makeRunID(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "\(f.string(from: date))-\(UUID().uuidString.prefix(4).lowercased())"
    }
}
