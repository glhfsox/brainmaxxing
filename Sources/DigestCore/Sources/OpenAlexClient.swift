import Foundation
import os

public enum OpenAlexError: LocalizedError, Equatable {
    case badStatus(Int)
    case parse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case let .badStatus(code): "OpenAlex API returned HTTP \(code)"
        case let .parse(reason): "cannot parse OpenAlex response: \(reason)"
        case let .transport(reason): "network error talking to OpenAlex: \(reason)"
        }
    }
}

/// An OpenAlex work for lookups (MCP tools): the paper as the fetch maps it plus citation data. Lookups never drop rows.
public struct OpenAlexWork: Sendable, Equatable {
    /// `id` is the short OpenAlex id (`W...`); `source` is `.openalex`.
    public var paper: RawPaper
    public var citedByCount: Int
    public var publicationYear: Int?
    /// The arXiv id (no version) when the work has an arXiv location.
    public var arxivID: String?

    public init(paper: RawPaper, citedByCount: Int, publicationYear: Int?, arxivID: String?) {
        self.paper = paper
        self.citedByCount = citedByCount
        self.publicationYear = publicationYear
        self.arxivID = arxivID
    }
}

/// OpenAlex works API: journal papers in the configured subfields, plus lookups for the MCP server.
/// Anonymous: no `mailto`, no `api_key`. Requests are sequential and >= 0.2 s apart (its own limiter, never arXiv's).
public struct OpenAlexClient: PaperSource {
    public let id = SourceID.openalex
    public static let baseURL = "https://api.openalex.org"
    public static let userAgent = "brainmaxxing/0.1"
    static let listSelect = "id,doi,display_name,publication_date,updated_date,authorships,abstract_inverted_index,locations,"
        + "primary_location,best_oa_location,primary_topic,is_retracted,is_paratext"
    static let lookupSelect = listSelect + ",publication_year,cited_by_count"
    static let maxRetryAfter: TimeInterval = 10

