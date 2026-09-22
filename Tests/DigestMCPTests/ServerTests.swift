import Foundation
import MCP
import Synchronization
import Testing
@testable import DigestCore
@testable import DigestMCP

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Serves `body` (or fails) for every request; records URLs.
final class StubTransport: HTTPTransport {
    private let state = Mutex<[URL]>([])
    let status: Int, body: Data, fail: Bool
    init(status: Int = 200, body: Data = Data(), fail: Bool = false) { (self.status, self.body, self.fail) = (status, body, fail) }
    var urls: [URL] { state.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        state.withLock { $0.append(url) }
        if fail { throw URLError(.notConnectedToInternet) }
        guard let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { throw URLError(.badURL) }
        return (body, http)
    }
}

/// Answers by URL (`route` returns status and body, or nil for a connection failure); records URLs.
final class RouteTransport: HTTPTransport {
    private let state = Mutex<[URL]>([])
    let route: @Sendable (URL) -> (Int, Data)?
    init(_ route: @escaping @Sendable (URL) -> (Int, Data)?) { self.route = route }
    var urls: [URL] { state.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        state.withLock { $0.append(url) }
        guard let (status, body) = route(url) else { throw URLError(.notConnectedToInternet) }
        guard let http = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { throw URLError(.badURL) }
        return (body, http)
    }
}

struct StubFullText: FullTextFetcher {
    func fetch(_ paper: RawPaper) async throws -> FullTextResult {
        FullTextResult(text: "Fetched text of \(paper.id). " + String(repeating: "y", count: 900), figures: [], source: .html)
    }
}

/// A seeded home: one stored paper with full text, a digest for "today", one chat message.
func seededHome(today: String) async throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("brainmaxxing-mcp-\(UUID().uuidString)")
    let store = try Store(url: AppPaths(home: home).database)
    let paper = RawPaper(id: "2610.00001", version: 2, title: "Attention Sinks Revisited", abstract: String(repeating: "abstract ", count: 200),
                         authors: (1...8).map { "Author \($0)" }, categories: ["cs.LG"], primaryCategory: "cs.LG",
                         absURL: URL(string: "https://arxiv.org/abs/2610.00001v2"), pdfURL: nil,
                         published: Date(timeIntervalSince1970: 1_800_000_000), updated: Date(timeIntervalSince1970: 1_800_000_000), source: .arxiv)
    let journal = RawPaper(id: "W4381712656", version: 1, title: "Fast quantum algorithm for differential equations",
                           abstract: "Partial differential equations are ubiquitous.", authors: ["Author A"], categories: ["Physics"],
                           primaryCategory: "Physics", absURL: URL(string: "https://doi.org/10.1103/2mlq-dbfg"), pdfURL: nil,
                           published: Date(timeIntervalSince1970: 1_800_000_000), updated: Date(timeIntervalSince1970: 1_800_000_000),
                           source: .openalex, venue: "Physical Review Research", doi: "10.1103/2mlq-dbfg")
    try await store.upsertPapers([paper, journal], runID: nil)
    try await store.saveFullText(paperID: paper.id, text: String(repeating: "0123456789", count: 3_000), source: .html)
    try await store.startRun(id: "r1", startedAt: Date(), force: true, since: nil, stages: .all)
    try await store.saveTriageScores(runID: "r1", [TriageScore(paperID: paper.id, score: 9, oneLine: "sinks matter", tags: ["attention"], promptVersion: 1)])
    try await store.saveDigest(Digest(
        title: "Sinks and quantization", summary: "quantization of attention sinks", clusters: [DigestCluster(id: "c1", name: "Sinks", paperIDs: [paper.id], narrative: "sink narrative")],
        papers: [], hfSection: [], trendNotes: "", date: today, runID: "r1", generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        partial: false, empty: false, counts: RunCounts(), promptVersion: 1, model: "claude-opus-5-5", costUSD: 1))
    let conv = try await store.conversation(forDigestDate: today)
    try await store.appendMessage(ChatMessage(conversationID: conv, role: .user, content: "how does quantization treat sinks?", createdAt: Date()))
    return home
}

