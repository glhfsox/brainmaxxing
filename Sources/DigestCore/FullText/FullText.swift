import Foundation

public enum FullTextSource: String, Codable, Sendable { case html, pdf }

/// A stored figure. `index` numbers the kept figures 1...2 in order of appearance.
public struct Figure: Codable, Sendable, Equatable {
    public var paperID: String
    public var index: Int
    /// Relative to the home directory: `figures/<id>/<index>.png`.
    public var path: String
    /// Plain text, "Figure N: " prefix stripped.
    public var caption: String
    public var source: FullTextSource

    public init(paperID: String, index: Int, path: String, caption: String, source: FullTextSource) {
        self.paperID = paperID
        self.index = index
        self.path = path
        self.caption = caption
        self.source = source
    }
}

public struct FullTextResult: Sendable, Equatable {
    public var text: String
    /// At most two, already PNG-encoded, in order of appearance.
    public var figures: [(image: Data, caption: String)]
    public var source: FullTextSource

    public init(text: String, figures: [(image: Data, caption: String)], source: FullTextSource) {
        self.text = text
        self.figures = figures
        self.source = source
    }

    public static func == (a: FullTextResult, b: FullTextResult) -> Bool {
        a.text == b.text && a.source == b.source && a.figures.map(\.image) == b.figures.map(\.image)
            && a.figures.map(\.caption) == b.figures.map(\.caption)
    }
}

public protocol FullTextFetcher: Sendable {
    func fetch(_ paper: RawPaper) async throws -> FullTextResult
}

public enum FullTextError: LocalizedError, Equatable {
    case http(status: Int, url: String)
    case transport(String)
    case parse(String)
    case notAvailable(String)

    public var errorDescription: String? {
        switch self {
        case let .http(status, url): "HTTP \(status) for \(url)"
        case let .transport(reason): "network error fetching full text: \(reason)"
        case let .parse(reason): "cannot extract full text: \(reason)"
        case let .notAvailable(id): "no HTML or PDF available for \(id)"
        }
    }
}

public enum FullText {
    public static let truncationMarker = "\n[... truncated]"

    /// Cuts at the last blank line before `maxChars` (hard cut if there is none) and appends the marker.
    /// The file on disk is never truncated; this is only for the digest bundle.
    public static func truncate(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let prefix = text.prefix(max(0, maxChars))
        let kept = prefix.range(of: "\n\n", options: .backwards).map { prefix[..<$0.lowerBound] } ?? prefix
        return String(kept) + truncationMarker
    }

    /// File-name-safe form of an arXiv id (old-style ids contain `/`).
    public static func fileSafe(_ id: String) -> String { id.replacingOccurrences(of: "/", with: "_") }
}
