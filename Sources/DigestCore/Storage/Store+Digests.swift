import Foundation
import GRDB

public struct DigestSearchHit: Sendable, Equatable {
    public var date: String
    public var title: String
    public var snippet: String
    public var edition: Int = 1
}

/// Full text, figures and digests (migration v2).
extension Store {
    // MARK: Full text

    /// Writes `fulltext/<id>.txt`, records path and source, and indexes the text in `papers_fts`.
    public func saveFullText(paperID: String, text: String, source: FullTextSource) async throws {
        let relative = "fulltext/\(FullText.fileSafe(paperID)).txt"
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        try await pool.write { db in
            // The `fulltext` column feeds the FTS5 triggers; the file is what readers use.
            try db.execute(sql: "UPDATE papers SET fulltext = ?, fulltext_path = ?, fulltext_source = ? WHERE id = ?",
                           arguments: [text, relative, source.rawValue, paperID])
        }
    }

    public func fullText(paperID: String) async throws -> String? {
        guard let info = try await fullTextInfo(paperID: paperID) else { return nil }
        return try? String(contentsOf: home.appendingPathComponent(info.path), encoding: .utf8)
    }

    public func fullTextSource(paperID: String) async throws -> FullTextSource? {
        try await fullTextInfo(paperID: paperID)?.source
    }

