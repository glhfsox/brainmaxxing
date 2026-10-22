import Foundation
import GRDB
import Synchronization
import Testing
@testable import DigestCore

/// Sets a feedback row's `created_at` directly (the store stamps `Date()`, too coarse to order rows in a test).
func stampFeedback(_ store: Store, _ paperID: String, _ iso: String) async throws {
    let date = try TestSupport.date(iso)
    try await store.pool.write { db in
        try db.execute(sql: "UPDATE feedback SET created_at = ? WHERE paper_id = ?", arguments: [date, paperID])
    }
}

@Suite struct SecondarySourcesStoreTests {
    @Test func venueAndDoiRoundTripAndArxivJSONIsUnchanged() async throws {
        let store = try tempStore()
        var journal = try samplePaper("W4381712656", title: "Fast quantum algorithm")
        journal.source = .openalex
        journal.venue = "Physical Review Research"
        journal.doi = "10.1103/2mlq-dbfg"
        try await store.upsertPapers([journal, try samplePaper("2610.00011")], runID: nil)
        #expect(try await store.paper(id: "W4381712656") == journal)
        let arxiv = try #require(try await store.paper(id: "2610.00011"))
        #expect(arxiv.venue == nil && arxiv.doi == nil)
        // nil fields are omitted: arXiv papers (and goldens' papers.json) keep their bytes.
        let json = String(decoding: try Golden.encoder.encode(arxiv), as: UTF8.self)
        #expect(!json.contains("venue") && !json.contains("doi"))
        var counts = RunCounts()
        counts.fetched = 3
        #expect(!String(decoding: try Digest.encoder.encode(counts), as: UTF8.self).contains("openalex"))
        counts.openalexMerged = 2
        let decoded = try Digest.decoder.decode(RunCounts.self, from: try Digest.encoder.encode(counts))
        #expect(decoded == counts)
    }

    @Test func insertIfAbsentNeverOverwrites() async throws {
        let store = try tempStore()
        try await store.upsertPapers([try samplePaper("2610.00011", title: "From arXiv")], runID: "r")
        var hf = try samplePaper("2610.00011", title: "From HF")
        hf.source = .hfPapers
        var fresh = try samplePaper("2610.00022", title: "Only on HF")
        fresh.source = .hfPapers
        #expect(try await store.insertPapersIfAbsent([hf, fresh]) == 1)
        #expect(try await store.paper(id: "2610.00011")?.title == "From arXiv")
        #expect(try await store.paper(id: "2610.00022")?.source == .hfPapers)
        #expect(try await store.papers(firstSeenIn: "r").map(\.id) == ["2610.00011"])
    }

    @Test func hfSectionIDsSkipTheRunsOwnEdition() async throws {
        let store = try tempStore()
        func digest(_ runID: String, _ hf: [String]) -> Digest {
            Digest(title: "T", summary: "s", clusters: [], papers: [], hfSection: hf.map { HFEntry(id: $0, oneLine: "x", title: "t", upvotes: 1) },
                   trendNotes: "", date: "2026-10-21", runID: runID, generatedAt: Date(timeIntervalSince1970: 1_800_000_000), partial: false,
                   empty: false, counts: RunCounts(), promptVersion: 1, model: "m", costUSD: 0)
        }
        for id in ["r1", "r2"] { try await store.startRun(id: id, startedAt: Date(), force: true, since: nil, stages: .all) }
        try await store.saveDigest(digest("r1", ["2610.1", "2610.2"]))
        try await store.saveDigest(digest("r2", ["2610.3"]))
        #expect(try await store.hfSectionIDs(excludingRunID: "r2") == ["2610.1", "2610.2"])
        #expect(try await store.hfSectionIDs(excludingRunID: nil) == ["2610.1", "2610.2", "2610.3"])
    }