@Suite struct DigestMCPServerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var today: String { LocalDate.string(now) }

    /// Server and SDK client connected in-process over the SDK's in-memory transport.
    func connect(arxiv: StubTransport, openalex: HTTPTransport = StubTransport(fail: true)) async throws -> (Client, URL) {
        let home = try await seededHome(today: today)
        let paths = AppPaths(home: home)
        let limiter = RateLimiter(minInterval: 3, sleep: { _ in })
        let context = ServerContext(paths: paths, store: LazyStore(url: paths.database),
                                    arxiv: ArxivLookup(transport: arxiv, rateLimiter: limiter), fullText: StubFullText(),
                                    openalex: OpenAlexClient(transport: openalex, rateLimiter: RateLimiter(minInterval: 0.2, sleep: { _ in }),
                                                             sleep: { _ in }),
                                    now: { now })
        let server = await PaperServer.make(context: context)
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverSide)
        let client = Client(name: "test", version: "0")
        try await client.connect(transport: clientSide)
        return (client, home)
    }

    func call(_ client: Client, _ name: String, _ args: [String: Value]) async throws -> (text: String, isError: Bool) {
        let (content, isError): (content: [Tool.Content], isError: Bool?) = try await client.callTool(name: name, arguments: args)
        guard case let .text(text, _, _)? = content.first else { throw ToolError("no text content") }
        return (text, isError ?? false)
    }

    func json(_ text: String) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    @Test func listsSevenToolsWithSchemas() async throws {
        let (client, _) = try await connect(arxiv: StubTransport())
        let tools = try await client.listTools().tools
        #expect(tools.map(\.name) == ["search_arxiv", "get_paper", "get_fulltext", "search_openalex", "get_citations", "search_digests", "get_digest"])
        for t in tools {
            #expect(t.inputSchema.objectValue?["type"] == "object")
            #expect((t.description ?? "").count > 150)
        }
    }

    @Test func searchArxivCapsAndTruncates() async throws {
        let arxiv = StubTransport(body: try Data(contentsOf: fixtures.appendingPathComponent("arxiv/query-page0.xml")))
        let (client, _) = try await connect(arxiv: arxiv)
        let r = try await call(client, "search_arxiv", ["query": "attention sinks", "categories": ["cs.LG"], "since": "2026-10-01", "max": 5])
        #expect(!r.isError)
        guard case let .array(hits) = try json(r.text) else { Issue.record("not an array"); return }
        #expect(hits.count == 5)
        for h in hits {
            #expect((h["abstract"]?.stringValue?.count ?? 0) <= 600)
            guard case let .array(authors)? = h["authors"] else { Issue.record("no authors"); continue }
            #expect(authors.count <= 6)
            #expect(Set(h.objectKeys) == ["id", "title", "authors", "published", "abstract"])
        }
        let query = arxiv.urls.first?.query(percentEncoded: false) ?? ""
        #expect(query.contains("all:attention AND all:sinks AND (cat:cs.LG) AND submittedDate:[") && query.contains("max_results=5"))
    }

    @Test func getPaperLocalAndRemote() async throws {
        let arxiv = StubTransport(body: try Data(contentsOf: fixtures.appendingPathComponent("arxiv/query-page0.xml")))
        let (client, _) = try await connect(arxiv: arxiv)
        let local = try json(try await call(client, "get_paper", ["id": "arXiv:2610.00001v2"]).text)
        #expect(local["title"]?.stringValue == "Attention Sinks Revisited" && local["has_fulltext"] == .bool(true))
        #expect(local["triage"] == .object(["score": .number(9), "one_line": .string("sinks matter"), "tags": .array([.string("attention")])]))
        #expect(arxiv.urls.isEmpty)
        let remote = try json(try await call(client, "get_paper", ["id": "2610.28631"]).text)
        #expect(remote["id"]?.stringValue == "2610.28631" && remote["has_fulltext"] == .bool(false))
        #expect(remote["triage"] == nil)
        #expect(arxiv.urls.first?.query?.contains("id_list=2610.28631") == true)
        let bad = try await call(client, "get_paper", ["id": "hello"])
        #expect(bad.isError && bad.text.contains("not an arXiv or OpenAlex id"))
    }

    @Test func getFulltextSlicesAndFetchesMissing() async throws {
        let arxiv = StubTransport(body: try Data(contentsOf: fixtures.appendingPathComponent("arxiv/query-page0.xml")))
        let (client, home) = try await connect(arxiv: arxiv)
        let first = try json(try await call(client, "get_fulltext", ["id": "2610.00001", "max_chars": 1000, "offset": 25]).text)
        #expect(first["total_chars"] == .number(30_000) && first["offset"] == .number(25) && first["next_offset"] == .number(1025))
        #expect(first["text"]?.stringValue?.count == 1000 && first["text"]?.stringValue?.hasPrefix("56789") == true)
        let last = try json(try await call(client, "get_fulltext", ["id": "2610.00001", "offset": 29_990]).text)
        #expect(last["text"]?.stringValue == "0123456789" && last["next_offset"] == nil)

        let fetched = try json(try await call(client, "get_fulltext", ["id": "2610.28631"]).text)
        #expect(fetched["text"]?.stringValue?.hasPrefix("Fetched text of 2610.28631.") == true)
        let store = try Store(url: AppPaths(home: home).database)
        #expect(try await store.fullText(paperID: "2610.28631")?.hasPrefix("Fetched") == true)
    }

    @Test func digestsAndSearch() async throws {
        let (client, _) = try await connect(arxiv: StubTransport())
        let digest = try json(try await call(client, "get_digest", ["date": "today"]).text)
        #expect(digest["title"]?.stringValue == "Sinks and quantization" && digest["date"]?.stringValue == today)
        let missing = try await call(client, "get_digest", ["date": "2020-01-01"])
        #expect(missing.isError && missing.text.contains("latest is \(today)"))

        guard case let .array(hits) = try json(try await call(client, "search_digests", ["query": "quantization"]).text) else {
            Issue.record("not an array"); return
        }
        #expect(hits.compactMap { $0["kind"]?.stringValue } == ["digest", "chat"])
        #expect(hits.allSatisfy { $0["date"]?.stringValue == today })
    }

    @Test func digestEditions() async throws {
        let (client, home) = try await connect(arxiv: StubTransport())
        let first = try json(try await call(client, "get_digest", ["date": .string(today)]).text)
        #expect(first["edition"] == .number(1) && first["editions_available"] == .array([.number(1)]))

        // A forced second run the same day appends edition 2.
        let store = try Store(url: AppPaths(home: home).database)
        try await store.startRun(id: "r2", startedAt: Date(), force: true, since: nil, stages: .all)
        try await store.saveDigest(Digest(
            title: "Second look at sinks", summary: "edition two", clusters: [], papers: [], hfSection: [], trendNotes: "",
            date: today, runID: "r2", generatedAt: now, partial: false, empty: false, counts: RunCounts(),
            promptVersion: 1, model: "claude-opus-5-5", costUSD: 1))

        let latest = try json(try await call(client, "get_digest", ["date": "today"]).text)
        #expect(latest["title"]?.stringValue == "Second look at sinks" && latest["edition"] == .number(2))
        #expect(latest["editions_available"] == .array([.number(1), .number(2)]))
        let old = try json(try await call(client, "get_digest", ["date": "today", "edition": 1]).text)
        #expect(old["title"]?.stringValue == "Sinks and quantization" && old["edition"] == .number(1))
        #expect(old["editions_available"] == .array([.number(1), .number(2)]))
        let missing = try await call(client, "get_digest", ["date": "today", "edition": 3])
        #expect(missing.isError && missing.text.contains("editions available: 1, 2"))
        #expect(try await call(client, "get_digest", ["date": "today", "edition": 0]).isError)

        guard case let .array(hits) = try json(try await call(client, "search_digests", ["query": "sinks"]).text) else {
            Issue.record("not an array"); return
        }
        let digestHits = hits.filter { $0["kind"]?.stringValue == "digest" }
        let editions = digestHits.compactMap { $0["edition"] }
        #expect(editions.count == 2 && editions.contains(.number(1)) && editions.contains(.number(2)))
        #expect(hits.filter { $0["kind"]?.stringValue == "chat" }.allSatisfy { $0["edition"] == nil })

        // The resource stays on the latest edition.
        let resource = try await client.readResource(uri: "digest://\(today)")
        #expect(resource.first?.text?.contains("\"title\":\"Second look at sinks\"") == true)
    }

    /// `max: 1e300` must not trap in `Int(Double)` and kill the server.
    @Test func outOfRangeNumbersClampOrAreToolErrors() async throws {
        let (client, _) = try await connect(arxiv: StubTransport())
        #expect(try await call(client, "search_digests", ["query": "sinks", "max": .double(1e300)]).isError == false)
        #expect(try await call(client, "search_digests", ["query": "sinks", "max": .double(-1e300)]).isError == false)
        let fraction = try await call(client, "search_digests", ["query": "sinks", "max": .double(2.5)])
        #expect(fraction.isError && fraction.text.contains("max must be an integer"))
        #expect(try await call(client, "search_digests", ["query": "sinks", "max": "lots"]).isError)
        let far = try json(try await call(client, "get_fulltext", ["id": "2610.00001", "offset": .double(1e300)]).text)
        #expect(far["text"]?.stringValue == "" && far["next_offset"] == nil)
        #expect(try await call(client, "get_digest", ["date": "today", "edition": .double(1e300)]).isError)
        // NaN and infinity cannot travel as JSON; the parser still rejects them.
        for x in [Double.nan, .infinity, -.infinity] {
            #expect(throws: ToolError.self) { try PaperTools.int(["max": .double(x)], "max", default: 10, range: 1...25) }
        }
        #expect(try PaperTools.int(["max": .double(7)], "max", default: 10, range: 1...25) == 7)
        #expect(try PaperTools.int([:], "max", default: 10, range: 1...25) == 10)
    }

    @Test func networkFailureIsAToolErrorAndServerKeepsAnswering() async throws {
        let (client, _) = try await connect(arxiv: StubTransport(fail: true))
        let r = try await call(client, "search_arxiv", ["query": "sinks"])
        #expect(r.isError && r.text.contains("arXiv is unreachable"))
        let r503 = try await call(client, "get_paper", ["id": "2610.99999"])
        #expect(r503.isError)
        let missingArg = try await call(client, "search_arxiv", [:])
        #expect(missingArg.isError && missingArg.text.contains("query"))
        #expect(try await client.listTools().tools.count == 7)
    }

    // MARK: OpenAlex

    static func fixture(_ name: String) -> Data { (try? Data(contentsOf: fixtures.appendingPathComponent("openalex/\(name)"))) ?? Data() }

    /// search -> search.json; arXiv DOI or W id of 2306.11802 -> its work; cites / cited_by filters -> cites.json; else 404.
    static func openalexRoutes() -> RouteTransport { RouteTransport { url in
        let path = url.path(percentEncoded: false)
        let query = url.query(percentEncoded: false) ?? ""
        if path == "/works/doi:10.48550/arXiv.2306.11802" || path == "/works/W4381712656" { return (200, fixture("work-arxiv-2306.11802.json")) }
        if path == "/works", query.contains("search=") { return (200, fixture("search.json")) }
        if path == "/works", query.contains("filter=cites:W4381712656") || query.contains("filter=cited_by:W4381712656") {
            return (200, fixture("cites.json"))
        }
        return (404, Data("{}".utf8))
    } }

    @Test func searchOpenAlexCompactsAndCaps() async throws {
        let transport = Self.openalexRoutes()
        let (client, _) = try await connect(arxiv: StubTransport(), openalex: transport)
        let r = try await call(client, "search_openalex", ["query": "attention sinks", "max": 2])
        #expect(!r.isError)
        guard case let .array(hits) = try json(r.text) else { Issue.record("not an array"); return }
        #expect(hits.count == 2)
        let first = try #require(hits.first)
        #expect(first["id"]?.stringValue == "W4387294617" && first["arxiv_id"]?.stringValue == "2309.17453")
        #expect(first["year"] == .number(2023) && first["cited_by_count"] == .number(55))
        #expect(first["doi"]?.stringValue == "10.48550/arxiv.2309.17453" && first["venue"]?.stringValue == "arXiv (Cornell University)")
        for h in hits {
            #expect((1...500).contains(h["abstract"]?.stringValue?.count ?? 0))
            #expect(Set(h.objectKeys).isSubset(of: ["id", "arxiv_id", "title", "venue", "year", "cited_by_count", "doi", "pdf_url", "abstract"]))
        }
        let url = try #require(transport.urls.last)
        let query = url.query(percentEncoded: false) ?? ""
        #expect(query.contains("search=attention sinks") && query.contains("per-page=2"))
        #expect(!query.contains("mailto") && !query.contains("api_key"))

        // `since` over-fetches one page and filters by publication date. The ACL paper has no OpenAlex source, so its
        // `venue` comes from `raw_source_name`; it also has an arXiv location and an open-access PDF.
        guard case let .array(recent) = try json(try await call(client, "search_openalex", ["query": "sinks", "since": "2026-01-01"]).text) else {
            Issue.record("not an array"); return
        }
        #expect(recent.compactMap { $0["id"]?.stringValue } == ["W7161688140", "W4415885347"])
        #expect(recent.last?["venue"]?.stringValue == "Findings of the Association for Computational Linguistics: ACL 2026" && recent.last?["arxiv_id"]?.stringValue == "2510.15731")
        #expect(recent.last?["pdf_url"]?.stringValue == "https://aclanthology.org/2026.findings-acl.2145.pdf")
        #expect(transport.urls.last?.query(percentEncoded: false)?.contains("per-page=\(ToolCatalog.openalexSincePool)") == true)
    }

    @Test(arguments: [
        ("arXiv:2306.11802v2", "cited_by", "/works/doi:10.48550/arXiv.2306.11802", "filter=cites:W4381712656"),
        ("https://openalex.org/W4381712656", "references", "/works/W4381712656", "filter=cited_by:W4381712656"),
        ("W4381712656", "cited_by", "/works/W4381712656", "filter=cites:W4381712656"),
    ])
    func getCitationsResolvesIDs(id: String, direction: String, lookupPath: String, listFilter: String) async throws {
        let transport = Self.openalexRoutes()
        let (client, _) = try await connect(arxiv: StubTransport(), openalex: transport)
        let r = try await call(client, "get_citations", ["id": .string(id), "direction": .string(direction), "max": 2])
        #expect(!r.isError, "\(r.text)")
        let result = try json(r.text)
        #expect(result["paper"]?["id"]?.stringValue == "W4381712656" && result["paper"]?["venue"]?.stringValue == "Physical Review Research")
        #expect(result["direction"]?.stringValue == direction)
        guard case let .array(works)? = result["works"] else { Issue.record("no works"); return }
        #expect(works.count == 2 && works.first?["id"]?.stringValue == "W4394710090")
        #expect(works.allSatisfy { $0["abstract"] == nil })
        #expect(transport.urls.map { $0.path(percentEncoded: false) } == [lookupPath, "/works"])
        let listQuery = transport.urls.last?.query(percentEncoded: false) ?? ""
        #expect(listQuery.contains(listFilter) && listQuery.contains("per-page=2"))
    }

    @Test func getCitationsNotFoundAndBadInput() async throws {
        let (client, _) = try await connect(arxiv: StubTransport(), openalex: Self.openalexRoutes())
        let unknown = try await call(client, "get_citations", ["id": "2610.99999", "direction": "cited_by"])
        #expect(unknown.isError && unknown.text.contains("not found in OpenAlex"))
        let unknownW = try await call(client, "get_citations", ["id": "W1", "direction": "references"])
        #expect(unknownW.isError && unknownW.text.contains("not found in OpenAlex"))
        let bad = try await call(client, "get_citations", ["id": "hello", "direction": "cited_by"])
        #expect(bad.isError && bad.text.contains("not an arXiv or OpenAlex id"))
        let dir = try await call(client, "get_citations", ["id": "W4381712656", "direction": "sideways"])
        #expect(dir.isError && dir.text.contains("direction"))
    }

    @Test(arguments: [(nil, "OpenAlex is unreachable"), (503, "HTTP 503")] as [(Int?, String)])
    func openAlexFailuresAreToolErrors(status: Int?, message: String) async throws {
        let transport = RouteTransport { _ in status.map { ($0, Data()) } }
        let (client, _) = try await connect(arxiv: StubTransport(), openalex: transport)
        let search = try await call(client, "search_openalex", ["query": "sinks"])
        #expect(search.isError && search.text.contains(message))
        let cites = try await call(client, "get_citations", ["id": "2306.11802", "direction": "references"])
        #expect(cites.isError && cites.text.contains(message))
        #expect(try await client.listTools().tools.count == 7)
    }

    /// Stored OpenAlex papers (`W...`) are readable through get_paper, get_fulltext and paper://; no arXiv call.
    @Test func openAlexIDsResolveFromTheStore() async throws {
        let arxiv = StubTransport(fail: true)
        let (client, _) = try await connect(arxiv: arxiv)
        for id in ["W4381712656", "https://openalex.org/W4381712656", "w4381712656"] {
            let paper = try await call(client, "get_paper", ["id": .string(id)])
            #expect(!paper.isError, "\(paper.text)")
            let p = try json(paper.text)
            #expect(p["id"]?.stringValue == "W4381712656" && p["venue"]?.stringValue == "Physical Review Research")
            #expect(p["doi"]?.stringValue == "10.1103/2mlq-dbfg" && p["has_fulltext"] == .bool(false))
        }
        let arxivPaper = try json(try await call(client, "get_paper", ["id": "2610.00001"]).text)
        #expect(arxivPaper["venue"] == nil && arxivPaper["doi"] == nil)

        let text = try await call(client, "get_fulltext", ["id": "W4381712656"])
        #expect(!text.isError)
        let t = try json(text.text)
        #expect(t["fulltext_available"] == .bool(false) && t["note"]?.stringValue?.contains("only the abstract") == true)
        #expect(t["abstract"]?.stringValue == "Partial differential equations are ubiquitous.")

        let unknown = try await call(client, "get_paper", ["id": "W1"])
        #expect(unknown.isError && unknown.text.contains("not in the local library"))
        #expect(try await call(client, "get_fulltext", ["id": "W1"]).isError)

        let md = try #require(try await client.readResource(uri: "paper://W4381712656").first?.text)
        #expect(md.hasPrefix("# Fast quantum algorithm") && md.contains("**W4381712656**") && md.contains("Physical Review Research / DOI 10.1103/2mlq-dbfg"))
        #expect(arxiv.urls.isEmpty)
    }

    @Test func resources() async throws {
        let (client, _) = try await connect(arxiv: StubTransport())
        #expect(try await client.listResources().resources.map(\.uri) == ["digest://today"])
        #expect(try await client.listResourceTemplates().templates.map(\.uriTemplate) == ["digest://{date}", "paper://{id}"])
        let paper = try await client.readResource(uri: "paper://2610.00001")
        #expect(paper.first?.mimeType == "text/markdown" && paper.first?.text?.hasPrefix("# Attention Sinks Revisited") == true)
        let digest = try await client.readResource(uri: "digest://\(today)")
        #expect(digest.first?.text?.contains("\"title\":\"Sinks and quantization\"") == true)
        await #expect(throws: (any Error).self) { try await client.readResource(uri: "digest://2020-01-01") }
    }
}