    private func fullTextInfo(paperID: String) async throws -> (path: String, source: FullTextSource)? {
        try await pool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT fulltext_path, fulltext_source FROM papers WHERE id = ?", arguments: [paperID]),
                  let path: String = row["fulltext_path"], let source = FullTextSource(rawValue: row["fulltext_source"] ?? "")
            else { return nil }
            return (path, source)
        }
    }

    /// Replaces the paper's figures: `figures/<id>/<n>.png`, n = 1... in the given order.
    @discardableResult
    public func saveFigures(paperID: String, _ figures: [(image: Data, caption: String)], source: FullTextSource) async throws -> [Figure] {
        let dir = home.appendingPathComponent("figures/\(FullText.fileSafe(paperID))", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        var stored: [Figure] = []
        if !figures.isEmpty { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (i, f) in figures.enumerated() {
            let figure = Figure(paperID: paperID, index: i + 1, path: "figures/\(FullText.fileSafe(paperID))/\(i + 1).png",
                                caption: f.caption, source: source)
            try f.image.write(to: home.appendingPathComponent(figure.path), options: .atomic)
            stored.append(figure)
        }
        try await pool.write { [stored] db in
            try db.execute(sql: "DELETE FROM figures WHERE paper_id = ?", arguments: [paperID])
            for f in stored {
                try db.execute(sql: "INSERT INTO figures (paper_id, idx, path, caption, source) VALUES (?, ?, ?, ?, ?)",
                               arguments: [f.paperID, f.index, f.path, f.caption, f.source.rawValue])
            }
        }
        return stored
    }

    public func figures(paperID: String) async throws -> [Figure] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM figures WHERE paper_id = ? ORDER BY idx", arguments: [paperID]).map { row in
                Figure(paperID: row["paper_id"] ?? "", index: row["idx"] ?? 0, path: row["path"] ?? "", caption: row["caption"] ?? "",
                       source: FullTextSource(rawValue: row["source"] ?? "") ?? .html)
            }
        }
    }

    // MARK: Digests

    /// Stores the digest as a new edition of its date, or replaces the edition the same run wrote earlier
    /// (`run --stage digest`). Its papers are added to `shown_papers`, which nothing ever deletes from. Returns the edition.
    @discardableResult
    public func saveDigest(_ digest: Digest) async throws -> Int {
        let json = String(decoding: try Digest.encoder.encode(digest), as: UTF8.self)
        let searchText = ([digest.title, digest.summary] + digest.clusters.map(\.narrative)
            + digest.papers.flatMap { [$0.essence, $0.detail] }).filter { !$0.isEmpty }.joined(separator: "\n")
        return try await pool.write { db in
            let edition: Int
            if let own = try Int.fetchOne(db, sql: "SELECT edition FROM digests WHERE date = ? AND run_id = ? ORDER BY edition DESC LIMIT 1",
                                          arguments: [digest.date, digest.runID]) {
                edition = own
                try db.execute(sql: "DELETE FROM digests WHERE date = ? AND edition = ?", arguments: [digest.date, edition])  // cascades
                try db.execute(sql: "DELETE FROM digests_fts WHERE date = ? AND edition = ?", arguments: [digest.date, edition])
            } else {
                edition = (try Int.fetchOne(db, sql: "SELECT MAX(edition) FROM digests WHERE date = ?", arguments: [digest.date]) ?? 0) + 1
            }
            try db.execute(sql: """
                INSERT INTO digests (date, edition, run_id, json, partial, empty, prompt_version, model, cost_usd, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [digest.date, edition, digest.runID, json, digest.partial, digest.empty, digest.promptVersion, digest.model,
                                 digest.costUSD, digest.generatedAt])
            for (i, p) in digest.papers.enumerated() {
                try db.execute(sql: "INSERT INTO digest_papers (date, edition, paper_id, rank, cluster_id) VALUES (?, ?, ?, ?, ?)",
                               arguments: [digest.date, edition, p.id, i + 1, p.clusterID])
                try db.execute(sql: "INSERT OR IGNORE INTO shown_papers (paper_id, first_shown_date, digest_edition) VALUES (?, ?, ?)",
                               arguments: [p.id, digest.date, edition])
            }
            for c in digest.clusters {
                try db.execute(sql: "INSERT INTO clusters (date, edition, id, name, narrative) VALUES (?, ?, ?, ?, ?)",
                               arguments: [digest.date, edition, c.id, c.name, c.narrative])
            }
            try db.execute(sql: "INSERT INTO digests_fts (date, edition, text) VALUES (?, ?, ?)", arguments: [digest.date, edition, searchText])
            return edition
        }
    }

    /// The latest edition of the date's digest.
    public func digest(date: String) async throws -> Digest? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT json, edition FROM digests WHERE date = ? ORDER BY edition DESC LIMIT 1", arguments: [date])
                .map(Store.digest(from:))
        }
    }

    public func digest(date: String, edition: Int) async throws -> Digest? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT json, edition FROM digests WHERE date = ? AND edition = ?", arguments: [date, edition])
                .map(Store.digest(from:))
        }
    }

    /// The latest edition of the latest date.
    public func latestDigest() async throws -> Digest? {
        try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT json, edition FROM digests ORDER BY date DESC, edition DESC LIMIT 1").map(Store.digest(from:))
        }
    }

    /// Cluster names of the digests dated in the `days` days before `date` (exclusive), oldest first.
    public func recentClusterNames(days: Int = 7, before date: String) async throws -> [String] {
        guard let day = LocalDate.date(date), let start = Calendar.current.date(byAdding: .day, value: -days, to: day) else { return [] }
        return try await pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT c.name FROM clusters c JOIN digests d ON d.date = c.date AND d.edition = c.edition
                WHERE c.date >= ? AND c.date < ? ORDER BY c.date ASC, c.edition ASC, c.rowid ASC
                """, arguments: [LocalDate.string(start), date])
        }
    }

    public func searchDigests(_ query: String, limit: Int = 20) async throws -> [DigestSearchHit] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try await pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.date, d.edition, snippet(digests_fts, 2, '[', ']', '...', 12) AS snip, json_extract(d.json, '$.title') AS title
                FROM digests_fts f JOIN digests d ON d.date = f.date AND d.edition = f.edition
                WHERE digests_fts MATCH ? ORDER BY rank LIMIT ?
                """, arguments: [pattern, limit]).map { row in
                DigestSearchHit(date: row["date"] ?? "", title: row["title"] ?? "", snippet: row["snip"] ?? "", edition: row["edition"] ?? 1)
            }
        }
    }

    /// Ids listed in the `hf_section` of any stored digest edition not written by `runID` (an HF paper is
    /// shown once). The run's own edition is excluded so `run --stage digest` can rebuild it with the same papers.
    public func hfSectionIDs(excludingRunID runID: String?) async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT json_extract(j.value, '$.id') FROM digests d, json_each(d.json, '$.hf_section') j
                WHERE d.run_id IS NOT ? AND json_extract(j.value, '$.id') IS NOT NULL
                """, arguments: [runID]))
        }
    }

    /// Every paper ever shown in a digest's main list (`shown_papers`).
    public func shownPaperIDs() async throws -> Set<String> {
        try await pool.read { db in Set(try String.fetchAll(db, sql: "SELECT paper_id FROM shown_papers")) }
    }

    /// Papers first stored by `runID` (`papers.first_seen_run`), sorted by id.
    public func papers(firstSeenIn runID: String) async throws -> [RawPaper] {
        try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM papers WHERE first_seen_run = ? ORDER BY id", arguments: [runID]).map(Store.paper(from:))
        }
    }

    private static func digest(from row: Row) throws -> Digest {
        var digest = try decodeDigest(row["json"] ?? "")
        digest.edition = row["edition"] ?? 1
        return digest
    }

    static func decodeDigest(_ json: String) throws -> Digest {
        do {
            return try Digest.decoder.decode(Digest.self, from: Data(json.utf8))
        } catch {
            throw StoreError.corruptRow("digests.json: \(error.localizedDescription)")
        }
    }
}
