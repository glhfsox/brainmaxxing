import Foundation

public enum SourceID: String, Codable, Sendable, CaseIterable {
    case arxiv, openalex, hfPapers = "hf_papers"
}

/// A paper as a source returned it, before dedup. `id` is the arXiv id without version, or the short OpenAlex id (`W...`).
public struct RawPaper: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var title: String
    public var abstract: String
    public var authors: [String]
    /// Categories in source order (arXiv order).
    public var categories: [String]
    public var primaryCategory: String?
    public var absURL: URL?
    public var pdfURL: URL?
    public var published: Date
    public var updated: Date
    public var source: SourceID
    /// Journal or conference (OpenAlex `primary_location.source.display_name`); nil for arXiv. Omitted from JSON when nil.
    public var venue: String?
    /// Bare DOI (`10....`); nil for arXiv. Omitted from JSON when nil.
    public var doi: String?

    public init(
        id: String, version: Int, title: String, abstract: String, authors: [String], categories: [String],
        primaryCategory: String?, absURL: URL?, pdfURL: URL?, published: Date, updated: Date, source: SourceID,
        venue: String? = nil, doi: String? = nil
    ) {
        self.id = id
        self.version = version
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.categories = categories
        self.primaryCategory = primaryCategory
        self.absURL = absURL
        self.pdfURL = pdfURL
        self.published = published
        self.updated = updated
        self.source = source
        self.venue = venue
        self.doi = doi
    }
}

/// A stored paper with its triage outcome for one run.
public struct RankedPaper: Sendable, Equatable {
    public var paper: RawPaper
    public var score: Int
    public var oneLine: String
    public var tags: [String]
    public var selected: Bool
    public var rank: Int?
    /// The run whose triage produced `score`; differs from the listing run for carried-over papers.
    public var scoredInRunID: String?

    public init(paper: RawPaper, score: Int, oneLine: String, tags: [String], selected: Bool, rank: Int?, scoredInRunID: String? = nil) {
        self.paper = paper
        self.score = score
        self.oneLine = oneLine
        self.tags = tags
        self.selected = selected
        self.rank = rank
        self.scoredInRunID = scoredInRunID
    }
}
