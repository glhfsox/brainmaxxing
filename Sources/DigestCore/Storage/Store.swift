import Foundation
import GRDB
import os

public enum StoreError: LocalizedError {
    case open(String, String)
    case corruptRow(String)

    public var errorDescription: String? {
        switch self {
        case let .open(path, reason): "cannot open database at \(path): \(reason)"
        case let .corruptRow(what): "corrupt database row: \(what)"
        }
    }
}

/// One recorded LLM call (`llm_calls` row).
public struct LLMCallRecord: Sendable, Equatable {
    public var runID: String?
    public var stage: Stage
    public var model: String
    public var promptName: String?
    public var promptVersion: Int?
    public var usage: LLMUsage
    public var usdEstimate: Double
    public var createdAt: Date
    /// The usage is a worst-case estimate: a streamed call failed after it was sent.
    public var estimated: Bool

    public init(runID: String?, stage: Stage, model: String, promptName: String?, promptVersion: Int?, usage: LLMUsage, usdEstimate: Double,
                createdAt: Date, estimated: Bool = false) {
        self.runID = runID
        self.stage = stage
        self.model = model
        self.promptName = promptName
        self.promptVersion = promptVersion
        self.usage = usage
        self.usdEstimate = usdEstimate
        self.createdAt = createdAt
        self.estimated = estimated
    }
}

/// One triage outcome for one paper in one run.
public struct TriageScore: Sendable, Equatable {
    public var paperID: String
    public var score: Int
    public var oneLine: String
    public var tags: [String]
    public var promptVersion: Int?

    public init(paperID: String, score: Int, oneLine: String, tags: [String], promptVersion: Int?) {
        self.paperID = paperID
        self.score = score
        self.oneLine = oneLine
        self.tags = tags
        self.promptVersion = promptVersion
    }
}

public struct DailyCost: Sendable, Equatable {
    public var day: Date        // local start of day
    public var usd: Double
    public var calls: Int
    /// The part of `usd` spent by chat (`stage = chat`).
    public var chatUSD: Double = 0
}