    @Test func feedbackExamplesOrderAndFormat() async throws {
        let store = try tempStore()
        try await store.startRun(id: "r1", startedAt: try TestSupport.date("2026-10-20T03:00:00Z"), force: true, since: nil, stages: .all)
        try await store.startRun(id: "r2", startedAt: try TestSupport.date("2026-10-21T03:00:00Z"), force: true, since: nil, stages: .all)
        try await store.upsertPapers([try samplePaper("2610.00001", title: "Sparse\n  attention"), try samplePaper("2610.00002", title: "B"),
                                      try samplePaper("2610.00003", title: "C")], runID: nil)
        try await store.saveTriageScores(runID: "r1", [TriageScore(paperID: "2610.00001", score: 5, oneLine: "old line", tags: [], promptVersion: 1),
                                                       TriageScore(paperID: "2610.00002", score: 5, oneLine: "b  line", tags: [], promptVersion: 1)])
        try await store.saveTriageScores(runID: "r2", [TriageScore(paperID: "2610.00001", score: 5, oneLine: "new\tline", tags: [], promptVersion: 1)])
        try await store.setFeedback(paperID: "2610.00001", verdict: .up, digestDate: nil)
        try await store.setFeedback(paperID: "2610.00002", verdict: .down, digestDate: nil)
        try await store.setFeedback(paperID: "2610.00003", verdict: .up, digestDate: nil)
        try await stampFeedback(store, "2610.00001", "2026-10-20T10:00:00Z")
        try await stampFeedback(store, "2610.00002", "2026-10-21T10:00:00Z")
        try await stampFeedback(store, "2610.00003", "2026-10-21T10:00:00Z")

        let examples = try await store.feedbackExamples()
        // Newest first, ties by paper id; most recent one_line; no one_line -> title only.
        #expect(examples.map(\.line) == ["👎 B - b line", "👍 C", "👍 Sparse attention - new line"])
        #expect(try await store.feedbackExamples(limit: 1).map(\.paperID) == ["2610.00002"])

        // Same verdict again keeps created_at; a changed verdict moves it to now.
        try await store.setFeedback(paperID: "2610.00001", verdict: .up, digestDate: "2026-10-22")
        #expect(try await store.feedbackExamples().last?.paperID == "2610.00001")
        try await store.setFeedback(paperID: "2610.00001", verdict: .down, digestDate: "2026-10-22")
        #expect(try await store.feedbackExamples().first?.line == "👎 Sparse attention - new line")
    }
}

/// A limiter whose sleeps are recorded, not waited.
func instantLimiter(_ clock: FakeClock, interval: TimeInterval = 0.2) -> RateLimiter {
    RateLimiter(minInterval: interval, clock: { clock.now }, sleep: { clock.sleep($0) })
}

@Suite struct OpenAlexClientTests {
    let page1: Data
    let page2: Data

    init() throws {
        page1 = try TestSupport.fixture("openalex/works-page1.json")
        page2 = try TestSupport.fixture("openalex/works-page2.json")
    }

    func client(_ transport: MockTransport, clock: FakeClock = FakeClock(), maxPerRun: Int = 1000, perPage: Int = 200) -> OpenAlexClient {
        OpenAlexClient(transport: transport, rateLimiter: instantLimiter(clock), subfields: Config.defaultOpenAlexSubfields,
                       maxPerRun: maxPerRun, perPage: perPage, now: { (try? TestSupport.date("2026-10-22T09:00:00Z")) ?? Date() },
                       sleep: { clock.sleep($0) })
    }

    @Test func mapsRowsAndDropsArxivCopiesRetractedAndParatext() async throws {
        let transport = MockTransport([.init(status: 200, body: page1)])
        let result = try await client(transport).fetch(since: try TestSupport.date("2026-10-15T03:00:00Z"), categories: ["cs.LG"])
        // 12 rows: W2982288791 and W4381712656 have arXiv locations, one retracted, one paratext (hand-edited flags).
        #expect(result.merged == 2 && result.dropped == 2 && result.papers.count == 8 && !result.capped && !result.truncated)
        #expect(!result.papers.map(\.id).contains("W4381712656"))
        #expect(transport.requests.count == 1)  // 12 < per-page

        let url = try #require(transport.requests.first?.url)
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let items = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/works")
        // From the UTC day after since's.
        #expect(items["filter"] == "from_publication_date:2026-10-16,to_publication_date:\(LocalDate.string(try TestSupport.date("2026-10-22T09:00:00Z"))),"
            + "primary_topic.subfield.id:1702|1707|2608|2613,type:article,has_abstract:true,primary_location.source.is_core:true")
        #expect(items["select"] == OpenAlexClient.listSelect && items["per-page"] == "200" && items["page"] == "1")
        #expect(Set(items.keys) == ["filter", "select", "per-page", "page"])  // no mailto, no api_key
        #expect(!url.absoluteString.contains("mailto") && !url.absoluteString.contains("api_key"))
        #expect(transport.requests.first?.value(forHTTPHeaderField: "User-Agent") == "brainmaxxing/0.1")

