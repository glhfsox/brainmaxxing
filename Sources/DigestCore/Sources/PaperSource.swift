import Foundation

/// What one source returned for one window.
public struct SourceFetch: Sendable, Equatable {
    public var papers: [RawPaper]
    /// The page cap was hit while entries were still inside the window.
    public var truncated: Bool
    /// Secondary sources: rows dropped as copies of arXiv papers, rows dropped as unusable
    /// (retracted, paratext, no abstract), and whether the per-run row cap stopped paging (by design, not a fault).
    public var merged: Int
    public var dropped: Int
    public var capped: Bool

    public init(papers: [RawPaper], truncated: Bool = false, merged: Int = 0, dropped: Int = 0, capped: Bool = false) {
        self.papers = papers
        self.truncated = truncated
        self.merged = merged
        self.dropped = dropped
        self.capped = capped
    }
}

public protocol PaperSource: Sendable {
    var id: SourceID { get }
    func fetch(since: Date, categories: [String]) async throws -> SourceFetch
}
