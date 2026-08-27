import Foundation

/// Golden-day export for prompt evals. Layout under `<root>/<YYYY-MM-DD>/`:
/// `papers.json`, `triage_golden.json`, `selected.json`, `fulltext/<id>.txt`, `figures.json`, `config.json`.
/// `digest_golden.json` is the user's to add; an existing `triage_golden.json` (hand-edited) is never overwritten.
public enum Golden {
    /// `one_line` / `tags` are optional: hand-made or older files may omit them.
    public struct TriageEntry: Codable, Sendable, Equatable {
        public var id: String
        public var score: Int
        public var oneLine: String?
        public var tags: [String]?
        enum CodingKeys: String, CodingKey { case id, score, oneLine = "one_line", tags }
    }

    public struct FigureEntry: Codable, Sendable, Equatable {
        public var paperID: String
        public var index: Int
        public var caption: String
        enum CodingKeys: String, CodingKey { case paperID = "paper_id", index, caption }
    }

    public struct DayConfig: Codable, Sendable, Equatable {
        public var interestProfile: String
        public var language: String
        public var explanationLevel: String
        public var topN: Int
        public var minScore: Int
        enum CodingKeys: String, CodingKey {
            case interestProfile = "interest_profile", language, explanationLevel = "explanation_level", topN = "top_n", minScore = "min_score"
        }
    }

    /// `papers.json` dates are ISO 8601; decode with this.
    public static var decoder: JSONDecoder { Digest.decoder }
    public static var encoder: JSONEncoder { Digest.encoder }

    public struct Written: Sendable, Equatable {
        public var directory: URL
        public var keptExistingTriageGolden: Bool
    }

    /// Exports `runID` (a run that reached `select`). `config` is the current config: per-run config is not stored.
    public static func record(store: Store, runID: String, config: Config, root: URL) async throws -> Written {
        guard let run = try await store.run(id: runID) else { throw PipelineError.noRunToDigest }
        let dir = root.appendingPathComponent(LocalDate.string(run.startedAt), isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("fulltext"), withIntermediateDirectories: true)

        let listed = try await store.rankedPapers(runID: runID)
        let scored = listed.filter { $0.scoredInRunID == runID }
        // What triage saw: papers scored by this run plus the ones first seen here and left unscored.
        var seen = Dictionary(scored.map { ($0.paper.id, $0.paper) }, uniquingKeysWith: { a, _ in a })
        let firstSeen = try await store.papers(firstSeenIn: runID)
        let untriaged = try await store.untriagedIDs(among: firstSeen.map(\.id))
        for p in firstSeen where untriaged.contains(p.id) { seen[p.id] = p }
        try write(seen.values.sorted { $0.id < $1.id }, to: dir.appendingPathComponent("papers.json"))

        let triageURL = dir.appendingPathComponent("triage_golden.json")
        let keep = fm.fileExists(atPath: triageURL.path)
        if !keep {
            try write(scored.map { TriageEntry(id: $0.paper.id, score: $0.score, oneLine: $0.oneLine, tags: $0.tags) }.sorted { $0.id < $1.id }, to: triageURL)
        }

        let selected = listed.filter(\.selected).sorted { ($0.rank ?? .max) < ($1.rank ?? .max) }
        try write(selected.map(\.paper.id), to: dir.appendingPathComponent("selected.json"))

        var figures: [FigureEntry] = []
        for p in selected {
            guard let text = try await store.fullText(paperID: p.paper.id) else { continue }
            try Data(FullText.truncate(text, maxChars: config.fulltextMaxChars).utf8)
                .write(to: dir.appendingPathComponent("fulltext/\(FullText.fileSafe(p.paper.id)).txt"), options: .atomic)
            figures += try await store.figures(paperID: p.paper.id).map { FigureEntry(paperID: $0.paperID, index: $0.index, caption: $0.caption) }
        }
        try write(figures, to: dir.appendingPathComponent("figures.json"))
        try write(DayConfig(interestProfile: config.interestProfile, language: config.language, explanationLevel: config.explanationLevel,
                            topN: config.topN, minScore: config.minScore), to: dir.appendingPathComponent("config.json"))
        return Written(directory: dir, keptExistingTriageGolden: keep)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
