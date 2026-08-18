import Foundation

/// Swift mirror of `schemas/digest.json`: the raw `digest` tool input.
public struct DigestToolOutput: Codable, Sendable, Equatable {
    public struct Cluster: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var paperIDs: [String]
        public var narrative: String
        enum CodingKeys: String, CodingKey { case id, name, paperIDs = "paper_ids", narrative }
    }

    public struct Paper: Codable, Sendable, Equatable {
        public var id: String
        public var clusterID: String
        public var essence: String
        public var detail: String
        public var whyItMatters: String
        public var caveats: String
        public var figureIndex: Int
        public var mermaid: String
        enum CodingKeys: String, CodingKey {
            case id, clusterID = "cluster_id", essence, detail, whyItMatters = "why_it_matters", caveats, figureIndex = "figure_index", mermaid
        }
    }

    public var title: String
    public var summary: String
    public var clusters: [Cluster]
    public var papers: [Paper]
    public var hfSection: [HFEntry]
    public var trendNotes: String

    enum CodingKeys: String, CodingKey { case title, summary, clusters, papers, hfSection = "hf_section", trendNotes = "trend_notes" }
}

public struct HFEntry: Codable, Sendable, Equatable {
    public var id: String
    public var oneLine: String
    /// From the HF listing, filled by pipeline (never by the model); omitted from JSON when nil.
    public var title: String?
    public var upvotes: Int?
    public init(id: String, oneLine: String, title: String? = nil, upvotes: Int? = nil) {
        self.id = id
        self.oneLine = oneLine
        self.title = title
        self.upvotes = upvotes
    }
    enum CodingKeys: String, CodingKey { case id, oneLine = "one_line", title, upvotes }
}

public struct DigestCluster: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var paperIDs: [String]
    public var narrative: String
    public init(id: String, name: String, paperIDs: [String], narrative: String) {
        self.id = id
        self.name = name
        self.paperIDs = paperIDs
        self.narrative = narrative
    }
    enum CodingKeys: String, CodingKey { case id, name, paperIDs = "paper_ids", narrative }
}

public struct PaperLinks: Codable, Sendable, Equatable {
    public var abs: URL?
    public var html: URL?
    public var pdf: URL?
    public init(abs: URL?, html: URL?, pdf: URL?) {
        self.abs = abs
        self.html = html
        self.pdf = pdf
    }
}

/// One paper in a stored digest: the tool fields (snake_case, as in the schema) plus pipeline fields.
public struct DigestPaper: Codable, Sendable, Equatable {
    public var id: String
    public var clusterID: String
    public var essence: String
    public var detail: String
    public var whyItMatters: String
    public var caveats: String
    public var figureIndex: Int
    public var mermaid: String
    // Pipeline fields
    public var title: String
    public var authors: [String]
    public var score: Int
    public var tags: [String]
    public var links: PaperLinks
    public var figure: Figure?
    /// The model left this paper out; `essence` is the triage one-liner.
    public var modelOmitted: Bool
    /// Copied from the paper (OpenAlex journal papers); omitted from JSON when nil.
    public var venue: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, clusterID = "cluster_id", essence, detail, whyItMatters = "why_it_matters", caveats, figureIndex = "figure_index", mermaid
        case title, authors, score, tags, links, figure, modelOmitted, venue
    }
}

/// A stored digest. `date` is the local `YYYY-MM-DD` of the run; `(date, edition)` is unique.
public struct Digest: Codable, Sendable, Equatable {
    public var title: String
    public var summary: String
    public var clusters: [DigestCluster]
    /// In rank order.
    public var papers: [DigestPaper]
    public var hfSection: [HFEntry]
    public var trendNotes: String
    // Pipeline fields
    public var date: String
    public var runID: String
    public var generatedAt: Date
    public var partial: Bool
    public var empty: Bool
    public var counts: RunCounts
    public var promptVersion: Int?
    public var model: String?
    public var costUSD: Double
    /// 1 for the day's first digest, 2, 3, ... for forced re-runs that found unshown papers. Set by the store from
    /// its `digests.edition` column; not part of the JSON.
    public var edition: Int = 1

    enum CodingKeys: String, CodingKey {
        case title, summary, clusters, papers, hfSection = "hf_section", trendNotes = "trend_notes"
        case date, runID, generatedAt, partial, empty, counts, promptVersion, model, costUSD
    }

    /// Stable JSON (sorted keys, ISO 8601 dates) for the `digests.json` column, `show --json` and golden files.
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// One row of the app's digest sidebar.
public struct DigestListItem: Sendable, Equatable, Identifiable {
    /// `date` for edition 1, `date#edition` for later editions of the same day.
    public var id: String { edition == 1 ? date : "\(date)#\(edition)" }
    /// `YYYY-MM-DD` local.
    public var date: String
    /// Edition of that date; the list has one item per edition, newest first.
    public var edition: Int
    public var title: String
    public var partial: Bool
    public var empty: Bool
    public var paperCount: Int
    /// Papers of that digest without a `read_state` row.
    public var unreadCount: Int

    public init(date: String, edition: Int = 1, title: String, partial: Bool, empty: Bool, paperCount: Int, unreadCount: Int) {
        self.date = date
        self.edition = edition
        self.title = title
        self.partial = partial
        self.empty = empty
        self.paperCount = paperCount
        self.unreadCount = unreadCount
    }
}

/// The user's thumbs up / down on a paper (`feedback.verdict`).
public enum Verdict: Int, Codable, Sendable { case down = -1, up = 1 }
