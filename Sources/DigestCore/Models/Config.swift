import Foundation

/// User configuration (`config.json`). Single source of truth for keys and defaults.
/// JSON keys are snake_case; missing keys take defaults; unknown keys are ignored.
public struct Config: Codable, Sendable, Equatable {
    public struct Models: Codable, Sendable, Equatable {
        public var triage: String
        public var digest: String
        public var chat: String

        public init(triage: String = "claude-haiku-5-5", digest: String = "claude-opus-5-5", chat: String = "claude-sonnet-5-5") {
            self.triage = triage
            self.digest = digest
            self.chat = chat
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Models()
            triage = try c.decodeIfPresent(String.self, forKey: .triage) ?? d.triage
            digest = try c.decodeIfPresent(String.self, forKey: .digest) ?? d.digest
            chat = try c.decodeIfPresent(String.self, forKey: .chat) ?? d.chat
        }
    }

    public struct Schedule: Codable, Sendable, Equatable {
        public var windowStart: Int
        public var windowEnd: Int
        public var showAt: Int
        public var idleMinutes: Int

        public init(windowStart: Int = 3, windowEnd: Int = 9, showAt: Int = 10, idleMinutes: Int = 15) {
            self.windowStart = windowStart
            self.windowEnd = windowEnd
            self.showAt = showAt
            self.idleMinutes = idleMinutes
        }

        enum CodingKeys: String, CodingKey {
            case windowStart = "window_start", windowEnd = "window_end", showAt = "show_at", idleMinutes = "idle_minutes"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Schedule()
            windowStart = try c.decodeIfPresent(Int.self, forKey: .windowStart) ?? d.windowStart
            windowEnd = try c.decodeIfPresent(Int.self, forKey: .windowEnd) ?? d.windowEnd
            showAt = try c.decodeIfPresent(Int.self, forKey: .showAt) ?? d.showAt
            idleMinutes = try c.decodeIfPresent(Int.self, forKey: .idleMinutes) ?? d.idleMinutes
        }
    }

    /// Secondary sources; arXiv is always on.
    public struct Sources: Codable, Sendable, Equatable {
        public var openalex: Bool
        public var hfPapers: Bool

        public init(openalex: Bool = true, hfPapers: Bool = true) {
            self.openalex = openalex
            self.hfPapers = hfPapers
        }

