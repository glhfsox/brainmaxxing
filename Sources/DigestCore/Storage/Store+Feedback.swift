import Foundation
import GRDB

/// One 👍/👎 as the triage prompt shows it.
public struct FeedbackExample: Sendable, Equatable {
    public var paperID: String
    public var verdict: Verdict
    /// Whitespace-collapsed.
    public var title: String
    /// The paper's most recent triage `one_line`, whitespace-collapsed; nil when it has none.
    public var oneLine: String?
    public var createdAt: Date

    public init(paperID: String, verdict: Verdict, title: String, oneLine: String?, createdAt: Date) {
        self.paperID = paperID
        self.verdict = verdict
        self.title = title
        self.oneLine = oneLine
        self.createdAt = createdAt
    }

    /// `👍 <title> - <one_line>` / `👎 ...`; `👍 <title>` without a one-liner.
    public var line: String {
        "\(verdict == .up ? "👍" : "👎") \(title)" + (oneLine.map { " - \($0)" } ?? "")
    }
}

/// Digest list, feedback and read state for the app (migration v3).
extension Store {
    /// Stored digests, every edition, newest first.
    public func digestList(limit: Int = 200) async throws -> [DigestListItem] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT d.date, d.edition, json_extract(d.json, '$.title') AS title, d.partial, d.empty,
                    (SELECT COUNT(*) FROM digest_papers dp WHERE dp.date = d.date AND dp.edition = d.edition) AS paper_count,
                    (SELECT COUNT(*) FROM digest_papers dp WHERE dp.date = d.date AND dp.edition = d.edition
                        AND NOT EXISTS (SELECT 1 FROM read_state r WHERE r.paper_id = dp.paper_id)) AS unread_count
                FROM digests d ORDER BY d.date DESC, d.edition DESC LIMIT ?
                """, arguments: [limit]).map { row in
                DigestListItem(date: row["date"], edition: row["edition"], title: row["title"] ?? "", partial: row["partial"], empty: row["empty"],
                               paperCount: row["paper_count"], unreadCount: row["unread_count"])
            }
        }
    }

    /// Sets the paper's current verdict; `nil` clears it. `created_at` moves only when the verdict changes, so re-sending
    /// the same verdict does not reorder the feedback examples.
    public func setFeedback(paperID: String, verdict: Verdict?, digestDate: String?) async throws {
        try await pool.write { db in
            guard let verdict else {
                try db.execute(sql: "DELETE FROM feedback WHERE paper_id = ?", arguments: [paperID])
                return
            }
            try db.execute(sql: """
                INSERT INTO feedback (paper_id, verdict, digest_date, created_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(paper_id) DO UPDATE SET verdict = excluded.verdict, digest_date = excluded.digest_date,
                    created_at = CASE WHEN feedback.verdict = excluded.verdict THEN feedback.created_at ELSE excluded.created_at END
                """, arguments: [paperID, verdict.rawValue, digestDate, Date()])
        }
    }

    /// Current verdicts of those of `paperIDs` that have one.
    public func feedback(paperIDs: [String]) async throws -> [String: Verdict] {
        try await pool.read { db in
            let rows = try Store.chunked(paperIDs) { chunk, marks in
                try Row.fetchAll(db, sql: "SELECT paper_id, verdict FROM feedback WHERE paper_id IN (\(marks))",
                                 arguments: StatementArguments(chunk))
            }
            var result: [String: Verdict] = [:]
            for row in rows {
                guard let verdict = Verdict(rawValue: row["verdict"]) else { throw StoreError.corruptRow("feedback.verdict") }
                result[row["paper_id"]] = verdict
            }
            return result
        }
    }

    /// The newest `limit` verdicts for the triage prompt: `created_at` desc, ties by paper id.
    public func feedbackExamples(limit: Int = 20) async throws -> [FeedbackExample] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.paper_id, f.verdict, f.created_at, p.title,
                    (SELECT t.one_line FROM triage_scores t JOIN runs r ON r.id = t.run_id
                     WHERE t.paper_id = f.paper_id ORDER BY r.started_at DESC LIMIT 1) AS one_line
                FROM feedback f JOIN papers p ON p.id = f.paper_id
                ORDER BY f.created_at DESC, f.paper_id ASC LIMIT ?
                """, arguments: [max(0, limit)]).map { row in
                guard let verdict = Verdict(rawValue: row["verdict"]) else { throw StoreError.corruptRow("feedback.verdict") }
                let oneLine = ArxivClient.normalize((row["one_line"] as String?) ?? "")
                return FeedbackExample(paperID: row["paper_id"], verdict: verdict, title: ArxivClient.normalize(row["title"] ?? ""),
                                       oneLine: oneLine.isEmpty ? nil : oneLine, createdAt: row["created_at"] ?? Date.distantPast)
            }
        }
    }

    /// Marks a paper read (keeping the first read time) or unread.
    public func setRead(paperID: String, read: Bool) async throws {
        try await pool.write { db in
            if read {
                try db.execute(sql: "INSERT OR IGNORE INTO read_state (paper_id, read_at) VALUES (?, ?)", arguments: [paperID, Date()])
            } else {
                try db.execute(sql: "DELETE FROM read_state WHERE paper_id = ?", arguments: [paperID])
            }
        }
    }

    /// The subset of `ids` that has been marked read.
    public func readPaperIDs(among ids: [String]) async throws -> Set<String> {
        try await pool.read { db in
            Set(try Store.chunked(ids) { chunk, marks in
                try String.fetchAll(db, sql: "SELECT paper_id FROM read_state WHERE paper_id IN (\(marks))",
                                    arguments: StatementArguments(chunk))
            })
        }
    }

    /// All papers ever stored ("also seen: N").
    public func paperCountTotal() async throws -> Int {
        try await paperCount()
    }

    /// Runs `query` over `ids` (deduplicated) in chunks of 500 to stay below SQLite's bound-parameter limit.
    private static func chunked<T>(_ ids: [String], _ query: ([String], String) throws -> [T]) rethrows -> [T] {
        let unique = Array(Set(ids))
        var out: [T] = []
        for start in stride(from: 0, to: unique.count, by: 500) {
            let chunk = Array(unique[start..<min(start + 500, unique.count)])
            out += try query(chunk, Array(repeating: "?", count: chunk.count).joined(separator: ","))
        }
        return out
    }
}