    private let transport: HTTPTransport
    private let rateLimiter: RateLimiter
    private let subfields: [String]
    private let maxPerRun: Int
    private let perPage: Int
    private let archive: RawArchive?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "openalex")

    public init(
        transport: HTTPTransport = URLSessionTransport(), rateLimiter: RateLimiter = RateLimiter(minInterval: 0.2),
        subfields: [String] = Config.defaultOpenAlexSubfields, maxPerRun: Int = 1000, perPage: Int = 200, archive: RawArchive? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.transport = transport
        self.rateLimiter = rateLimiter
        self.subfields = subfields
        self.maxPerRun = maxPerRun
        self.perPage = perPage
        self.archive = archive
        self.now = now
        self.sleep = sleep
    }

    // MARK: Fetch (pipeline)

    /// Works published from the UTC day after `since`'s to the run's local date in the configured subfields: rows of
    /// `since`'s own day would map to 00:00 UTC < `since` and never reach the selection pool; the lagged window
    /// overlaps the previous run, which covered that day. Pages by page number
    /// until a short page, `meta.count`, or `maxPerRun` rows were read (`capped`). `categories` (arXiv) is ignored.
    public func fetch(since: Date, categories: [String]) async throws -> SourceFetch {
        var result = SourceFetch(papers: [])
        var read = 0
        var page = 1
        while read < maxPerRun {
            let url = try listURL(since: since, page: page)
            let data = try await get(url, archiveName: "openalex-page\(page).json")
            let list = try Self.decode(ListResponse.self, data)
            let rows = Array(list.results.prefix(maxPerRun - read))
            read += rows.count
            for row in rows {
                switch Self.classify(row) {
                case let .keep(paper): result.papers.append(paper)
                case .arxivCopy: result.merged += 1
                case .unusable: result.dropped += 1
                }
            }
            let total = list.meta?.count ?? Int.max
            let more = list.results.count == perPage && page * perPage < total
            if read >= maxPerRun, rows.count < list.results.count || more {
                result.capped = true
                Self.log.notice("stopped at openalex_max_per_run = \(maxPerRun) of \(total) rows")
                break
            }
            guard more else { break }
            page += 1
        }
        return result
    }

    func listURL(since: Date, page: Int) throws -> URL {
        let from = since.addingTimeInterval(86_400)
        let filter = "from_publication_date:\(Self.utcDay(from)),to_publication_date:\(LocalDate.string(now())),"
            + "primary_topic.subfield.id:\(subfields.joined(separator: "|")),type:article,has_abstract:true,"
            + "primary_location.source.is_core:true"
        return try url("/works", [("filter", filter), ("select", Self.listSelect), ("per-page", "\(perPage)"), ("page", "\(page)")])
    }

    // MARK: Lookups (MCP)

    /// Full-text search over works, OpenAlex relevance order.
    public func search(query: String, limit: Int) async throws -> [OpenAlexWork] {
        try await list([("search", query)], limit: limit)
    }

    /// The work for an arXiv id (OpenAlex merges the preprint DOI into the published work); nil when unknown.
    public func work(arxivID: String) async throws -> OpenAlexWork? {
        try await single("/works/doi:10.48550/arXiv.\(arxivID)")
    }

    /// The work for a short (`W...`) or full (`https://openalex.org/W...`) OpenAlex id; nil when unknown.
    public func work(openalexID: String) async throws -> OpenAlexWork? {
        try await single("/works/\(Self.shortID(openalexID))")
    }

    /// Works the given work cites.
    public func references(of work: OpenAlexWork, limit: Int) async throws -> [OpenAlexWork] {
        try await list([("filter", "cited_by:\(work.paper.id)")], limit: limit)
    }

    /// Works citing the given work.
    public func citedBy(of work: OpenAlexWork, limit: Int) async throws -> [OpenAlexWork] {
        try await list([("filter", "cites:\(work.paper.id)")], limit: limit)
    }

    private func list(_ query: [(String, String)], limit: Int) async throws -> [OpenAlexWork] {
        let n = min(max(limit, 1), 200)
        let data = try await get(try url("/works", query + [("select", Self.lookupSelect), ("per-page", "\(n)")]), archiveName: nil)
        return try Self.decode(ListResponse.self, data).results.prefix(n).compactMap(Self.work(from:))
    }

    private func single(_ path: String) async throws -> OpenAlexWork? {
        do {
            let data = try await get(try url(path, [("select", Self.lookupSelect)]), archiveName: nil)
            return Self.work(from: try Self.decode(Row.self, data))
        } catch OpenAlexError.badStatus(404) {
            return nil
        }
    }

    // MARK: HTTP

    private func url(_ path: String, _ query: [(String, String)]) throws -> URL {
        var components = URLComponents(string: Self.baseURL + path)
        components?.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components?.url else { throw OpenAlexError.parse("bad request URL for \(path)") }
        return url
    }

    /// One GET. 429 / 5xx: one retry when `Retry-After` is <= 10 s, otherwise (and after it) `OpenAlexError.badStatus`.
    private func get(_ url: URL, archiveName: String?) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        for attempt in 1...2 {
            try await rateLimiter.wait()
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await transport.send(request)
            } catch {
                throw OpenAlexError.transport(error.localizedDescription)
            }
            if response.statusCode == 200 {
                if let archiveName { try archive?.save(data, name: archiveName) }
                return data
            }
            let retryable = response.statusCode == 429 || (500...599).contains(response.statusCode)
            guard retryable, attempt == 1, let wait = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init),
                  wait <= Self.maxRetryAfter
            else { throw OpenAlexError.badStatus(response.statusCode) }
            Self.log.warning("OpenAlex HTTP \(response.statusCode), retrying in \(wait)s")
            try await sleep(max(0, wait))
        }
        throw OpenAlexError.badStatus(0)
    }

    // MARK: Mapping

    enum Classification: Equatable {
        case keep(RawPaper)
        case arxivCopy
        case unusable
    }

    /// Any arXiv location -> merged; retracted, paratext, or no title / abstract / date -> dropped.
    static func classify(_ row: Row) -> Classification {
        if hasArxivLocation(row) { return .arxivCopy }
        if row.isRetracted == true || row.isParatext == true { return .unusable }
        guard let paper = paper(from: row) else { return .unusable }
        return .keep(paper)
    }

    static func work(from row: Row) -> OpenAlexWork? {
        guard let paper = paper(from: row, requireAbstract: false) else { return nil }
        return OpenAlexWork(paper: paper, citedByCount: row.citedByCount ?? 0, publicationYear: row.publicationYear, arxivID: arxivID(row))
    }

    /// Lookups (`requireAbstract: false`) keep works without an abstract; the fetch does not (triage needs one).
    static func paper(from row: Row, requireAbstract: Bool = true) -> RawPaper? {
        let title = stripTags(row.displayName ?? "")
        let abstract = abstract(row.abstractInvertedIndex)
        guard !title.isEmpty, !requireAbstract || !abstract.isEmpty, let day = row.publicationDate, let published = utcDate(day) else { return nil }
        let doi = row.doi.map(bareDOI)
        let subfield = row.primaryTopic?.subfield?.displayName
        return RawPaper(
            id: shortID(row.id), version: 1, title: title, abstract: abstract,
            authors: (row.authorships ?? []).compactMap { $0.author?.displayName.map(ArxivClient.normalize) },
            categories: subfield.map { [$0] } ?? [], primaryCategory: subfield,
            absURL: doi.flatMap { URL(string: "https://doi.org/\($0)") } ?? URL(string: "https://openalex.org/\(shortID(row.id))"),
            pdfURL: row.bestOALocation?.pdfURL.flatMap(URL.init(string:)), published: published,
            updated: row.updatedDate.flatMap(utcTimestamp) ?? published, source: .openalex,
            venue: venue(row.primaryLocation), doi: doi)
    }

    /// `primary_location.source.display_name`, else `raw_source_name` (sources OpenAlex has not matched, e.g. ACL Findings).
    static func venue(_ location: Row.Location?) -> String? {
        let name = location?.source?.displayName ?? location?.rawSourceName
        return name.map(ArxivClient.normalize).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Words placed at their positions; gaps are skipped.
    static func abstract(_ index: [String: [Int]]?) -> String {
        guard let index else { return "" }
        var words: [(Int, String)] = []
        for (word, positions) in index { for p in positions { words.append((p, word)) } }
        return ArxivClient.normalize(words.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " "))
    }

    static func stripTags(_ s: String) -> String {
        ArxivClient.normalize(s.replacing(/<[^>]*>/, with: ""))
    }

    static func shortID(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// `https://doi.org/10.1103/x` -> `10.1103/x`.
    static func bareDOI(_ doi: String) -> String {
        guard let range = doi.range(of: "doi.org/", options: .caseInsensitive) else { return doi }
        return String(doi[range.upperBound...])
    }

    private static func locationURLs(_ row: Row) -> [String] {
        ((row.locations ?? []) + [row.primaryLocation, row.bestOALocation].compactMap { $0 })
            .flatMap { [$0.landingPageURL, $0.pdfURL].compactMap { $0?.lowercased() } }
    }

    static func hasArxivLocation(_ row: Row) -> Bool {
        let urls = locationURLs(row) + [row.doi?.lowercased()].compactMap { $0 }
        return urls.contains { $0.contains("arxiv.org/") || $0.contains("10.48550/arxiv.") }
    }

    /// From an `arxiv.org/abs|pdf/<id>` URL or a `10.48550/arXiv.<id>` DOI, version stripped.
    static func arxivID(_ row: Row) -> String? {
        for url in locationURLs(row) + [row.doi?.lowercased()].compactMap({ $0 }) {
            let tail: Substring
            if let r = url.range(of: "arxiv.org/abs/") ?? url.range(of: "arxiv.org/pdf/") {
                tail = url[r.upperBound...]
            } else if let r = url.range(of: "10.48550/arxiv.") {
                tail = url[r.upperBound...]
            } else {
                continue
            }
            var id = String(tail.prefix { $0 != "?" && $0 != "#" })
            if id.hasSuffix(".pdf") { id.removeLast(4) }
            if let match = id.firstMatch(of: /v\d+$/) { id.removeSubrange(match.range) }
            if ArxivClient.isArxivID(id) { return id }
        }
        return nil
    }

    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return LocalDate.string(date, calendar: calendar)
    }

    /// `YYYY-MM-DD` at 00:00 UTC.
    static func utcDate(_ day: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return LocalDate.date(day, calendar: calendar)
    }

    /// `2026-10-21T09:56:26.102985` (no zone; OpenAlex is UTC) -> seconds precision.
    static func utcTimestamp(_ s: String) -> Date? {
        try? Date(String(s.prefix(19)) + "Z", strategy: .iso8601)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw OpenAlexError.parse(error.localizedDescription)
        }
    }

    // MARK: Wire types (only the selected fields)

    struct ListResponse: Decodable {
        struct Meta: Decodable { var count: Int? }
        var meta: Meta?
        var results: [Row]
    }

    struct Row: Decodable {
        struct Authorship: Decodable {
            struct Author: Decodable {
                var displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            var author: Author?
        }
        struct Location: Decodable {
            struct Source: Decodable {
                var displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            var landingPageURL: String?
            var pdfURL: String?
            var source: Source?
            var rawSourceName: String?
            enum CodingKeys: String, CodingKey { case landingPageURL = "landing_page_url", pdfURL = "pdf_url", source, rawSourceName = "raw_source_name" }
        }
        struct Topic: Decodable {
            struct Subfield: Decodable {
                var displayName: String?
                enum CodingKeys: String, CodingKey { case displayName = "display_name" }
            }
            var subfield: Subfield?
        }

        var id: String
        var doi: String?
        var displayName: String?
        var publicationDate: String?
        var publicationYear: Int?
        var updatedDate: String?
        var authorships: [Authorship]?
        var abstractInvertedIndex: [String: [Int]]?
        var locations: [Location]?
        var primaryLocation: Location?
        var bestOALocation: Location?
        var primaryTopic: Topic?
        var isRetracted: Bool?
        var isParatext: Bool?
        var citedByCount: Int?

        enum CodingKeys: String, CodingKey {
            case id, doi, displayName = "display_name", publicationDate = "publication_date", publicationYear = "publication_year"
            case updatedDate = "updated_date", authorships, abstractInvertedIndex = "abstract_inverted_index", locations
            case primaryLocation = "primary_location", bestOALocation = "best_oa_location", primaryTopic = "primary_topic"
            case isRetracted = "is_retracted", isParatext = "is_paratext", citedByCount = "cited_by_count"
        }
    }
}