        enum CodingKeys: String, CodingKey { case openalex, hfPapers = "hf_papers" }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Sources()
            openalex = try c.decodeIfPresent(Bool.self, forKey: .openalex) ?? d.openalex
            hfPapers = try c.decodeIfPresent(Bool.self, forKey: .hfPapers) ?? d.hfPapers
        }
    }

    /// OpenAlex subfields: Artificial Intelligence, Computer Vision and Pattern Recognition, Geometry and Topology,
    /// Statistics and Probability.
    public static let defaultOpenAlexSubfields = ["1702", "1707", "2608", "2613"]

    public static let defaultCategories = [
        "cs.LG", "cs.AI", "cs.MA", "cs.CL", "cs.CV", "cs.RO", "math.DG", "math.AT", "math.PR", "math.ST", "stat.ML",
    ]

    public static let defaultInterestProfile = """
        ML engineer. Reads eagerly: LLM post-training and reasoning (RL for LLMs, reward models, test-time \
        compute), agents and tool use, multi-agent systems, efficient training and inference (quantization, \
        distillation, MoE), representation learning, geometric and topological methods in ML (differential \
        geometry, algebraic topology applied to representations or data), probability and statistics with direct \
        ML consequences. Skips: benchmark-only papers without a new method, domain applications with no \
        methodological novelty, surveys, position papers.
        """

    public var categories: [String]
    public var interestProfile: String
    public var topN: Int
    public var minScore: Int
    public var models: Models
    public var dailyBudgetUsd: Double
    public var schedule: Schedule
    public var language: String
    public var explanationLevel: String
    public var windowCapDays: Int
    /// Days the fetch window reaches back before the last complete run's start (arXiv announcement lag).
    public var announceLagDays: Int
    public var includeReversions: Bool
    public var promptPins: [String: Int]
    /// Per-paper full-text limit in the digest bundle (~ 12k tokens); the file on disk is never truncated.
    public var fulltextMaxChars: Int
    public var sources: Sources
    public var openalexSubfields: [String]
    /// OpenAlex rows read per run at most (raw rows, before drops).
    public var openalexMaxPerRun: Int
    /// HF Daily Papers kept for the digest's `<hf_papers>`.
    public var hfTopK: Int

    public init(
        categories: [String] = Config.defaultCategories,
        interestProfile: String = Config.defaultInterestProfile,
        topN: Int = 15,
        minScore: Int = 6,
        models: Models = Models(),
        dailyBudgetUsd: Double = 4.0,
        schedule: Schedule = Schedule(),
        language: String = "ru",
        explanationLevel: String = "engineer",
        windowCapDays: Int = 7,
        announceLagDays: Int = 4,
        includeReversions: Bool = false,
        promptPins: [String: Int] = [:],
        fulltextMaxChars: Int = 48_000,
        sources: Sources = Sources(),
        openalexSubfields: [String] = Config.defaultOpenAlexSubfields,
        openalexMaxPerRun: Int = 1000,
        hfTopK: Int = 10
    ) {
        self.categories = categories
        self.interestProfile = interestProfile
        self.topN = topN
        self.minScore = minScore
        self.models = models
        self.dailyBudgetUsd = dailyBudgetUsd
        self.schedule = schedule
        self.language = language
        self.explanationLevel = explanationLevel
        self.windowCapDays = windowCapDays
        self.announceLagDays = announceLagDays
        self.includeReversions = includeReversions
        self.promptPins = promptPins
        self.fulltextMaxChars = fulltextMaxChars
        self.sources = sources
        self.openalexSubfields = openalexSubfields
        self.openalexMaxPerRun = openalexMaxPerRun
        self.hfTopK = hfTopK
    }

    enum CodingKeys: String, CodingKey {
        case categories
        case interestProfile = "interest_profile"
        case topN = "top_n"
        case minScore = "min_score"
        case models
        case dailyBudgetUsd = "daily_budget_usd"
        case schedule
        case language
        case explanationLevel = "explanation_level"
        case windowCapDays = "window_cap_days"
        case announceLagDays = "announce_lag_days"
        case includeReversions = "include_reversions"
        case promptPins = "prompt_pins"
        case fulltextMaxChars = "fulltext_max_chars"
        case sources
        case openalexSubfields = "openalex_subfields"
        case openalexMaxPerRun = "openalex_max_per_run"
        case hfTopK = "hf_top_k"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? d.categories
        interestProfile = try c.decodeIfPresent(String.self, forKey: .interestProfile) ?? d.interestProfile
        topN = try c.decodeIfPresent(Int.self, forKey: .topN) ?? d.topN
        minScore = try c.decodeIfPresent(Int.self, forKey: .minScore) ?? d.minScore
        models = try c.decodeIfPresent(Models.self, forKey: .models) ?? d.models
        dailyBudgetUsd = try c.decodeIfPresent(Double.self, forKey: .dailyBudgetUsd) ?? d.dailyBudgetUsd
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? d.schedule
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        explanationLevel = try c.decodeIfPresent(String.self, forKey: .explanationLevel) ?? d.explanationLevel
        windowCapDays = try c.decodeIfPresent(Int.self, forKey: .windowCapDays) ?? d.windowCapDays
        announceLagDays = try c.decodeIfPresent(Int.self, forKey: .announceLagDays) ?? d.announceLagDays
        includeReversions = try c.decodeIfPresent(Bool.self, forKey: .includeReversions) ?? d.includeReversions
        promptPins = try c.decodeIfPresent([String: Int].self, forKey: .promptPins) ?? d.promptPins
        fulltextMaxChars = try c.decodeIfPresent(Int.self, forKey: .fulltextMaxChars) ?? d.fulltextMaxChars
        sources = try c.decodeIfPresent(Sources.self, forKey: .sources) ?? d.sources
        openalexSubfields = try c.decodeIfPresent([String].self, forKey: .openalexSubfields) ?? d.openalexSubfields
        openalexMaxPerRun = try c.decodeIfPresent(Int.self, forKey: .openalexMaxPerRun) ?? d.openalexMaxPerRun
        hfTopK = try c.decodeIfPresent(Int.self, forKey: .hfTopK) ?? d.hfTopK
    }

    /// Reads `config.json` from `home`; a missing file means all defaults.
    public static func load(home: URL) throws -> Config {
        let url = home.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw ConfigError.invalidFile(url.path, error.localizedDescription)
        }
    }

    /// Writes `config.json` into `home` atomically (pretty-printed, sorted keys), creating `home` if needed.
    public func save(home: URL) throws {
        let url = home.appendingPathComponent("config.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(self)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ConfigError.writeFailed(url.path, error.localizedDescription)
        }
    }
}

public enum ConfigError: LocalizedError, Equatable {
    case invalidFile(String, String)
    case writeFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case let .invalidFile(path, reason): "config file \(path) is invalid: \(reason)"
        case let .writeFailed(path, reason): "cannot write config file \(path): \(reason)"
        }
    }
}

/// Where brainmaxxing keeps its data. `BRAINMAXXING_HOME` overrides `~/Library/Application Support/brainmaxxing`.
public struct AppPaths: Sendable, Equatable {
    public let home: URL

    public init(home: URL) { self.home = home }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let custom = environment["BRAINMAXXING_HOME"], !custom.isEmpty {
            return AppPaths(home: URL(fileURLWithPath: custom, isDirectory: true))
        }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/brainmaxxing", isDirectory: true)
        return AppPaths(home: support)
    }

    public var database: URL { home.appendingPathComponent("digest.sqlite") }
    public var raw: URL { home.appendingPathComponent("raw", isDirectory: true) }
}
