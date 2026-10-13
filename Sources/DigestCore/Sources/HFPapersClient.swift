import Foundation

public enum HFPapersError: LocalizedError, Equatable {
    case badStatus(Int)
    case parse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case let .badStatus(code): "HF Daily Papers API returned HTTP \(code)"
        case let .parse(reason): "cannot parse HF Daily Papers response: \(reason)"
        case let .transport(reason): "network error talking to HF Daily Papers: \(reason)"
        }
    }
}

/// One HF Daily Papers entry.
public struct HFDailyPaper: Sendable, Equatable {
    public var arxivID: String
    public var title: String
    /// `paper.ai_summary` if non-empty, else `paper.summary` cut at 600 characters; whitespace-collapsed.
    public var summary: String
    public var upvotes: Int
    public var authors: [String]
    public var publishedAt: Date?
    /// The full `paper.summary` (the arXiv abstract), stored as the paper's abstract.
    public var abstract: String

    public init(arxivID: String, title: String, summary: String, upvotes: Int, authors: [String], publishedAt: Date?, abstract: String) {
        self.arxivID = arxivID
        self.title = title
        self.summary = summary
        self.upvotes = upvotes
        self.authors = authors
        self.publishedAt = publishedAt
        self.abstract = abstract
    }

    /// The `papers` row stored for links and chat lookups (source `hf_papers`, no triage score).
    public func rawPaper(listedOn day: Date) -> RawPaper {
        RawPaper(id: arxivID, version: 1, title: title, abstract: abstract.isEmpty ? summary : abstract, authors: authors, categories: [],
                 primaryCategory: nil, absURL: URL(string: "https://arxiv.org/abs/\(arxivID)"), pdfURL: nil,
                 published: publishedAt ?? day, updated: publishedAt ?? day, source: .hfPapers)
    }
}

/// HuggingFace Daily Papers JSON API. Not a `PaperSource`: its papers never go to triage; they fill the digest's
/// `<hf_papers>` after selection.
public struct HFPapersClient: Sendable {
    public static let baseURL = "https://huggingface.co/api/daily_papers"
    public static let summaryMaxChars = 600
    /// The run's local date and the 3 days before.
    public static let maxDays = 4

    private let transport: HTTPTransport
    private let archive: RawArchive?

    public init(transport: HTTPTransport = URLSessionTransport(), archive: RawArchive? = nil) {
        self.transport = transport
        self.archive = archive
    }

    /// The list for one `YYYY-MM-DD`.
    public func daily(date: String) async throws -> [HFDailyPaper] {
        guard let url = URL(string: "\(Self.baseURL)?date=\(date)") else { throw HFPapersError.parse("bad date \(date)") }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(OpenAlexClient.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw HFPapersError.transport(error.localizedDescription)
        }
        guard response.statusCode == 200 else { throw HFPapersError.badStatus(response.statusCode) }
        try archive?.save(data, name: "hf-\(date).json")
        return try Self.parse(data)
    }

    /// Lists for `day` and the 3 days before (stopping once >= `topK` eligible candidates), union by id
    /// keeping max upvotes, minus `excluding`, by upvotes desc then id, first `topK`. A failed day stops paging; the days
    /// already fetched are kept and the error is returned for the caller to log.
    public func candidates(day: Date, excluding: Set<String>, topK: Int, calendar: Calendar = .current) async
        -> (papers: [HFDailyPaper], failure: (any Error)?) {
        var lists: [[HFDailyPaper]] = []
        var failure: (any Error)?
        for offset in 0..<Self.maxDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: day) else { continue }
            do {
                lists.append(try await daily(date: LocalDate.string(date, calendar: calendar)))
            } catch {
                failure = error
                break
            }
            if Self.select(lists, excluding: excluding, topK: Int.max).count >= topK { break }
        }
        return (Self.select(lists, excluding: excluding, topK: topK), failure)
    }

    public static func select(_ lists: [[HFDailyPaper]], excluding: Set<String>, topK: Int) -> [HFDailyPaper] {
        var best: [String: HFDailyPaper] = [:]
        for paper in lists.joined() where !excluding.contains(paper.arxivID) {
            if let current = best[paper.arxivID], current.upvotes >= paper.upvotes { continue }
            best[paper.arxivID] = paper
        }
        let sorted = best.values.sorted { $0.upvotes != $1.upvotes ? $0.upvotes > $1.upvotes : $0.arxivID < $1.arxivID }
        return Array(sorted.prefix(max(0, topK)))
    }

    /// A body that is not a JSON array is a parse error; single entries that don't decode are skipped.
    public static func parse(_ data: Data) throws -> [HFDailyPaper] {
        let entries: [Entry]
        do {
            entries = try JSONDecoder().decode([Lenient].self, from: data).compactMap(\.entry)
        } catch {
            throw HFPapersError.parse(error.localizedDescription)
        }
        return entries.compactMap { e in
            let p = e.paper
            let id = p.id.trimmingCharacters(in: .whitespaces)
            guard ArxivClient.isArxivID(id) else { return nil }
            let abstract = ArxivClient.normalize(p.summary ?? "")
            let ai = ArxivClient.normalize(p.aiSummary ?? "")
            let published = p.publishedAt.flatMap {
                (try? Date($0, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))) ?? (try? Date($0, strategy: .iso8601))
            }
            return HFDailyPaper(arxivID: id, title: ArxivClient.normalize(p.title ?? e.title ?? ""),
                                summary: ai.isEmpty ? String(abstract.prefix(summaryMaxChars)) : ai, upvotes: p.upvotes ?? 0,
                                authors: (p.authors ?? []).compactMap { $0.name.map(ArxivClient.normalize) }.filter { !$0.isEmpty },
                                publishedAt: published, abstract: abstract)
        }
    }

    // MARK: Wire types

    /// One array element; nil when it doesn't decode as an `Entry`.
    struct Lenient: Decodable {
        var entry: Entry?
        init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
    }

    struct Entry: Decodable {
        struct Paper: Decodable {
            struct Author: Decodable { var name: String? }
            var id: String
            var title: String?
            var summary: String?
            var aiSummary: String?
            var upvotes: Int?
            var authors: [Author]?
            var publishedAt: String?
            enum CodingKeys: String, CodingKey { case id, title, summary, aiSummary = "ai_summary", upvotes, authors, publishedAt }
        }
        var paper: Paper
        var title: String?
    }
}