        let tagged = try #require(result.papers.first { $0.id == "W7123328434" })
        #expect(tagged.title.hasPrefix("Leveraging Large Language Model Token Probabilities"))
        #expect(tagged.title.hasSuffix(" with 2 tags") && !tagged.title.contains("<"))
        #expect(tagged.venue == "Applied Artificial Intelligence" && tagged.doi == "10.1080/08839514.2026.2724370")
        #expect(tagged.absURL?.absoluteString == "https://doi.org/10.1080/08839514.2026.2724370")
        #expect(tagged.pdfURL?.absoluteString == "https://www.tandfonline.com/doi/pdf/10.1080/08839514.2026.2724370?needAccess=true")
        #expect(tagged.categories == ["Artificial Intelligence"] && tagged.primaryCategory == "Artificial Intelligence")
        #expect(tagged.source == .openalex && tagged.version == 1)
        #expect(tagged.published == (try TestSupport.date("2026-10-15T00:00:00Z")))
        #expect(tagged.updated == (try TestSupport.date("2026-10-18T09:31:52Z")))
        #expect(!tagged.authors.isEmpty)

        let noDOI = try #require(result.papers.first { $0.id == "W7127614983" })
        #expect(noDOI.doi == nil && noDOI.absURL?.absoluteString == "https://openalex.org/W7127614983")
    }

    @Test func abstractFromInvertedIndex() {
        let index = ["world": [1, 3], "hello": [0], "again,": [2], "x": [5]]
        #expect(OpenAlexClient.abstract(index) == "hello world again, world x")
        #expect(OpenAlexClient.abstract(nil) == "")
        #expect(OpenAlexClient.stripTags("A <i>b</i>\n <sub>c</sub>") == "A b c")
    }

    @Test func pagesUntilShortPageAndCapsAtMaxPerRun() async throws {
        let clock = FakeClock()
        let all = MockTransport([.init(status: 200, body: page1), .init(status: 200, body: page2)])
        let full = try await client(all, clock: clock, perPage: 12).fetch(since: Date(), categories: [])
        #expect(all.requests.count == 2 && all.requests.last?.url?.query?.contains("page=2") == true)
        #expect(full.papers.count == 16 && full.merged == 2 && full.dropped == 2 && !full.capped)
        #expect(clock.sleeps.allSatisfy { $0 >= 0.2 - 1e-9 } && clock.sleeps.count == 1)  // second request waited >= 0.2 s

        let capped = MockTransport([.init(status: 200, body: page1), .init(status: 200, body: page2)])
        let cut = try await client(capped, maxPerRun: 15, perPage: 12).fetch(since: Date(), categories: [])
        #expect(cut.capped && cut.papers.count + cut.merged + cut.dropped == 15)

        let exact = MockTransport([.init(status: 200, body: page1), .init(status: 200, body: page2)])
        let stop = try await client(exact, maxPerRun: 12, perPage: 12).fetch(since: Date(), categories: [])
        #expect(stop.capped && exact.requests.count == 1)  // meta.count says 20: more rows existed
    }

    @Test func retriesOnceAfterShortRetryAfterOtherwiseFails() async throws {
        let clock = FakeClock()
        let retried = MockTransport([.init(status: 429, body: Data(), headers: ["Retry-After": "3"]), .init(status: 200, body: page1)])
        #expect(try await client(retried, clock: clock).fetch(since: Date(), categories: []).papers.count == 8)
        #expect(clock.sleeps.contains(3))

        let twice = MockTransport([.init(status: 503, body: Data(), headers: ["Retry-After": "1"]),
                                   .init(status: 503, body: Data(), headers: ["Retry-After": "1"])])
        await #expect(throws: OpenAlexError.badStatus(503)) { try await client(twice).fetch(since: Date(), categories: []) }
        let long = MockTransport([.init(status: 429, body: Data(), headers: ["Retry-After": "60"])])
        await #expect(throws: OpenAlexError.badStatus(429)) { try await client(long).fetch(since: Date(), categories: []) }
        #expect(long.requests.count == 1)
        let bare = MockTransport([.init(status: 500, body: Data())])
        await #expect(throws: OpenAlexError.badStatus(500)) { try await client(bare).fetch(since: Date(), categories: []) }
    }

    @Test func lookups() async throws {
        let work = try TestSupport.fixture("openalex/work-arxiv-2306.11802.json")
        let transport = MockTransport([.init(status: 200, body: work), .init(status: 404, body: Data()),
                                       .init(status: 200, body: try TestSupport.fixture("openalex/search.json")),
                                       .init(status: 200, body: try TestSupport.fixture("openalex/cites.json")),
                                       .init(status: 200, body: try TestSupport.fixture("openalex/search.json"))])
        let c = client(transport)
        let found = try #require(try await c.work(arxivID: "2306.11802"))
        #expect(found.paper.id == "W4381712656" && found.arxivID == "2306.11802" && found.citedByCount == 4 && found.publicationYear == 2026)
        #expect(found.paper.venue == "Physical Review Research")
        #expect(transport.requests[0].url?.path == "/works/doi:10.48550/arXiv.2306.11802")
        #expect(try await c.work(openalexID: "https://openalex.org/W1") == nil)
        #expect(transport.requests[1].url?.path == "/works/W1")

        let hits = try await c.search(query: "attention sinks", limit: 2)
        #expect(hits.count == 2 && hits[0].paper.title == "Efficient Streaming Language Models with Attention Sinks")
        // W4415885347 (ACL Findings): `primary_location.source` is null -> venue from `raw_source_name`.
        let all = try await client(MockTransport([.init(status: 200, body: try TestSupport.fixture("openalex/search.json"))]))
            .search(query: "attention sinks", limit: 3)
        #expect(all.first { $0.paper.id == "W4415885347" }?.paper.venue == "Findings of the Association for Computational Linguistics: ACL 2026")
        #expect(transport.requests[2].url?.query?.contains("search=attention%20sinks") == true)
        let citing = try await c.citedBy(of: found, limit: 3)
        #expect(citing.count == 3)
        #expect(transport.requests[3].url?.query?.contains("filter=cites:W4381712656") == true)
        _ = try await c.references(of: found, limit: 5)
        #expect(transport.requests[4].url?.query?.contains("filter=cited_by:W4381712656") == true)
    }
}

