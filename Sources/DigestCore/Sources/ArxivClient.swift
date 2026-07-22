import Foundation
import os

public enum ArxivError: LocalizedError, Equatable {
    case badStatus(Int)
    case parse(String)
    case transport(String)
    /// A page with 0 entries although `start < totalResults`, still empty after retries.
    case emptyPage(start: Int)

    public var errorDescription: String? {
        switch self {
        case let .badStatus(code): "arXiv API returned HTTP \(code)"
        case let .parse(reason): "cannot parse arXiv response: \(reason)"
        case let .transport(reason): "network error talking to arXiv: \(reason)"
        case let .emptyPage(start): "arXiv API returned an empty page at start=\(start) inside the result set"
        }
    }
}

/// arXiv Atom API source. One request per 3 s, newest `updated` first, paginated by `start`.
public struct ArxivClient: PaperSource {
    public let id = SourceID.arxiv
    public static let baseURL = "https://export.arxiv.org/api/query"
    public static let userAgent = "brainmaxxing/0.1 (+https://github.com/brainmaxxing)"

    private let transport: HTTPTransport
    private let rateLimiter: RateLimiter
    private let includeReversions: Bool
    private let pageSize: Int
    private let maxPages: Int
    private let archive: RawArchive?
    private let maxAttempts: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "arxiv")

    public init(
        transport: HTTPTransport = URLSessionTransport(), rateLimiter: RateLimiter = RateLimiter(minInterval: 3),
        includeReversions: Bool = false, pageSize: Int = 1000, maxPages: Int = 10, archive: RawArchive? = nil,
        maxAttempts: Int = 3, sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.rateLimiter = rateLimiter
        self.includeReversions = includeReversions
        self.pageSize = pageSize
        self.maxPages = maxPages
        self.archive = archive
        self.maxAttempts = maxAttempts
        self.sleep = sleep
    }

    /// Entries with `updated >= since`; unless `includeReversions`, only those with `published >= since`
    /// (new inside the window, whatever version is served). `truncated` when the page cap is hit while the
    /// oldest entry on the last page is still inside the window.
    public func fetch(since: Date, categories: [String]) async throws -> SourceFetch {
        var result: [RawPaper] = []
        for page in 0..<maxPages {
            let start = page * pageSize
            let entries = try await fetchPage(start: start, page: page, categories: categories)
            let fresh = entries.filter { $0.updated >= since }
            result += fresh.filter { includeReversions || $0.published >= since }
            // Entries within a page are not strictly ordered by `updated`: stop only when a whole page is old.
            if fresh.isEmpty || entries.count < pageSize { break }
            if page == maxPages - 1, let oldest = entries.map(\.updated).min(), oldest >= since {
                Self.log.warning("hit the \(maxPages)-page cap at \(oldest, privacy: .public); older papers in the window are skipped")
                return SourceFetch(papers: result, truncated: true)
            }
        }
        return SourceFetch(papers: result, truncated: false)
    }

    func pageURL(start: Int, categories: [String]) -> URL? {
        let query = categories.map { "cat:\($0)" }.joined(separator: "+OR+")
        return URL(string: "\(Self.baseURL)?search_query=\(query)&sortBy=lastUpdatedDate&sortOrder=descending&start=\(start)&max_results=\(pageSize)")
    }

    /// One page, parsed. HTTP 429 / 503 and an empty page inside the result set are retried with the same policy.
    private func fetchPage(start: Int, page: Int, categories: [String]) async throws -> [RawPaper] {
        guard let url = pageURL(start: start, categories: categories) else { throw ArxivError.parse("bad categories \(categories)") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for attempt in 1...max(1, maxAttempts) {
            try await rateLimiter.wait()
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await transport.send(request)
            } catch {
                throw ArxivError.transport(error.localizedDescription)
            }
            let retryAfter: Double
            if response.statusCode == 200 {
                try archive?.save(data, name: "arxiv-page\(page).xml")
                let feed = try Self.parseFeed(data)
                // An empty page while the feed says more results exist is a transient API fault.
                guard feed.entries.isEmpty, let total = feed.totalResults, start < total else { return feed.entries }
                guard attempt < maxAttempts else { throw ArxivError.emptyPage(start: start) }
                Self.log.warning("arXiv returned an empty page at start=\(start) of \(total)")
                retryAfter = 0
            } else {
                // arXiv answers bursts with 429 / 503 (often with Retry-After); back off and retry those only.
                guard [429, 503].contains(response.statusCode), attempt < maxAttempts else { throw ArxivError.badStatus(response.statusCode) }
                retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
            }
            let delay = max(retryAfter, 10 * Double(attempt))
            Self.log.warning("arXiv HTTP \(response.statusCode), retrying in \(delay)s")
            try await sleep(delay)
        }
        throw ArxivError.badStatus(0)
    }

    // MARK: Parsing

    /// Parses an Atom feed into papers (all versions; filtering is the caller's job).
    public static func parse(_ data: Data) throws -> [RawPaper] {
        try parseFeed(data).entries
    }

    /// Entries plus `opensearch:totalResults` (nil if absent).
    static func parseFeed(_ data: Data) throws -> (entries: [RawPaper], totalResults: Int?) {
        let delegate = AtomDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() else {
            throw ArxivError.parse(parser.parserError?.localizedDescription ?? "XML error")
        }
        return (try delegate.entries.map(paper(from:)), delegate.totalResults)
    }

    private static func paper(from e: AtomDelegate.Entry) throws -> RawPaper {
        guard let range = e.id.range(of: "/abs/") else { throw ArxivError.parse("unexpected id \(e.id)") }
        let versioned = String(e.id[range.upperBound...])
        var baseID = versioned
        var version = 1
        if let v = versioned.lastIndex(of: "v"), let n = Int(versioned[versioned.index(after: v)...]) {
            baseID = String(versioned[..<v])
            version = n
        }
        guard let published = try? Date(e.published, strategy: .iso8601),
              let updated = try? Date(e.updated, strategy: .iso8601)
        else { throw ArxivError.parse("bad dates for \(e.id)") }
        return RawPaper(
            id: baseID, version: version, title: normalize(e.title), abstract: normalize(e.summary),
            authors: e.authors.map(normalize), categories: e.categories, primaryCategory: e.primaryCategory,
            absURL: e.absLink.flatMap(URL.init(string:)), pdfURL: e.pdfLink.flatMap(URL.init(string:)),
            published: published, updated: updated, source: .arxiv, doi: e.doi.isEmpty ? nil : e.doi)
    }

    /// New-style (`2610.28632`) or old-style (`math.DG/0601001`) arXiv id without version; OpenAlex ids (`W...`) are not.
    public static func isArxivID(_ id: String) -> Bool {
        id.wholeMatch(of: /\d{4}\.\d{4,5}/) != nil || id.wholeMatch(of: /[a-z-]+(\.[A-Za-z-]+)?\/\d{7}/) != nil
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// XMLParser delegate; used synchronously inside `ArxivClient.parse`, never shared across tasks.
private final class AtomDelegate: NSObject, XMLParserDelegate {
    struct Entry {
        var id = "", title = "", summary = "", published = "", updated = "", doi = ""
        var authors: [String] = [], categories: [String] = []
        var primaryCategory: String?, absLink: String?, pdfLink: String?
    }

    var entries: [Entry] = []
    var totalResults: Int?
    private var current: Entry?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "entry" { current = Entry(); return }
        guard current != nil else { return }
        switch name {
        case "category": if let term = attributes["term"] { current?.categories.append(term) }
        case "primary_category": current?.primaryCategory = attributes["term"]
        case "link":
            if attributes["title"] == "pdf" { current?.pdfLink = attributes["href"] }
            else if attributes["rel"] == "alternate" { current?.absLink = attributes["href"] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "entry" {
            if let current { entries.append(current) }
            current = nil
            return
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if current == nil, name == "totalResults" { totalResults = Int(value) }
        guard current != nil else { return }
        switch name {
        case "id": current?.id = value
        case "title": current?.title = value
        case "summary": current?.summary = value
        case "published": current?.published = value
        case "updated": current?.updated = value
        case "name": current?.authors.append(value)
        case "doi": current?.doi = value
        default: break
        }
    }
}
