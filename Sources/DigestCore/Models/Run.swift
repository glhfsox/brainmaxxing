import Foundation

public enum Stage: String, Codable, Sendable, CaseIterable, Comparable {
    case fetch, dedup, triage, select, fulltext, digest
    /// LLM calls of the chat window (`llm_calls.stage`). Not a pipeline stage: never in `pipelineStages`,
    /// `Set<Stage>.all` or `throughHere`, and never a run's `last_stage`.
    case chat

    /// The stages a pipeline run goes through, in order.
    public static let pipelineStages: [Stage] = [.fetch, .dedup, .triage, .select, .fulltext, .digest]

    public static func < (lhs: Stage, rhs: Stage) -> Bool {
        allCases.firstIndex(of: lhs) ?? 0 < allCases.firstIndex(of: rhs) ?? 0
    }

    /// All pipeline stages up to and including `self`.
    public var throughHere: Set<Stage> { Set(Stage.pipelineStages.filter { $0 <= self }) }
}

extension Set where Element == Stage {
    /// Every pipeline stage (excludes `.chat`).
    public static var all: Set<Stage> { Set(Stage.pipelineStages) }
}

public enum RunStatus: String, Codable, Sendable {
    case running, succeeded, partial, failed
}

public struct RunCounts: Codable, Sendable, Equatable {
    public var fetched = 0
    public var deduped = 0
    /// Papers entering triage: fetched papers with no `triage_scores` row from any run.
    public var new = 0
    public var triaged = 0
    /// Input papers the model left out of its triage output (no score stored).
    public var unscored = 0
    public var selected = 0
    public var fulltext = 0
    public var written = 0
    /// OpenAlex rows kept.
    public var openalex = 0
    /// OpenAlex rows dropped as copies of arXiv papers.
    public var openalexMerged = 0
    /// OpenAlex rows dropped as retracted, paratext or unusable.
    public var openalexDropped = 0
    /// 1 when OpenAlex paging stopped at `openalex_max_per_run`.
    public var openalexCapped = 0
    /// HF Daily Papers kept for the digest's `<hf_papers>`.
    public var hf = 0

    public init() {}

    enum CodingKeys: String, CodingKey {
        case fetched, deduped, new, triaged, unscored, selected, fulltext, written
        case openalex, openalexMerged = "openalex_merged", openalexDropped = "openalex_dropped", openalexCapped = "openalex_capped", hf
    }

    /// Missing keys decode as 0, so rows written before a counter existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ key: CodingKeys) throws -> Int { try c.decodeIfPresent(Int.self, forKey: key) ?? 0 }
        fetched = try n(.fetched)
        deduped = try n(.deduped)
        new = try n(.new)
        triaged = try n(.triaged)
        unscored = try n(.unscored)
        selected = try n(.selected)
        fulltext = try n(.fulltext)
        written = try n(.written)
        openalex = try n(.openalex)
        openalexMerged = try n(.openalexMerged)
        openalexDropped = try n(.openalexDropped)
        openalexCapped = try n(.openalexCapped)
        hf = try n(.hf)
    }

    /// The secondary-source counters are written only when non-zero, so digests and runs without secondary sources keep their
    /// earlier JSON bytes.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for (key, value) in [(CodingKeys.fetched, fetched), (.deduped, deduped), (.new, new), (.triaged, triaged), (.unscored, unscored),
                             (.selected, selected), (.fulltext, fulltext), (.written, written)] {
            try c.encode(value, forKey: key)
        }
        for (key, value) in [(CodingKeys.openalex, openalex), (.openalexMerged, openalexMerged), (.openalexDropped, openalexDropped),
                             (.openalexCapped, openalexCapped), (.hf, hf)] where value != 0 {
            try c.encode(value, forKey: key)
        }
    }
}

public struct RunReport: Sendable {
    public var runID: String
    public var counts: RunCounts
    public var costByStage: [Stage: Double]
    public var partial: Bool
    public var errors: [Stage: any Error]
    /// Secondary-source failures (OpenAlex, HF): appended to `error_summary`, never `partial`.
    public var warnings: [String]