func hfFixture(_ date: String) throws -> Data { try TestSupport.fixture("hf/daily_papers-\(date).json") }

func hfPaper(_ id: String, _ upvotes: Int, summary: String = "Does a thing. Then more.") -> HFDailyPaper {
    HFDailyPaper(arxivID: id, title: "T \(id)", summary: summary, upvotes: upvotes, authors: ["A"], publishedAt: nil, abstract: "Abstract \(id).")
}

@Suite struct HFPapersClientTests {
    @Test func parsesListingWithSummaryFallback() throws {
        let papers = try HFPapersClient.parse(try hfFixture("2026-10-22"))
        #expect(papers.count == 8)
        let first = try #require(papers.first)
        #expect(first.arxivID == "2610.26828" && first.upvotes == 51 && !first.authors.isEmpty)
        #expect(first.title.hasPrefix("Agent World Model in the Wild"))
        #expect(first.publishedAt != nil && first.abstract.count > first.summary.count)  // ai_summary used
        // No ai_summary: the paper's summary, cut at 600 characters.
        let plain = try #require(papers.first { $0.arxivID == "2610.28887" })
        #expect(plain.summary.count == 600 && plain.abstract.hasPrefix(plain.summary))
        #expect(!plain.summary.contains("\n"))
    }

    @Test func selectionUnionsDedupsExcludesAndRanks() {
        let today = [hfPaper("2610.00003", 5), hfPaper("2610.00001", 9), hfPaper("2610.00009", 50)]
        let yesterday = [hfPaper("2610.00003", 7), hfPaper("2610.00002", 9), hfPaper("2610.00004", 1)]
        let kept = HFPapersClient.select([today, yesterday], excluding: ["2610.00009"], topK: 3)
        // Union by id with max upvotes; ties by id; excluded ids gone; top-k.
        #expect(kept.map(\.arxivID) == ["2610.00001", "2610.00002", "2610.00003"])
        #expect(kept[2].upvotes == 7)
    }

    @Test func candidatesStopOnceEnoughAndUseLocalDates() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let day = try TestSupport.date("2026-10-22T01:30:00Z")  // 03:30 in Berlin
        // Today is empty (not published yet) -> yesterday has 6 -> enough for top 5.
        let transport = MockTransport([.init(status: 200, body: Data("[]".utf8)), .init(status: 200, body: try hfFixture("2026-10-21"))])
        let (kept, failure) = await HFPapersClient(transport: transport).candidates(day: day, excluding: ["2610.26203"], topK: 5, calendar: calendar)
        #expect(failure == nil)
        #expect(transport.requests.map { $0.url?.query ?? "" } == ["date=2026-10-22", "date=2026-10-21"])
        #expect(kept.count == 5 && !kept.map(\.arxivID).contains("2610.26203"))
        #expect(kept.map(\.upvotes) == kept.map(\.upvotes).sorted(by: >))

        // Never more than 4 days; a failure is an error for the caller to log.
        let few = MockTransport((0..<4).map { _ in .init(status: 200, body: Data("[]".utf8)) })
        #expect(await HFPapersClient(transport: few).candidates(day: day, excluding: [], topK: 5, calendar: calendar).papers.isEmpty)
        #expect(few.requests.count == 4)
        // A failing day stops paging but keeps the days already fetched; the error goes back to the caller.
        let failing = MockTransport([.init(status: 200, body: try hfFixture("2026-10-21")), .init(status: 502, body: Data())])
        let partial = await HFPapersClient(transport: failing).candidates(day: day, excluding: [], topK: 10, calendar: calendar)
        #expect(partial.papers.count == 6 && partial.failure as? HFPapersError == .badStatus(502) && failing.requests.count == 2)
    }
}