/// The real binary, spawned by `MCPToolProvider` over stdio (built by `swift build` / `swift test`).
@Suite struct MCPToolProviderTests {
    let binary = repoRoot.appendingPathComponent(".build/debug/DigestMCP")

    @Test func serverGetsOnlyAllowlistedEnvironment() async {
        let provider = MCPToolProvider(executable: binary, environment: [
            "HOME": "/h", "BRAINMAXXING_HOME": "/b", "PATH": "/bin", "TMPDIR": "/t", "LANG": "ru_RU.UTF-8",
            "ANTHROPIC_API_KEY": "sk-secret", "AWS_SECRET_ACCESS_KEY": "x", "DIGEST_MCP_PATH": "/x"])
        #expect(provider.environment == ["HOME": "/h", "BRAINMAXXING_HOME": "/b", "PATH": "/bin", "TMPDIR": "/t", "LANG": "ru_RU.UTF-8"])
    }

    @Test func spawnsListsCallsAndRestartsOnce() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: binary.path), "build DigestMCP first")
        let home = try await seededHome(today: LocalDate.string(Date()))
        let provider = MCPToolProvider(executable: binary, environment: ["BRAINMAXXING_HOME": home.path])
        #expect(try await provider.listTools().count == 7)
        let r = try await provider.call("get_digest", input: .object(["date": .string("today")]))
        #expect(!r.isError && r.text.contains("Sinks and quantization"))

        // Kill the server: the next call restarts it once per message.
        let pid = try #require(await provider.serverPID)
        kill(pid, SIGKILL)
        try await Task.sleep(for: .milliseconds(200))
        await provider.beginMessage()
        #expect(try await provider.call("get_digest", input: .object(["date": .string("today")])).text.contains("Sinks"))
        kill(try #require(await provider.serverPID), SIGKILL)
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: ChatError.self) { try await provider.call("get_digest", input: .object(["date": .string("today")])) }
        await provider.shutdown()
    }
}

extension JSONValue {
    var objectKeys: [String] { if case let .object(o) = self { Array(o.keys) } else { [] } }
}