    public var totalCost: Double { costByStage.values.reduce(0, +) }

    public init(runID: String, counts: RunCounts = RunCounts(), costByStage: [Stage: Double] = [:], partial: Bool = false, errors: [Stage: any Error] = [:],
                warnings: [String] = []) {
        self.runID = runID
        self.counts = counts
        self.costByStage = costByStage
        self.partial = partial
        self.errors = errors
        self.warnings = warnings
    }
}

/// A stored run row.
public struct RunRecord: Sendable, Equatable {
    public var id: String
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: RunStatus
    public var partial: Bool
    public var force: Bool
    public var since: Date?
    public var counts: RunCounts
    public var promptVersions: [String: Int]
    /// The last stage the run completed (nil for runs that never got past a crash).
    public var lastStage: Stage?
    /// Error message per stage, as recorded when the run finished.
    public var errors: [Stage: String]
    public var errorSummary: String?
    /// Secondary-source failures of the run (not stage errors, never partial).
    public var warnings: [String] = []
    /// Where the run is right now (`runs.progress`); nil before the first step reports and for runs older than v8.
    public var progress: RunProgress?
}

/// Where a running pipeline is, for the person waiting on it. The pipeline writes it to `runs.progress` at every
/// step someone would wait on (a fetch page, a triage batch, a full text, the digest call); the app polls it and
/// `digest-cli` prints it. `sentence` is the one line every surface shows, so they never disagree.
public struct RunProgress: Codable, Sendable, Equatable {
    public var stage: Stage
    /// Units completed in the stage: papers for triage and full text, papers kept so far for fetch, 0 or 1 for digest.
    public var done: Int
    /// Units the stage has in all; nil while unknown (fetch).
    public var total: Int?
    /// What the current unit is about: the arXiv category most of the current triage batch is in ("cs.LG"), the
    /// sources being fetched ("arXiv, OpenAlex"), the digest model. Nil when the stage has no natural topic.
    public var topic: String?
    /// The theme of the current unit: the top tags the model gave the last scored batch ("diffusion models, video
    /// generation"), the title of the paper whose full text is being read.
    public var theme: String?
    public var updatedAt: Date

    public init(stage: Stage, done: Int, total: Int? = nil, topic: String? = nil, theme: String? = nil, updatedAt: Date = Date()) {
        self.stage = stage
        self.done = done
        self.total = total
        self.topic = topic
        self.theme = theme
        self.updatedAt = updatedAt
    }

    /// 0...1 when the total is known.
    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// One sentence for the toolbar, the sidebar and the CLI.
    public var sentence: String {
        let n = { (v: Int) in v.formatted(.number.grouping(.automatic)) }
        switch stage {
        case .fetch:
            return "Fetching \(topic ?? "papers")" + (done > 0 ? ": \(n(done)) papers so far" : "...")
        case .dedup:
            return "Deduplicating \(n(done)) papers..."
        case .triage:
            var s = "Triaged \(n(done)) of \(n(total ?? done)) new papers"
            if let topic { s += "; now \(topic)" }
            if let theme { s += "; last batch: \(theme)" }
            return s
        case .select:
            return "Ranking \(n(done)) scored papers..."
        case .fulltext:
            let current = min(done + 1, total ?? done + 1)
            return "Reading full text \(current) of \(n(total ?? current))" + (theme.map { ": \($0)" } ?? "")
        case .digest:
            return "Writing the digest for \(n(total ?? done)) papers" + (topic.map { " with \($0)" } ?? "") + "..."
        case .chat:
            return "Chat"
        }
    }
}

/// Task-local context of the run in progress, so that layers below `Pipeline` (LLM call records,
/// raw response archive) can tag their output with the run id without it being threaded through
/// every contract signature.
public enum RunContext {
    @TaskLocal public static var runID: String?
    /// The run's progress reporter (nil outside a pipeline run, e.g. `record-fixture`).
    @TaskLocal static var progress: ProgressReporter?
}