/// The only way the rest of the code talks to `digest.sqlite`. Intent methods, no SQL for callers.
public actor Store {
    let pool: DatabasePool
    /// Directory of the database file; full texts and figures live below it, referenced by relative path.
    public nonisolated let home: URL
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "store")

    public init(url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            home = url.deletingLastPathComponent()
            pool = try DatabasePool(path: url.path)
            try Store.migrator.migrate(pool)
        } catch {
            throw StoreError.open(url.path, error.localizedDescription)
        }
    }

    // MARK: Migrations (append-only: never edit a registered migration, add a new one)

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE papers (
                    id TEXT PRIMARY KEY NOT NULL,
                    version INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    abstract TEXT NOT NULL,
                    authors TEXT NOT NULL,
                    categories TEXT NOT NULL,
                    primary_category TEXT,
                    abs_url TEXT,
                    pdf_url TEXT,
                    published DATETIME NOT NULL,
                    updated DATETIME NOT NULL,
                    source TEXT NOT NULL,
                    first_seen_run TEXT,
                    fulltext TEXT
                );
                CREATE INDEX papers_updated ON papers(updated);
                CREATE TABLE runs (
                    id TEXT PRIMARY KEY NOT NULL,
                    started_at DATETIME NOT NULL,
                    finished_at DATETIME,
                    status TEXT NOT NULL,
                    partial BOOLEAN NOT NULL DEFAULT 0,
                    force BOOLEAN NOT NULL DEFAULT 0,
                    since DATETIME,
                    stages TEXT NOT NULL,
                    counts TEXT NOT NULL DEFAULT '{}',
                    prompt_versions TEXT NOT NULL DEFAULT '{}',
                    error_summary TEXT
                );
                CREATE INDEX runs_started ON runs(started_at);
                CREATE TABLE llm_calls (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
                    stage TEXT NOT NULL,
                    model TEXT NOT NULL,
                    prompt_name TEXT,
                    prompt_version INTEGER,
                    input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    cache_read_tokens INTEGER NOT NULL,
                    cache_write_tokens INTEGER NOT NULL,
                    usd_estimate REAL NOT NULL,
                    created_at DATETIME NOT NULL
                );
                CREATE INDEX llm_calls_created ON llm_calls(created_at);
                CREATE TABLE triage_scores (
                    run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
                    paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
                    score INTEGER NOT NULL,
                    one_line TEXT NOT NULL,
                    tags TEXT NOT NULL,
                    prompt_version INTEGER,
                    selected BOOLEAN NOT NULL DEFAULT 0,
                    rank INTEGER,
                    PRIMARY KEY (run_id, paper_id)
                );
                """)
            try db.create(virtualTable: "papers_fts", using: FTS5()) { t in
                t.synchronize(withTable: "papers")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("title")
                t.column("abstract")
                t.column("fulltext")
            }
        }
        m.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE papers ADD COLUMN fulltext_path TEXT;
                ALTER TABLE papers ADD COLUMN fulltext_source TEXT;
                ALTER TABLE runs ADD COLUMN last_stage TEXT;
                ALTER TABLE runs ADD COLUMN errors TEXT NOT NULL DEFAULT '{}';
                -- Set on rows copied into a run that selected a paper scored by an earlier run.
                ALTER TABLE triage_scores ADD COLUMN scored_in_run TEXT;
                -- Older runs: the highest requested stage, capped at select (nothing ran after it then).
                UPDATE runs SET last_stage = CASE
                        WHEN stages LIKE '%select%' THEN 'select' WHEN stages LIKE '%triage%' THEN 'triage'
                        WHEN stages LIKE '%dedup%' THEN 'dedup' ELSE 'fetch' END
                    WHERE status IN ('succeeded', 'partial');
                CREATE TABLE figures (
                    paper_id TEXT NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
                    idx INTEGER NOT NULL,
                    path TEXT NOT NULL,
                    caption TEXT NOT NULL,
                    source TEXT NOT NULL,
                    PRIMARY KEY (paper_id, idx)
                );
                CREATE TABLE digests (
                    date TEXT PRIMARY KEY NOT NULL,
                    run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
                    json TEXT NOT NULL,
                    partial BOOLEAN NOT NULL,
                    empty BOOLEAN NOT NULL,
                    prompt_version INTEGER,
                    model TEXT,
                    cost_usd REAL NOT NULL,
                    created_at DATETIME NOT NULL
                );
                CREATE TABLE digest_papers (
                    date TEXT NOT NULL REFERENCES digests(date) ON DELETE CASCADE,
                    paper_id TEXT NOT NULL,
                    rank INTEGER NOT NULL,
                    cluster_id TEXT NOT NULL,
                    PRIMARY KEY (date, paper_id)
                );
                CREATE INDEX digest_papers_paper ON digest_papers(paper_id);
                CREATE TABLE clusters (
                    date TEXT NOT NULL REFERENCES digests(date) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    narrative TEXT NOT NULL,
                    PRIMARY KEY (date, id)
                );
                """)
            try db.create(virtualTable: "digests_fts", using: FTS5()) { t in
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("date").notIndexed()
                t.column("text")
            }
        }
        m.registerMigration("v3") { db in
            try db.execute(sql: """
                -- One current verdict per paper; clearing a verdict deletes the row.
                CREATE TABLE feedback (
                    paper_id TEXT PRIMARY KEY NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
                    verdict INTEGER NOT NULL CHECK (verdict IN (-1, 1)),
                    digest_date TEXT,
                    created_at DATETIME NOT NULL
                );
                CREATE TABLE read_state (
                    paper_id TEXT PRIMARY KEY NOT NULL REFERENCES papers(id) ON DELETE CASCADE,
                    read_at DATETIME NOT NULL
                );
                """)
        }
        m.registerMigration("v4") { db in
            try db.execute(sql: """
                -- Chat: one conversation per digest date plus `general` (digest_date NULL).
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY NOT NULL,
                    digest_date TEXT UNIQUE,
                    title TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL
                );
                CREATE TABLE chat_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'summary')),
                    content TEXT NOT NULL,
                    quotes_json TEXT,
                    tool_calls_json TEXT,
                    model TEXT,
                    created_at DATETIME NOT NULL
                );
                CREATE INDEX chat_messages_conversation ON chat_messages(conversation_id, created_at);
                """)
            try db.create(virtualTable: "chat_messages_fts", using: FTS5()) { t in
                t.synchronize(withTable: "chat_messages")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("content")
            }
        }
        m.registerMigration("v5") { db in
            // Digest editions (PK date -> (date, edition)), shown-memory, deterministic digest failures, estimated calls.
            // GRDB runs migrations with foreign keys off and checks them at the end, so the tables are rebuilt in place.
            try db.execute(sql: """
                CREATE TABLE digests_v5 (
                    date TEXT NOT NULL,
                    edition INTEGER NOT NULL DEFAULT 1,
                    run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
                    json TEXT NOT NULL,
                    partial BOOLEAN NOT NULL,
                    empty BOOLEAN NOT NULL,
                    prompt_version INTEGER,
                    model TEXT,
                    cost_usd REAL NOT NULL,
                    created_at DATETIME NOT NULL,
                    PRIMARY KEY (date, edition)
                );
                INSERT INTO digests_v5 (date, edition, run_id, json, partial, empty, prompt_version, model, cost_usd, created_at)
                    SELECT date, 1, run_id, json, partial, empty, prompt_version, model, cost_usd, created_at FROM digests;
                CREATE TABLE digest_papers_v5 (
                    date TEXT NOT NULL,
                    edition INTEGER NOT NULL DEFAULT 1,
                    paper_id TEXT NOT NULL,
                    rank INTEGER NOT NULL,
                    cluster_id TEXT NOT NULL,
                    PRIMARY KEY (date, edition, paper_id),
                    FOREIGN KEY (date, edition) REFERENCES digests(date, edition) ON DELETE CASCADE
                );
                INSERT INTO digest_papers_v5 (date, edition, paper_id, rank, cluster_id)
                    SELECT date, 1, paper_id, rank, cluster_id FROM digest_papers;
                CREATE TABLE clusters_v5 (
                    date TEXT NOT NULL,
                    edition INTEGER NOT NULL DEFAULT 1,
                    id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    narrative TEXT NOT NULL,
                    PRIMARY KEY (date, edition, id),
                    FOREIGN KEY (date, edition) REFERENCES digests(date, edition) ON DELETE CASCADE
                );
                INSERT INTO clusters_v5 (date, edition, id, name, narrative) SELECT date, 1, id, name, narrative FROM clusters ORDER BY rowid;
                DROP TABLE digest_papers;
                DROP TABLE clusters;
                DROP TABLE digests;
                ALTER TABLE digests_v5 RENAME TO digests;
                ALTER TABLE digest_papers_v5 RENAME TO digest_papers;
                ALTER TABLE clusters_v5 RENAME TO clusters;
                CREATE INDEX digest_papers_paper ON digest_papers(paper_id);
                -- What the reader has been shown; replacing a digest never deletes from it.
                CREATE TABLE shown_papers (
                    paper_id TEXT PRIMARY KEY NOT NULL,
                    first_shown_date TEXT NOT NULL,
                    digest_edition INTEGER NOT NULL
                );
                INSERT INTO shown_papers (paper_id, first_shown_date, digest_edition)
                    SELECT paper_id, MIN(date), 1 FROM digest_papers GROUP BY paper_id;
                -- 'deterministic' | 'transient' when the run's digest stage failed.
                ALTER TABLE runs ADD COLUMN digest_failure TEXT;
                -- A streamed call that failed after sending is recorded at its worst case.
                ALTER TABLE llm_calls ADD COLUMN estimated BOOLEAN NOT NULL DEFAULT 0;
                """)
            // The search index gains the edition; FTS5 tables can't be altered, so it is rebuilt.
            try db.execute(sql: "ALTER TABLE digests_fts RENAME TO digests_fts_v4")
            try db.create(virtualTable: "digests_fts", using: FTS5()) { t in
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("date").notIndexed()
                t.column("edition").notIndexed()
                t.column("text")
            }
            try db.execute(sql: """
                INSERT INTO digests_fts (date, edition, text) SELECT date, 1, text FROM digests_fts_v4;
                DROP TABLE digests_fts_v4;
                """)
        }
        m.registerMigration("v6") { db in
            // OpenAlex journal papers carry a venue and a DOI; NULL for arXiv rows.
            try db.execute(sql: """
                ALTER TABLE papers ADD COLUMN venue TEXT;
                ALTER TABLE papers ADD COLUMN doi TEXT;
                """)
        }
        m.registerMigration("v7") { db in
            // Secondary-source warnings survive `run --stage digest`; DOI lookups across sources.
            try db.execute(sql: """
                ALTER TABLE runs ADD COLUMN warnings TEXT NOT NULL DEFAULT '[]';
                CREATE INDEX papers_doi ON papers(lower(doi)) WHERE doi IS NOT NULL;
                """)
        }
        m.registerMigration("v8") { db in
            // Live progress of the run (`RunProgress` JSON), for the app's "what is it doing now" line.
            try db.execute(sql: "ALTER TABLE runs ADD COLUMN progress TEXT")
        }
        return m
    }

    // MARK: Papers

    /// Inserts or updates papers; a stored newer version is never overwritten by an older one.
    /// Returns the number of rows written. Idempotent.
    @discardableResult
    public func upsertPapers(_ papers: [RawPaper], runID: String?) async throws -> Int {
        let rows = try papers.map { try PaperRow($0) }
        return try await pool.write { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO papers (id, version, title, abstract, authors, categories, primary_category,
                                        abs_url, pdf_url, published, updated, source, first_seen_run, venue, doi)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        version = excluded.version, title = excluded.title, abstract = excluded.abstract,
                        authors = excluded.authors, categories = excluded.categories,
                        primary_category = excluded.primary_category, abs_url = excluded.abs_url,
                        pdf_url = excluded.pdf_url, published = excluded.published, updated = excluded.updated,
                        source = excluded.source, venue = excluded.venue, doi = excluded.doi,
                        first_seen_run = COALESCE(papers.first_seen_run, excluded.first_seen_run)
                    WHERE excluded.version >= papers.version
                    """, arguments: [r.id, r.version, r.title, r.abstract, r.authors, r.categories, r.primaryCategory,
                                     r.absURL, r.pdfURL, r.published, r.updated, r.source, runID, r.venue, r.doi])
            }
            return rows.count
        }
    }

    /// Stores papers whose id is not in the store yet; existing rows are left untouched (HF Daily Papers).
    /// `first_seen_run` stays NULL: these papers were listed, not fetched for triage. Returns the number inserted.
    @discardableResult
    public func insertPapersIfAbsent(_ papers: [RawPaper]) async throws -> Int {
        let rows = try papers.map { try PaperRow($0) }
        return try await pool.write { db in
            var inserted = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO papers (id, version, title, abstract, authors, categories, primary_category,
                                                  abs_url, pdf_url, published, updated, source, venue, doi)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [r.id, r.version, r.title, r.abstract, r.authors, r.categories, r.primaryCategory,
                                     r.absURL, r.pdfURL, r.published, r.updated, r.source, r.venue, r.doi])
                inserted += db.changesCount
            }
            return inserted
        }
    }

    /// The lowercased DOIs among `dois` that a stored arXiv paper carries (`<arxiv:doi>`), for OpenAlex dedup.
    public func arxivDOIs(among dois: [String]) async throws -> Set<String> {
        let lowered = Array(Set(dois.map { $0.lowercased() }))
        return try await pool.read { db in
            var found = Set<String>()
            for start in stride(from: 0, to: lowered.count, by: 500) {
                let chunk = Array(lowered[start..<min(start + 500, lowered.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                found.formUnion(try String.fetchAll(db, sql: """
                    SELECT DISTINCT lower(doi) FROM papers WHERE doi IS NOT NULL AND lower(doi) IN (\(marks)) AND source = 'arxiv'
                    """, arguments: StatementArguments(chunk)))
            }
            return found
        }
    }

    public func paper(id: String) async throws -> RawPaper? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM papers WHERE id = ?", arguments: [id]).map(Store.paper(from:))
        }
    }

    public func paperCount() async throws -> Int {
        try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM papers") ?? 0 }
    }

    /// Full-text search over title, abstract and full text (prefix match on every word).
    public func searchPapers(_ query: String, limit: Int = 50) async throws -> [RawPaper] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT papers.* FROM papers JOIN papers_fts ON papers_fts.rowid = papers.rowid
                WHERE papers_fts MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit]).map(Store.paper(from:))
        }
    }

    // MARK: Runs

    public func startRun(id: String, startedAt: Date, force: Bool, since: Date?, stages: Set<Stage>) async throws {
        let stagesText = stages.sorted().map(\.rawValue).joined(separator: ",")
        let countsJSON = try Store.json(RunCounts())
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO runs (id, started_at, status, force, since, stages, counts) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [id, startedAt, RunStatus.running.rawValue, force, since, stagesText, countsJSON])
        }
    }

    public func finishRun(
        _ id: String, status: RunStatus, partial: Bool, counts: RunCounts, promptVersions: [String: Int],
        errorSummary: String?, finishedAt: Date, errors: [Stage: String] = [:], warnings: [String] = []
    ) async throws {
        let warningsJSON = try Store.json(warnings)
        let countsJSON = try Store.json(counts)
        let versionsJSON = try Store.json(promptVersions)
        let errorsJSON = try Store.json(Dictionary(uniqueKeysWithValues: errors.map { ($0.key.rawValue, $0.value) }))
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE runs SET status = ?, partial = ?, counts = ?, prompt_versions = ?, error_summary = ?, finished_at = ?, errors = ?,
                    warnings = ?
                WHERE id = ?
                """, arguments: [status.rawValue, partial, countsJSON, versionsJSON, errorSummary, finishedAt, errorsJSON, warningsJSON, id])
        }
    }

    /// Records that `stage` completed for the run (what "reached select / digest" means).
    public func markStageReached(_ id: String, stage: Stage) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE runs SET last_stage = ? WHERE id = ?", arguments: [stage.rawValue, id])
        }
    }

    /// Marks a finished run as running again (`run --stage digest` re-runs a stage of an existing run).
    public func reopenRun(_ id: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE runs SET status = ?, finished_at = NULL, progress = NULL WHERE id = ?",
                           arguments: [RunStatus.running.rawValue, id])
        }
    }

    public func run(id: String) async throws -> RunRecord? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE id = ?", arguments: [id]).map(Store.run(from:))
        }
    }

    /// The latest finished run (any status but `running`) whose `last_stage` is at or past `stage`.
    public func latestRun(reaching stage: Stage) async throws -> RunRecord? {
        let reached = Stage.pipelineStages.filter { $0 >= stage }.map(\.rawValue)
        let marks = Array(repeating: "?", count: reached.count).joined(separator: ",")
        return try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE status != ? AND last_stage IN (\(marks)) ORDER BY started_at DESC LIMIT 1",
                             arguments: StatementArguments([RunStatus.running.rawValue] + reached)).map(Store.run(from:))
        }
    }

    /// Stores the counts reached so far, so `status` shows progress and a killed run keeps its last counts.
    public func updateRunCounts(_ id: String, counts: RunCounts) async throws {
        let countsJSON = try Store.json(counts)
        try await pool.write { db in
            try db.execute(sql: "UPDATE runs SET counts = ? WHERE id = ?", arguments: [countsJSON, id])
        }
    }

    /// Stores where the run is now (one row write per step; the app polls it every couple of seconds).
    public func updateRunProgress(_ id: String, progress: RunProgress) async throws {
        let progressJSON = try Store.json(progress)
        try await pool.write { db in
            try db.execute(sql: "UPDATE runs SET progress = ? WHERE id = ?", arguments: [progressJSON, id])
        }
    }

    public func markRun(_ id: String, status: RunStatus) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE runs SET status = ? WHERE id = ?", arguments: [status.rawValue, id])
        }
    }

    /// Records how the run's digest stage failed, `nil` = it didn't: a deterministic failure is not retried
    /// by `--if-due` that day.
    public func markDigestFailure(_ id: String, deterministic: Bool?) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE runs SET digest_failure = ? WHERE id = ?",
                           arguments: [deterministic.map { $0 ? "deterministic" : "transient" }, id])
        }
    }

    /// The latest run started on the local day of `date` whose digest stage failed deterministically, unless a later
    /// run that day failed only transiently.
    public func deterministicDigestFailure(onDayOf date: Date, calendar: Calendar = .current) async throws -> RunRecord? {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? date.addingTimeInterval(86_400)
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM runs WHERE digest_failure IS NOT NULL AND started_at >= ? AND started_at < ?
                ORDER BY started_at DESC LIMIT 1
                """, arguments: [start, end]), (row["digest_failure"] as String?) == "deterministic" else { return nil }
            return try Store.run(from: row)
        }
    }

    public func lastRun() async throws -> RunRecord? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM runs ORDER BY started_at DESC LIMIT 1").map(Store.run(from:))
        }
    }

    /// Latest run with status `succeeded`; with `stage`, only runs that completed it (`last_stage` at or past it).
    public func lastSuccessfulRun(reaching stage: Stage? = nil) async throws -> RunRecord? {
        let reached = Stage.pipelineStages.filter { s in stage.map { s >= $0 } ?? true }.map(\.rawValue)
        let marks = Array(repeating: "?", count: reached.count).joined(separator: ",")
        let stageFilter = stage == nil ? "" : "AND last_stage IN (\(marks))"
        return try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM runs WHERE status = ? \(stageFilter) ORDER BY started_at DESC LIMIT 1",
                             arguments: StatementArguments([RunStatus.succeeded.rawValue] + (stage == nil ? [] : reached)))
                .map(Store.run(from:))
        }
    }

    // MARK: LLM calls and cost

    public func recordLLMCall(_ call: LLMCallRecord) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO llm_calls (run_id, stage, model, prompt_name, prompt_version, input_tokens, output_tokens,
                                       cache_read_tokens, cache_write_tokens, usd_estimate, created_at, estimated)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [call.runID, call.stage.rawValue, call.model, call.promptName, call.promptVersion,
                                 call.usage.inputTokens, call.usage.outputTokens, call.usage.cacheReadTokens,
                                 call.usage.cacheWriteTokens, call.usdEstimate, call.createdAt, call.estimated])
        }
    }

    public func llmCalls(runID: String) async throws -> [LLMCallRecord] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM llm_calls WHERE run_id = ? ORDER BY id", arguments: [runID]).map { row in
                guard let stage = Stage(rawValue: row["stage"] ?? "") else { throw StoreError.corruptRow("llm_calls.stage") }
                return LLMCallRecord(
                    runID: row["run_id"], stage: stage, model: row["model"] ?? "", promptName: row["prompt_name"],
                    promptVersion: row["prompt_version"],
                    usage: LLMUsage(inputTokens: row["input_tokens"] ?? 0, outputTokens: row["output_tokens"] ?? 0,
                                    cacheReadTokens: row["cache_read_tokens"] ?? 0, cacheWriteTokens: row["cache_write_tokens"] ?? 0),
                    usdEstimate: row["usd_estimate"] ?? 0, createdAt: row["created_at"] ?? Date.distantPast,
                    estimated: row["estimated"] ?? false)
            }
        }
    }

    /// Total estimated USD of all LLM calls made at or after `date`.
    public func costSince(_ date: Date) async throws -> Double {
        try await pool.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(usd_estimate), 0) FROM llm_calls WHERE created_at >= ?",
                                arguments: [date]) ?? 0
        }
    }

    public func costByStage(runID: String) async throws -> [Stage: Double] {
        try await pool.read { db in
            var result: [Stage: Double] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT stage, SUM(usd_estimate) AS usd FROM llm_calls WHERE run_id = ? GROUP BY stage",
                                        arguments: [runID]) {
                if let stage = Stage(rawValue: row["stage"] ?? "") { result[stage] = row["usd"] ?? 0 }
            }
            return result
        }
    }

    /// Cost per local calendar day for calls at or after `since`, oldest first.
    public func dailyCosts(since: Date, calendar: Calendar = .current) async throws -> [DailyCost] {
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT created_at, usd_estimate, stage FROM llm_calls WHERE created_at >= ?", arguments: [since])
                .map { (($0["created_at"] as Date?) ?? Date.distantPast, ($0["usd_estimate"] as Double?) ?? 0, ($0["stage"] as String?) == Stage.chat.rawValue) }
        }
        var byDay: [Date: DailyCost] = [:]
        for (date, usd, isChat) in rows {
            let day = calendar.startOfDay(for: date)
            byDay[day, default: DailyCost(day: day, usd: 0, calls: 0)].usd += usd
            byDay[day, default: DailyCost(day: day, usd: 0, calls: 0)].calls += 1
            if isChat { byDay[day, default: DailyCost(day: day, usd: 0, calls: 0)].chatUSD += usd }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    // MARK: Triage

    public func saveTriageScores(runID: String, _ scores: [TriageScore]) async throws {
        let rows = try scores.map { ($0, try Store.json($0.tags)) }
        try await pool.write { db in
            for (s, tags) in rows {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO triage_scores (run_id, paper_id, score, one_line, tags, prompt_version)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [runID, s.paperID, s.score, s.oneLine, tags, s.promptVersion])
            }
        }
    }

    /// The subset of `ids` that has no `triage_scores` row from any run (novelty comes from the store).
    public func untriagedIDs(among ids: [String]) async throws -> Set<String> {
        let unique = Array(Set(ids))
        let scored = try await pool.read { db in
            var scored = Set<String>()
            // Chunked to stay far below SQLite's bound-parameter limit.
            for start in stride(from: 0, to: unique.count, by: 500) {
                let chunk = Array(unique[start..<min(start + 500, unique.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                scored.formUnion(try String.fetchAll(db, sql: "SELECT DISTINCT paper_id FROM triage_scores WHERE paper_id IN (\(marks))",
                                                     arguments: StatementArguments(chunk)))
            }
            return scored
        }
        return Set(unique).subtracting(scored)
    }

    /// The newest original triage score of a paper across runs (carry-over copies tagged `scored_in_run` are skipped).
    public func latestTriage(paperID: String) async throws -> TriageScore? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT t.* FROM triage_scores t JOIN runs r ON r.id = t.run_id
                WHERE t.paper_id = ? AND t.scored_in_run IS NULL ORDER BY r.started_at DESC LIMIT 1
                """, arguments: [paperID]).map { row in
                TriageScore(paperID: row["paper_id"], score: row["score"] ?? 0, oneLine: row["one_line"] ?? "",
                            tags: try Store.decode([String].self, row["tags"]), promptVersion: row["prompt_version"])
            }
        }
    }

    /// Marks `orderedIDs` as the selection of the run, rank 1 first; clears any earlier selection.
    /// A paper scored by an earlier run gets a copy of its newest score row in this run, tagged `scored_in_run`.
    public func markSelected(runID: String, orderedIDs: [String]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM triage_scores WHERE run_id = ? AND scored_in_run IS NOT NULL", arguments: [runID])
            try db.execute(sql: "UPDATE triage_scores SET selected = 0, rank = NULL WHERE run_id = ?", arguments: [runID])
            for (i, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE triage_scores SET selected = 1, rank = ? WHERE run_id = ? AND paper_id = ?",
                               arguments: [i + 1, runID, id])
                if db.changesCount == 0 {
                    try db.execute(sql: """
                        INSERT INTO triage_scores (run_id, paper_id, score, one_line, tags, prompt_version, selected, rank, scored_in_run)
                        SELECT ?, t.paper_id, t.score, t.one_line, t.tags, t.prompt_version, 1, ?, t.run_id
                        FROM triage_scores t JOIN runs r ON r.id = t.run_id
                        WHERE t.paper_id = ? AND t.scored_in_run IS NULL ORDER BY r.started_at DESC LIMIT 1
                        """, arguments: [runID, i + 1, id])
                }
            }
        }
    }

    /// Every paper with a triage score from any run, not in `shown_papers`, `published >= windowStart`;
    /// the newest run's score wins when several runs scored it.
    public func selectionPool(windowStart: Date) async throws -> [(paper: RawPaper, score: Int, scoredInRunID: String)] {
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT papers.*, t.score AS triage_score, t.run_id AS scored_run
                FROM triage_scores t JOIN runs r ON r.id = t.run_id JOIN papers ON papers.id = t.paper_id
                WHERE t.scored_in_run IS NULL AND papers.published >= ?
                  AND NOT EXISTS (SELECT 1 FROM shown_papers sp WHERE sp.paper_id = t.paper_id)
                  -- A journal paper whose DOI an arXiv paper carries is that paper's copy; arXiv wins.
                  AND NOT (papers.source != 'arxiv' AND papers.doi IS NOT NULL AND EXISTS (
                      SELECT 1 FROM papers a WHERE lower(a.doi) = lower(papers.doi) AND a.source = 'arxiv' AND a.id != papers.id))
                ORDER BY r.started_at DESC
                """, arguments: [windowStart]).map { row in
                (paper: try Store.paper(from: row), score: (row["triage_score"] as Int?) ?? 0, scoredInRunID: (row["scored_run"] as String?) ?? "")
            }
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.paper.id).inserted }
    }

    /// Triage results of a run: selected papers by rank, then the rest by score desc, updated desc.
    public func rankedPapers(runID: String, selectedOnly: Bool = false) async throws -> [RankedPaper] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT papers.*, t.score, t.one_line, t.tags AS triage_tags, t.selected, t.rank,
                       COALESCE(t.scored_in_run, t.run_id) AS scored_run
                FROM triage_scores t JOIN papers ON papers.id = t.paper_id
                WHERE t.run_id = ? \(selectedOnly ? "AND t.selected = 1" : "")
                ORDER BY t.selected DESC, t.rank ASC, t.score DESC, papers.updated DESC, papers.id ASC
                """, arguments: [runID]).map { row in
                RankedPaper(
                    paper: try Store.paper(from: row), score: row["score"] ?? 0, oneLine: row["one_line"] ?? "",
                    tags: try Store.decode([String].self, row["triage_tags"]), selected: row["selected"] ?? false,
                    rank: row["rank"], scoredInRunID: row["scored_run"])
            }
        }
    }

    // MARK: Row mapping

    private struct PaperRow {
        var id: String, version: Int, title: String, abstract: String, authors: String, categories: String
        var primaryCategory: String?, absURL: String?, pdfURL: String?, published: Date, updated: Date, source: String
        var venue: String?, doi: String?

        init(_ p: RawPaper) throws {
            id = p.id
            version = p.version
            title = p.title
            abstract = p.abstract
            authors = try Store.json(p.authors)
            categories = try Store.json(p.categories)
            primaryCategory = p.primaryCategory
            absURL = p.absURL?.absoluteString
            pdfURL = p.pdfURL?.absoluteString
            published = p.published
            updated = p.updated
            source = p.source.rawValue
            venue = p.venue
            doi = p.doi
        }
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) throws -> T {
        guard let text else { throw StoreError.corruptRow("missing JSON column") }
        return try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    static func paper(from row: Row) throws -> RawPaper {
        guard let id: String = row["id"], let source = SourceID(rawValue: row["source"] ?? ""),
              let published: Date = row["published"], let updated: Date = row["updated"]
        else { throw StoreError.corruptRow("papers") }
        return RawPaper(
            id: id, version: row["version"] ?? 1, title: row["title"] ?? "", abstract: row["abstract"] ?? "",
            authors: try decode([String].self, row["authors"]), categories: try decode([String].self, row["categories"]),
            primaryCategory: row["primary_category"], absURL: (row["abs_url"] as String?).flatMap(URL.init(string:)),
            pdfURL: (row["pdf_url"] as String?).flatMap(URL.init(string:)), published: published, updated: updated,
            source: source, venue: row["venue"], doi: row["doi"])
    }

    private static func run(from row: Row) throws -> RunRecord {
        guard let id: String = row["id"], let startedAt: Date = row["started_at"],
              let status = RunStatus(rawValue: row["status"] ?? "")
        else { throw StoreError.corruptRow("runs") }
        let errors = try decode([String: String].self, row["errors"] ?? "{}")
        return RunRecord(
            id: id, startedAt: startedAt, finishedAt: row["finished_at"], status: status,
            partial: row["partial"] ?? false, force: row["force"] ?? false, since: row["since"],
            counts: try decode(RunCounts.self, row["counts"]), promptVersions: try decode([String: Int].self, row["prompt_versions"]),
            lastStage: (row["last_stage"] as String?).flatMap(Stage.init(rawValue:)),
            errors: Dictionary(uniqueKeysWithValues: errors.compactMap { k, v in Stage(rawValue: k).map { ($0, v) } }),
            errorSummary: row["error_summary"], warnings: try decode([String].self, row["warnings"] ?? "[]"),
            progress: try (row["progress"] as String?).map { try decode(RunProgress.self, $0) })
    }
}
