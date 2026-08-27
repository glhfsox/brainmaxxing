import DigestCore
import Foundation

extension PromptEvals {
    /// The digest eval calls Opus (~$1-2 per golden day), so it needs its own opt-in on top of `PROMPT_EVALS=1`.
    static let digestEnabled = enabled && ProcessInfo.processInfo.environment["PROMPT_EVALS_DIGEST"] == "1"
    /// `PROMPT_EVALS_TRIAGE_VERSION=1` / `PROMPT_EVALS_DIGEST_VERSION=1` pin the version under test; unset -> highest.
    static var pins: [String: Int] {
        let env = ProcessInfo.processInfo.environment
        var pins: [String: Int] = [:]
        if let v = env["PROMPT_EVALS_TRIAGE_VERSION"].flatMap(Int.init) { pins["triage"] = v }
        if let v = env["PROMPT_EVALS_DIGEST_VERSION"].flatMap(Int.init) { pins["digest"] = v }
        return pins
    }
    /// Eval-only prompts (the digest grader) live next to the golden days, outside every target.
    static let graderPrompts = golden.appendingPathComponent("grader", isDirectory: true)
    /// Prompts under test. `PROMPT_EVALS_PROMPT_DIR` points at an unpublished candidate directory (same layout as
    /// `Sources/DigestCore/Prompts/`, e.g. `Tests/Fixtures/golden/candidates`) so a version is measured before it
    /// becomes the highest bundled file, i.e. current in production. Unset -> the bundled prompts.
    static func prompts() throws -> PromptLoader {
        if let dir = ProcessInfo.processInfo.environment["PROMPT_EVALS_PROMPT_DIR"], !dir.isEmpty {
            return PromptLoader(directory: URL(fileURLWithPath: dir, isDirectory: true), pins: pins)
        }
        return try PromptLoader.bundled(pins: pins)
    }
}

/// The eval harness never reads Keychain: a Keychain dialog would hang an unattended eval run.
struct MissingEvalAPIKey: LocalizedError {
    var errorDescription: String? { "prompt evals need ANTHROPIC_API_KEY in the environment; they never read Keychain" }
}

extension PromptEvals {
    static func apiKey() throws -> String {
        guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { throw MissingEvalAPIKey() }
        return key
    }
}

/// One temp `BRAINMAXXING_HOME` + store + cost meter for the whole test process, so `PROMPT_EVALS_BUDGET_USD`
/// caps the entire eval run, not each test. The client is built exactly as `digest-cli run` builds it.
struct EvalEnv: Sendable {
    let paths: AppPaths
    let store: Store
    let llm: AnthropicClient

    static let shared: Result<EvalEnv, any Error> = Result { try EvalEnv() }

    private init() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("brainmaxxing-evals-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(home: home)
        store = try Store(url: paths.database)
        let apiKey = try PromptEvals.apiKey()
        let meter = CostMeter(store: store, dailyBudgetUSD: PromptEvals.budgetUSD)
        llm = AnthropicClient(apiKey: apiKey, costMeter: meter)
    }

    /// Everything this eval process has spent so far (the store is fresh, so all of it is ours).
    func spentUSD() async throws -> Double { try await store.costSince(.distantPast) }
}

/// One recorded day under `Tests/Fixtures/golden/<YYYY-MM-DD>/`.
struct GoldenDay {
    /// `triage_golden.json` entry. `one_line` / `tags` are optional (`record-golden` writes them; older or
    /// hand-made files may not have them); the digest eval puts them into the bundle's `<triage>` element when present.
    struct TriageEntry: Decodable {
        var id: String
        var score: Int
        var oneLine: String?
        var tags: [String]?
        enum CodingKeys: String, CodingKey { case id, score, oneLine = "one_line", tags }
    }

    let date: String
    let directory: URL
    let papers: [RawPaper]
    let triage: [TriageEntry]
    let selected: [String]
    let figures: [Golden.FigureEntry]
    let config: Golden.DayConfig

    static func all() throws -> [GoldenDay] {
        let names = try FileManager.default.contentsOfDirectory(atPath: PromptEvals.golden.path)
        return try names.filter { $0.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil }.sorted().map {
            try GoldenDay(directory: PromptEvals.golden.appendingPathComponent($0, isDirectory: true))
        }
    }

    init(directory: URL) throws {
        func read<T: Decodable>(_ name: String, as: T.Type) throws -> T {
            try Golden.decoder.decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
        }
        self.directory = directory
        date = directory.lastPathComponent
        papers = try read("papers.json", as: [RawPaper].self)
        triage = try read("triage_golden.json", as: [TriageEntry].self)
        selected = try read("selected.json", as: [String].self)
        figures = try read("figures.json", as: [Golden.FigureEntry].self)
        config = try read("config.json", as: Golden.DayConfig.self)
    }

    func fullText(_ id: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent("fulltext/\(FullText.fileSafe(id)).txt"), encoding: .utf8)
    }

    /// The production config with this day's profile/language/levels; models follow the prompt under test.
    func appConfig(triageModel: String? = nil, digestModel: String? = nil) -> Config {
        var c = Config()
        c.interestProfile = config.interestProfile
        c.language = config.language
        c.explanationLevel = config.explanationLevel
        c.topN = config.topN
        c.minScore = config.minScore
        if let triageModel { c.models.triage = triageModel }
        if let digestModel { c.models.digest = digestModel }
        return c
    }
}

enum EvalMetrics {
    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? .nan : xs.reduce(0, +) / Double(xs.count) }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 1 : Double(a.intersection(b).count) / Double(union)
    }

    /// The production ranking (`Triage.select`: score desc, `updated` desc, id) cut at `k`, ignoring `min_score`
    /// so the set always has `k` members.
    static func topK(_ scores: [String: Int], papers: [RawPaper], k: Int) -> Set<String> {
        let scored = papers.compactMap { p in scores[p.id].map { (paper: p, score: $0) } }
        return Set(Triage.select(scored, topN: k, minScore: 0))
    }

    /// Mean |a - b| over ids present in both.
    static func mae(_ a: [String: Int], _ b: [String: Int]) -> Double {
        mean(a.compactMap { id, s in b[id].map { Double(abs(s - $0)) } })
    }

    /// Share of ids present in both whose scores differ by at most `tolerance`.
    static func agreement(_ a: [String: Int], _ b: [String: Int], tolerance: Int) -> Double {
        let diffs = a.compactMap { id, s in b[id].map { abs(s - $0) } }
        return diffs.isEmpty ? .nan : Double(diffs.filter { $0 <= tolerance }.count) / Double(diffs.count)
    }

    static func containsCyrillic(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    static func cyrillicShare(_ texts: [String]) -> Double {
        texts.isEmpty ? .nan : Double(texts.filter(containsCyrillic).count) / Double(texts.count)
    }

    static func f(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", x) }
}