@Suite struct SecondarySourcesDigestWriterTests {
    @Test func bundleCarriesVenueAndHFPapers() throws {
        var journal = try samplePaper("W7123328434", title: "Token probabilities")
        journal.venue = "Applied \"AI\" & More"
        journal.primaryCategory = "Artificial Intelligence"
        journal.published = try TestSupport.date("2026-10-15T00:00:00Z")
        let arxiv = try samplePaper("2610.00019", title: "Arxiv paper")
        let papers = [
            BundlePaper(ranked: RankedPaper(paper: journal, score: 8, oneLine: "why", tags: [], selected: true, rank: 1), fullText: nil, source: nil, figures: []),
            BundlePaper(ranked: RankedPaper(paper: arxiv, score: 7, oneLine: "why", tags: [], selected: true, rank: 2), fullText: nil, source: nil, figures: []),
        ]
        let hf = [hfPaper("2610.26203", 226, summary: "Focused agents."), hfPaper("2610.11111", 3, summary: "S <b>.")]
        let bundle = DigestWriter.bundle(date: "2026-10-22", partial: false, recentClusters: [], papers: papers, hfPapers: hf)
        #expect(bundle.contains("<paper id=\"W7123328434\" rank=\"1\" score=\"8\" tags=\"\" primary_category=\"Artificial Intelligence\" venue=\"Applied &quot;AI&quot; &amp; More\" fulltext=\"none\" chars=\"0\">\n"))
        #expect(bundle.contains("<paper id=\"2610.00019\" rank=\"2\" score=\"7\" tags=\"\" primary_category=\"cs.LG\" fulltext=\"none\" chars=\"0\">\n"))
        #expect(bundle.hasSuffix("""
            </papers>
            <hf_papers>
            <hf_paper id="2610.26203" upvotes="226">
            <title>T 2610.26203</title>
            <summary>Focused agents.</summary>
            </hf_paper>
            <hf_paper id="2610.11111" upvotes="3">
            <title>T 2610.11111</title>
            <summary>S <b>.</summary>
            </hf_paper>
            </hf_papers>
            </run>
            """))
        #expect(DigestWriter.bundle(date: "2026-10-22", partial: false, recentClusters: [], papers: papers)
            .hasSuffix("</papers>\n<hf_papers>\n(none)\n</hf_papers>\n</run>"))

        // Digest entries: venue copied, OpenAlex links are DOI + OA PDF, no arXiv HTML.
        var withPDF = journal
        withPDF.absURL = URL(string: "https://doi.org/10.1/x")
        let out = DigestToolOutput(title: "t", summary: "s", clusters: [], papers: [], hfSection: [], trendNotes: "")
        let (_, normalized) = DigestWriter.normalize(out, papers: [BundlePaper(ranked: papers[0].ranked, fullText: nil, source: nil, figures: [])]
            .map { var b = $0; b.ranked.paper = withPDF; return b })
        #expect(normalized.first?.venue == journal.venue)
        #expect(normalized.first?.links == PaperLinks(abs: URL(string: "https://doi.org/10.1/x"), html: nil, pdf: journal.pdfURL))
    }

    @Test func hfSectionEnforcement() {
        let listed = [hfPaper("2610.00001", 9, summary: "Uses v1.5 weights. Then more."), hfPaper("2610.00002", 5, summary: "No period at all"),
                      hfPaper("2610.00003", 1)]
        let model = [HFEntry(id: "2610.00002", oneLine: " model line ", title: "ignored", upvotes: 1000), HFEntry(id: "9999.00000", oneLine: "unknown"),
                     HFEntry(id: "2610.00002", oneLine: "duplicate"), HFEntry(id: "2610.00003", oneLine: "  ")]
        let result = DigestWriter.normalizeHF(model, listed: listed)
        #expect(result == [
            HFEntry(id: "2610.00002", oneLine: "model line", title: "T 2610.00002", upvotes: 5),
            HFEntry(id: "2610.00003", oneLine: "Does a thing.", title: "T 2610.00003", upvotes: 1),
            HFEntry(id: "2610.00001", oneLine: "Uses v1.5 weights.", title: "T 2610.00001", upvotes: 9),
        ])
        #expect(DigestWriter.firstSentence("No period at all") == "No period at all")
        #expect(DigestWriter.normalizeHF([HFEntry(id: "x", oneLine: "y")], listed: []).isEmpty)
    }
}

/// Re-dates a source's papers to yesterday so fixed fixture dates stay inside the window whenever the test runs.
struct RecentSource: PaperSource {
    let inner: PaperSource
    var id: SourceID { inner.id }
    func fetch(since: Date, categories: [String]) async throws -> SourceFetch {
        var result = try await inner.fetch(since: since, categories: categories)
        result.papers = result.papers.map { var p = $0; p.published = Date().addingTimeInterval(-86_400); return p }
        return result
    }
}

/// Records which papers full text was requested for; returns a stub text.
final class RecordingFullText: FullTextFetcher {
    private let state = Mutex<[String]>([])
    var requested: [String] { state.withLock { $0 } }
    func fetch(_ paper: RawPaper) async throws -> FullTextResult {
        state.withLock { $0.append(paper.id) }
        return FullTextResult(text: "Body.", figures: [], source: .html)
    }
}

/// The canned digest output with `hf_section` replaced.
func cannedDigest(hfSection: [HFEntry]) throws -> @Sendable (Int, LLMRequest) throws -> LLMResponse {
    let entries = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(hfSection.map { ["id": $0.id, "one_line": $0.oneLine] }))
    return { _, request in
        guard case var .object(input) = try cannedDigestInput() else { throw LLMError.invalidResponse("canned digest is not an object") }
        input["hf_section"] = entries
        return LLMResponse(content: [.toolUse(id: "toolu_d", name: "digest", input: .object(input))], stopReason: "tool_use",
                           usage: LLMUsage(inputTokens: 10, outputTokens: 10), model: request.model)
    }
}

/// An HF listing body: the 2026-10-22 fixture plus extra `(id, upvotes)` entries.
func hfListing(extra: [(String, Int)] = []) throws -> Data {
    var list = try #require(try JSONSerialization.jsonObject(with: hfFixture("2026-10-22")) as? [[String: Any]])
    for (id, upvotes) in extra {
        list.append(["paper": ["id": id, "title": "HF copy of \(id)", "summary": "Already ranked.", "upvotes": upvotes] as [String: Any]])
    }
    return try JSONSerialization.data(withJSONObject: list)
}

@Suite struct SecondarySourcesPipelineTests {
    func prompts() throws -> PromptLoader { PromptLoader(directory: try testPromptDirectory()) }

    @Test func secondarySourceFailureIsLoggedButNotPartial() async throws {
        let store = try tempStore()
        let papers = try digestPapers()
        let llm = StagedLLM()
        let hf = HFPapersClient(transport: MockTransport([.init(status: 502, body: Data())]))
        let report = try await Pipeline(store: store, sources: [FailingSource(), FixtureSource(id: .arxiv, papers: papers)], llm: llm, prompts: try prompts(),
                                        config: Config(), fullText: FakeFullText(), hfPapers: hf).run(force: true)
        #expect(!report.partial && report.errors.isEmpty)
        #expect(report.warnings.count == 2)
        let run = try #require(try await store.lastRun())
        #expect(run.status == .succeeded && !run.partial && run.errors.isEmpty)
        let summary = try #require(run.errorSummary)
        #expect(summary.contains("source openalex failed: arXiv API returned HTTP 503"))
        #expect(summary.contains("source hf_papers failed: HF Daily Papers API returned HTTP 502"))
        #expect(try await store.latestDigest()?.hfSection == [])
        #expect(llm.digestCalls.count == 1)
        #expect(try await store.lastSuccessfulRun(reaching: Pipeline.completionStage)?.id == report.runID)
    }

    @Test func openAlexPapersAreTriagedWithArxivAndSkipFullText() async throws {
        let store = try tempStore()
        let openalex = OpenAlexClient(transport: MockTransport([.init(status: 200, body: try TestSupport.fixture("openalex/works-page1.json"))]),
                                      rateLimiter: instantLimiter(FakeClock()))
        let fullText = RecordingFullText()
        let llm = StagedLLM()
        var config = Config()
        config.topN = 20
        let report = try await Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try digestPapers()), RecentSource(inner: openalex)],
                                        llm: llm, prompts: try prompts(), config: config, fullText: fullText).run(force: true)
        #expect(!report.partial, "\(report.errors)")
        #expect(report.counts.openalex == 8 && report.counts.openalexMerged == 2 && report.counts.openalexDropped == 2 && report.counts.openalexCapped == 0)
        #expect(report.counts.fetched == 12 && report.counts.new == 12 && report.counts.triaged == 12)
        let triaged = Set(llm.triage.requests.flatMap { r -> [String] in
            guard case let .text(t, _)? = r.messages.first?.content.first else { return [] }
            return ((try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        })
        #expect(triaged.contains("W7123328434") && triaged.contains("2610.00019"))

        let selected = try await store.rankedPapers(runID: report.runID, selectedOnly: true).map(\.paper)
        let journal = try #require(selected.first { $0.id == "W7161550517" })  // score 7
        #expect(journal.venue == "Data" && journal.doi == "10.3390/data11100280")
        // Full text was requested only for arXiv ids; the journal paper goes to the bundle abstract-only.
        #expect(!fullText.requested.isEmpty && fullText.requested.allSatisfy(ArxivClient.isArxivID))
        let bundle = try #require(llm.digestCalls.first.flatMap { r -> String? in
            if case let .text(t, true)? = r.messages.first?.content.first { return t } else { return nil } })
        #expect(bundle.contains("<paper id=\"W7161550517\""))
        #expect(bundle.contains("primary_category=\"Artificial Intelligence\" venue=\"Data\" fulltext=\"none\" chars=\"0\">"))
        let stored = try #require(try await store.latestDigest())
        #expect(stored.counts.openalex == 8)
    }

    @Test func hfSectionIsFilledEnforcedAndNotRepeated() async throws {
        let store = try tempStore()
        try await store.upsertPapers([try samplePaper("2610.28577", title: "Stored from arXiv")], runID: nil)
        var config = Config()
        config.hfTopK = 3
        // The listing also has a paper that made today's ranked list: it is never an HF entry.
        let listing = try hfListing(extra: [("2610.00019", 999)])
        let llm = StagedLLM(digest: try cannedDigest(hfSection: [HFEntry(id: "2610.28577", oneLine: "Model's line."),
                                                                 HFEntry(id: "2610.99999", oneLine: "Unknown id.")]))
        func pipeline(_ papers: [RawPaper]) throws -> Pipeline {
            Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: papers)], llm: llm, prompts: try prompts(), config: config,
                     fullText: FakeFullText(), hfPapers: HFPapersClient(transport: MockTransport([.init(status: 200, body: listing)])))
        }
        let first = try await pipeline(try digestPapers()).run(force: true)
        #expect(!first.partial && first.counts.hf == 3 && first.warnings.isEmpty)
        let bundle = try #require(llm.digestCalls.first.flatMap { r -> String? in
            if case let .text(t, true)? = r.messages.first?.content.first { return t } else { return nil } })
        #expect(bundle.contains("<hf_papers>\n<hf_paper id=\"2610.26828\" upvotes=\"51\">\n<title>Agent World Model in the Wild"))
        #expect(!bundle.contains("<hf_paper id=\"2610.00019\""))
        let digest = try #require(try await store.latestDigest())
        #expect(digest.hfSection.map(\.id) == ["2610.28577", "2610.26828", "2610.29989"])
        #expect(digest.hfSection[0].oneLine == "Model's line." && digest.hfSection[0].upvotes == 49)
        #expect(digest.hfSection[1].title?.hasPrefix("Agent World Model in the Wild") == true && digest.hfSection[1].oneLine.hasSuffix("."))
        // Stored only if absent: links and chat lookups work, an existing row is untouched, no triage score.
        #expect(try await store.paper(id: "2610.26828")?.source == .hfPapers)
        #expect(try await store.paper(id: "2610.28577")?.title == "Stored from arXiv")
        #expect(try await store.untriagedIDs(among: ["2610.26828"]) == ["2610.26828"])

        // A forced re-run with an unshown paper writes edition 2: the HF papers already shown are skipped.
        var extra = try samplePaper("2610.00058", title: "Paper 2610.00058")
        extra.published = Date().addingTimeInterval(-3600)
        let second = try await pipeline(try digestPapers() + [extra]).run(force: true)
        let edition2 = try #require(try await store.latestDigest())
        #expect(edition2.edition == 2 && second.counts.hf == 3)
        // 2610.00019 was shown in edition 1's main list (`shown_papers`): never an HF entry later, even when not ranked today.
        #expect(edition2.hfSection.map(\.id) == ["2610.17860", "2610.21114", "2610.28589"])
    }

    @Test func feedbackRecordedTodayReachesNextRunsTriagePrompt() async throws {
        let store = try tempStore()
        let papers = try digestPapers()
        let first = MockLLM { _, ids in scoreAll(ids) }
        _ = try await Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: papers)], llm: first, prompts: try prompts(), config: Config())
            .run(force: true, stages: Stage.select.throughHere)
        #expect(first.requests.allSatisfy { $0.system.first?.text.contains("Examples: (none yet)") == true })

        try await store.setFeedback(paperID: "2610.00019", verdict: .up, digestDate: LocalDate.string(Date()))
        try await store.setFeedback(paperID: "2610.00041", verdict: .down, digestDate: LocalDate.string(Date()))
        try await stampFeedback(store, "2610.00041", "2026-01-01T00:00:00Z")
        let fresh = (0..<30).map { i in
            var p = (try? samplePaper(String(format: "2610.%05d", 50_000 + i))) ?? papers[0]
            p.published = Date().addingTimeInterval(-3600)
            return p
        }
        let second = MockLLM { _, ids in scoreAll(ids) }
        _ = try await Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: papers + fresh)], llm: second, prompts: try prompts(),
                               config: Config()).run(force: true, stages: Stage.select.throughHere)
        #expect(second.requests.count == 2)
        let system = try #require(second.requests.first?.system.first)
        #expect(system.cache)
        #expect(system.text.contains("Examples: 👍 Paper 2610.00019 - why 2610.00019\n👎 Paper 2610.00041 - why 2610.00041\nLanguage:"))
        // Frozen for the run: both batches send the same cached system block.
        #expect(second.requests.map(\.system) == [[system], [system]])
    }
}

/// DOI dedup and first_seen_run for HF-first papers.
@Suite struct CrossSourceDedupTests {
    func journal(_ id: String, doi: String) throws -> RawPaper {
        var p = try samplePaper(id, title: "Journal \(id)")
        p.source = .openalex
        p.doi = doi
        p.published = Date().addingTimeInterval(-86_400)
        return p
    }

    func arxiv(_ id: String, doi: String?) throws -> RawPaper {
        var p = try samplePaper(id, title: "Paper \(id)")
        p.doi = doi
        p.published = Date().addingTimeInterval(-86_400)
        return p
    }

    func run(_ store: Store, arxiv: [RawPaper], openalex: [RawPaper], llm: MockLLM) async throws -> RunReport {
        var config = Config()
        config.topN = 50
        return try await Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: arxiv), FixtureSource(id: .openalex, papers: openalex)],
                                  llm: llm, prompts: PromptLoader(directory: try testTriagePromptDirectory()), config: config)
            .run(force: true, stages: Stage.select.throughHere)
    }

    @Test func arxivFeedCarriesDOI() throws {
        let papers = try ArxivClient.parse(try TestSupport.fixture("arxiv/query-page0.xml"))
        #expect(papers.compactMap(\.doi).contains("10.1007/s13324-026-01278-4"))
        #expect(papers.filter { $0.doi != nil }.count == 2)
    }

    @Test func openAlexRowWithAnArxivPapersDOIIsMerged() async throws {
        let store = try tempStore()
        // Stored earlier from arXiv with a journal DOI.
        try await store.upsertPapers([try arxiv("2610.00011", doi: "10.1/Stored")], runID: nil)
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let report = try await run(store, arxiv: [try arxiv("2610.00029", doi: "10.1/NOW")],
                                   openalex: [try journal("W19", doi: "10.1/now"), try journal("W29", doi: "10.1/stored"), try journal("W39", doi: "10.1/other")],
                                   llm: llm)
        #expect(report.counts.openalex == 1 && report.counts.openalexMerged == 2)
        #expect(report.counts.fetched == 2 && report.counts.triaged == 2)
        #expect(try await store.paper(id: "W19") == nil)
        #expect(try await store.paper(id: "W29") == nil)
        #expect(try await store.paper(id: "W39") != nil)
    }

    @Test func arxivCopyOfAStoredJournalPaperKeepsTheJournalOneOutOfThePool() async throws {
        let store = try tempStore()
        let llm = MockLLM { _, ids in scoreAll(ids) }
        // Run 1: the journal paper is triaged (score 9) but not shown.
        let first = try await run(store, arxiv: [], openalex: [try journal("W99", doi: "10.5/X")], llm: llm)
        #expect(try await store.rankedPapers(runID: first.runID, selectedOnly: true).map(\.paper.id) == ["W99"])
        // Run 2: its arXiv copy appears; the arXiv paper is selectable, the journal copy no longer is.
        let second = try await run(store, arxiv: [try arxiv("2610.00019", doi: "10.5/x")], openalex: [], llm: llm)
        #expect(try await store.rankedPapers(runID: second.runID, selectedOnly: true).map(\.paper.id) == ["2610.00019"])
        #expect(try await store.paper(id: "W99") != nil)
    }

    @Test func hfFirstPaperGetsFirstSeenRunWhenArxivFetchesIt() async throws {
        let store = try tempStore()
        var hf = try samplePaper("2610.00011")
        hf.source = .hfPapers
        try await store.insertPapersIfAbsent([hf])
        try await store.upsertPapers([try samplePaper("2610.00011")], runID: "r1")
        try await store.upsertPapers([try samplePaper("2610.00011")], runID: "r2")
        #expect(try await store.papers(firstSeenIn: "r1").map(\.id) == ["2610.00011"])
        #expect(try await store.papers(firstSeenIn: "r2").isEmpty)
    }
}
