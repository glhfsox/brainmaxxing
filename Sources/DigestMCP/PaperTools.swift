import DigestCore
import Foundation
import MCP
import os

/// Tool and resource handlers. Every failure becomes a short `isError` result; nothing thrown here stops the server.
struct PaperTools: Sendable {
    let context: ServerContext
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "mcp")

    func call(_ name: String, _ arguments: [String: Value]?) async -> CallTool.Result {
        let args = arguments ?? [:]
        do {
            let text: String
            switch name {
            case "search_arxiv": text = try await searchArxiv(args)
            case "get_paper": text = try await getPaper(args)
            case "get_fulltext": text = try await getFulltext(args)
            case "search_openalex": text = try await searchOpenAlex(args)
            case "get_citations": text = try await getCitations(args)
            case "search_digests": text = try await searchDigests(args)
            case "get_digest": text = try await getDigest(args)
            default: throw ToolError("unknown tool \(name)")
            }
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch {
            let message = (error as? ToolError)?.message ?? Self.short(error)
            Self.log.notice("tool \(name, privacy: .public) failed: \(message, privacy: .public)")
            return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
        }
    }

    // MARK: Tools

    struct PaperHit: Encodable {
        let id: String, title: String, authors: [String], published: String, abstract: String
    }

    func searchArxiv(_ a: [String: Value]) async throws -> String {
        let query = try Self.string(a, "query")
        let categories = a["categories"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let since = try Self.date(a, "since")
        let max = try Self.int(a, "max", default: 10, range: 1...ToolCatalog.maxSearch)
        let papers = try await context.arxiv.search(query: query, categories: categories, since: since, max: max)
        return try Self.json(papers.prefix(max).map {
            PaperHit(id: $0.id, title: $0.title, authors: Self.authors($0.authors), published: LocalDate.string($0.published),
                     abstract: Self.cut($0.abstract, ToolCatalog.abstractChars))
        })
    }

    struct PaperDetail: Encodable {
        let id: String, version: Int, title: String, authors: [String], categories: [String]
        let published: String, updated: String, absURL: String?, pdfURL: String?, hasFulltext: Bool, abstract: String
        /// OpenAlex papers only (omitted for arXiv).
        let venue: String?, doi: String?
        let triage: Triage?
        enum CodingKeys: String, CodingKey {
            case id, version, title, authors, categories, published, updated, absURL = "abs_url", pdfURL = "pdf_url"
            case hasFulltext = "has_fulltext", abstract, venue, doi, triage
        }
        struct Triage: Encodable {
            let score: Int, oneLine: String, tags: [String]
            enum CodingKeys: String, CodingKey { case score, oneLine = "one_line", tags }
        }
    }

    func getPaper(_ a: [String: Value]) async throws -> String {
        let id = try Self.paperID(a)
        let store = try await context.store.get()
        let paper = try await localOrRemotePaper(id, store: store)
        let hasFulltext = try await store.fullTextSource(paperID: id) != nil
        let triage = try await store.latestTriage(paperID: id)
        return try Self.json(PaperDetail(
            id: paper.id, version: paper.version, title: paper.title, authors: paper.authors, categories: paper.categories,
            published: LocalDate.string(paper.published), updated: LocalDate.string(paper.updated),
            absURL: paper.absURL?.absoluteString, pdfURL: paper.pdfURL?.absoluteString, hasFulltext: hasFulltext,
            abstract: paper.abstract, venue: paper.venue, doi: paper.doi,
            triage: triage.map { PaperDetail.Triage(score: $0.score, oneLine: $0.oneLine, tags: $0.tags) }))
    }

    struct FulltextSlice: Encodable {
        let id: String, totalChars: Int, offset: Int, nextOffset: Int?, text: String
        enum CodingKeys: String, CodingKey { case id, totalChars = "total_chars", offset, nextOffset = "next_offset", text }
    }

    /// What `get_fulltext` answers for an OpenAlex paper: journal papers have no stored full text.
    struct AbstractOnly: Encodable {
        let id: String, fulltextAvailable = false, note: String, abstract: String
        enum CodingKeys: String, CodingKey { case id, fulltextAvailable = "fulltext_available", note, abstract }
    }

    func getFulltext(_ a: [String: Value]) async throws -> String {
        let id = try Self.paperID(a)
        if PaperID.isOpenAlex(id) {
            let store = try await context.store.get()
            let paper = try await localOrRemotePaper(id, store: store)
            return try Self.json(AbstractOnly(
                id: id, note: "Full text is not available for journal papers from OpenAlex; only the abstract is. "
                    + "Answer from the abstract and say so.", abstract: paper.abstract))
        }
        let maxChars = try Self.int(a, "max_chars", default: ToolCatalog.defaultFulltextChars, range: 500...ToolCatalog.maxFulltextChars)
        let offset = try Self.int(a, "offset", default: 0, range: 0...Int.max)
        let store = try await context.store.get()
        var text = try await store.fullText(paperID: id)
        if text == nil {
            let paper = try await localOrRemotePaper(id, store: store)
            let result: FullTextResult
            do {
                result = try await context.fullText.fetch(paper)
            } catch {
                throw ToolError("could not fetch the full text of \(id): \(Self.short(error))")
            }
            try await store.saveFullText(paperID: id, text: result.text, source: result.source)
            text = result.text
        }
        let full = text ?? ""
        let start = full.index(full.startIndex, offsetBy: offset, limitedBy: full.endIndex) ?? full.endIndex
        let end = full.index(start, offsetBy: maxChars, limitedBy: full.endIndex) ?? full.endIndex
        let slice = String(full[start..<end])
        return try Self.json(FulltextSlice(
            id: id, totalChars: full.count, offset: min(offset, full.count),
            nextOffset: end < full.endIndex ? offset + slice.count : nil, text: slice))
    }

    /// One OpenAlex work, compact. `abstract` only in search results; nil fields are omitted.
    struct WorkHit: Encodable {
        let id: String, arxivID: String?, title: String, venue: String?, year: Int?, citedByCount: Int, doi: String?
        let pdfURL: String?, abstract: String?
        enum CodingKeys: String, CodingKey {
            case id, arxivID = "arxiv_id", title, venue, year, citedByCount = "cited_by_count", doi, pdfURL = "pdf_url", abstract
        }

        init(_ w: OpenAlexWork, abstractChars: Int? = nil) {
            id = w.paper.id
            arxivID = w.arxivID
            title = w.paper.title
            venue = w.paper.venue
            year = w.publicationYear
            citedByCount = w.citedByCount
            doi = w.paper.doi
            pdfURL = w.paper.pdfURL?.absoluteString
            abstract = abstractChars.flatMap { w.paper.abstract.isEmpty ? nil : PaperTools.cut(w.paper.abstract, $0) }
        }
    }

    func searchOpenAlex(_ a: [String: Value]) async throws -> String {
        let query = try Self.string(a, "query")
        let since = try Self.date(a, "since")
        let max = try Self.int(a, "max", default: 10, range: 1...ToolCatalog.maxSearch)
        // `OpenAlexClient.search` has no date filter: with `since`, over-fetch one page and filter by publication date.
        let works = try await openalex { try await context.openalex.search(query: query, limit: since == nil ? max : ToolCatalog.openalexSincePool) }
        let kept = works.filter { w in since.map { w.paper.published >= $0 } ?? true }
        return try Self.json(kept.prefix(max).map { WorkHit($0, abstractChars: ToolCatalog.openalexAbstractChars) })
    }

    struct Citations: Encodable {
        let paper: WorkHit, direction: String, works: [WorkHit]
    }

    func getCitations(_ a: [String: Value]) async throws -> String {
        let raw = try Self.string(a, "id")
        let direction = try Self.string(a, "direction")
        guard direction == "references" || direction == "cited_by" else {
            throw ToolError("direction must be references or cited_by, got \(direction)")
        }
        let max = try Self.int(a, "max", default: 10, range: 1...ToolCatalog.maxSearch)
        guard let id = PaperID.resolve(raw) else {
            throw ToolError("not an arXiv or OpenAlex id: \(raw) (expected e.g. 2610.12345 or W4381712656)")
        }
        let work = try await openalex {
            PaperID.isOpenAlex(id) ? try await context.openalex.work(openalexID: id) : try await context.openalex.work(arxivID: id)
        }
        guard let work else { throw ToolError("\(raw) not found in OpenAlex") }
        let works = try await openalex {
            direction == "references"
                ? try await context.openalex.references(of: work, limit: max)
                : try await context.openalex.citedBy(of: work, limit: max)
        }
        return try Self.json(Citations(paper: WorkHit(work), direction: direction, works: works.prefix(max).map { WorkHit($0) }))
    }

    /// OpenAlex failures as one-line tool errors.
    private func openalex<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as OpenAlexError {
            switch error {
            case let .transport(reason): throw ToolError("OpenAlex is unreachable: \(Self.cut(reason, 200))")
            case let .badStatus(code): throw ToolError("OpenAlex API returned HTTP \(code); try again later")
            case .parse: throw ToolError("OpenAlex returned a response that could not be parsed")
            }
        }
    }

    struct SearchHit: Encodable {
        let kind: String, date: String, title: String, snippet: String
        /// Digest hits only.
        let edition: Int?
    }

    func searchDigests(_ a: [String: Value]) async throws -> String {
        let query = try Self.string(a, "query")
        let max = try Self.int(a, "max", default: 10, range: 1...ToolCatalog.maxSearch)
        let store = try await context.store.get()
        let digests = try await store.searchDigests(query, limit: max).map {
            SearchHit(kind: "digest", date: $0.date, title: $0.title, snippet: $0.snippet, edition: $0.edition)
        }
        let chat = try await store.searchChat(query, limit: max).map { m in
            // Conversation ids are `digest-<date>` or `general`; the message date stands in for the latter.
            let date = m.conversationID.hasPrefix("digest-") ? String(m.conversationID.dropFirst(7)) : LocalDate.string(m.createdAt)
            return SearchHit(kind: "chat", date: date, title: m.role.rawValue, snippet: Self.cut(m.content, 300), edition: nil)
        }
        // Digest hits first: they are the curated record; chat fills the remaining slots.
        return try Self.json(Array((digests + chat).prefix(max)))
    }

    func getDigest(_ a: [String: Value]) async throws -> String {
        let date = try Self.string(a, "date")
        guard a["edition"] != nil else { return try await digestJSON(date) }
        let edition = try Self.int(a, "edition", default: 0, range: 0...Int.max)
        guard edition >= 1 else { throw ToolError("edition must be a positive integer") }
        return try await digestJSON(date, edition: edition)
    }

    // MARK: Resources

    func readResource(_ uri: String) async throws -> ReadResource.Result {
        if uri.hasPrefix("digest://") {
            let json = try await digestJSON(String(uri.dropFirst("digest://".count)))
            return .init(contents: [.text(json, uri: uri, mimeType: "application/json")])
        }
        if uri.hasPrefix("paper://") {
            let raw = String(uri.dropFirst("paper://".count))
            guard let id = PaperID.resolve(raw) else { throw MCPError.invalidParams("not an arXiv or OpenAlex id: \(raw)") }
            let store = try await context.store.get()
            let p = try await localOrRemotePaper(id, store: store)
            let label = PaperID.isOpenAlex(p.id) ? p.id : "\(p.id)v\(p.version)"
            let journal = [p.venue, p.doi.map { "DOI \($0)" }].compactMap { $0 }.joined(separator: " / ")
            let markdown = """
                # \(p.title)

                **\(label)** / \(p.authors.joined(separator: ", "))
                Categories: \(p.categories.joined(separator: ", ")) / published \(LocalDate.string(p.published)) / \
                updated \(LocalDate.string(p.updated))\(journal.isEmpty ? "" : "\n" + journal)
                \(p.absURL.map { "<\($0.absoluteString)>" } ?? "")

                \(p.abstract)
                """
            return .init(contents: [.text(markdown, uri: uri, mimeType: "text/markdown")])
        }
        throw MCPError.invalidParams("unknown resource \(uri)")
    }

    // MARK: Helpers

    /// The digest JSON plus `edition` and `editions_available`; `edition: nil` is the latest edition.
    private func digestJSON(_ rawDate: String, edition: Int? = nil) async throws -> String {
        let date = rawDate == "today" ? LocalDate.string(context.now()) : rawDate
        guard LocalDate.date(date) != nil, date.count == 10 else { throw ToolError("date must be YYYY-MM-DD or today, got \(rawDate)") }
        let store = try await context.store.get()
        guard let latest = try await store.digest(date: date) else {
            let latest = try await store.latestDigest()?.date
            throw ToolError("no digest for \(date)" + (latest.map { "; the latest is \($0)" } ?? "; no digests stored yet"))
        }
        // Editions of a date are 1...N with none ever deleted, so the latest number lists them all.
        let available = Array(1...latest.edition)
        var digest = latest
        if let edition, edition != latest.edition {
            guard let other = try await store.digest(date: date, edition: edition) else {
                throw ToolError("no edition \(edition) for \(date); editions available: \(available.map(String.init).joined(separator: ", "))")
            }
            digest = other
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(EditionedDigest(digest: digest, available: available)), as: UTF8.self)
    }

    /// `Digest`'s own keys plus the edition fields, which are not part of the stored digest JSON.
    private struct EditionedDigest: Encodable {
        let digest: Digest, available: [Int]
        enum CodingKeys: String, CodingKey { case edition, editionsAvailable = "editions_available" }
        func encode(to encoder: Encoder) throws {
            try digest.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(digest.edition, forKey: .edition)
            try c.encode(available, forKey: .editionsAvailable)
        }
    }

    /// Stored paper, else arXiv metadata (stored so a later full-text fetch can attach to it). OpenAlex ids are
    /// looked up in the store only.
    private func localOrRemotePaper(_ id: String, store: Store) async throws -> RawPaper {
        if let p = try await store.paper(id: id) { return p }
        if PaperID.isOpenAlex(id) {
            throw ToolError("\(id) is not in the local library; use get_citations or search_openalex for OpenAlex works the app has not stored")
        }
        guard let remote = try await context.arxiv.paper(id: id) else { throw ToolError("no arXiv paper with id \(id)") }
        try await store.upsertPapers([remote], runID: nil)
        return remote
    }

    /// A normalized arXiv id or a short OpenAlex id (`W...`).
    static func paperID(_ a: [String: Value]) throws -> String {
        let raw = try string(a, "id")
        guard let id = PaperID.resolve(raw) else {
            throw ToolError("not an arXiv or OpenAlex id: \(raw) (expected e.g. 2610.12345 or W4381712656)")
        }
        return id
    }

    static func string(_ a: [String: Value], _ key: String) throws -> String {
        guard let s = a[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            throw ToolError("missing required argument \(key)")
        }
        return s
    }

    /// An integer argument clamped to `range`. Whole numbers outside `Int` (e.g. `1e300`) clamp too; a fraction,
    /// NaN, infinity or non-number is an error (`Int(Double)` would trap on the out-of-range ones).
    static func int(_ a: [String: Value], _ key: String, default d: Int, range: ClosedRange<Int>) throws -> Int {
        let raw: Int
        switch a[key] {
        case nil, .null?: raw = d
        case let .int(i)?: raw = i
        case let .double(x)?:
            guard x.isFinite, x.rounded() == x else { throw ToolError("\(key) must be an integer, got \(x)") }
            raw = Int(exactly: x) ?? (x < 0 ? .min : .max)
        case let .string(s)?:
            guard let i = Int(s.trimmingCharacters(in: .whitespaces)) else { throw ToolError("\(key) must be an integer, got \(s)") }
            raw = i
        default: throw ToolError("\(key) must be an integer")
        }
        return min(max(raw, range.lowerBound), range.upperBound)
    }

    static func date(_ a: [String: Value], _ key: String) throws -> Date? {
        guard let s = a[key]?.stringValue, !s.isEmpty else { return nil }
        guard s.count == 10, let d = LocalDate.date(s) else { throw ToolError("\(key) must be YYYY-MM-DD, got \(s)") }
        return d
    }

    static func authors(_ all: [String]) -> [String] {
        all.count <= 5 ? all : Array(all.prefix(5)) + ["et al. (\(all.count) authors)"]
    }

    static func cut(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n - 1)) + "…"
    }

    static func short(_ error: Error) -> String {
        cut((error as? LocalizedError)?.errorDescription ?? String(describing: error), 300)
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
