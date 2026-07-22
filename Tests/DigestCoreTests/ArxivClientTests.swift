import Foundation
import Testing
@testable import DigestCore

@Suite struct ArxivClientTests {
    let page0: Data
    let page1: Data

    init() throws {
        page0 = try TestSupport.fixture("arxiv/query-page0.xml")
        page1 = try TestSupport.fixture("arxiv/query-page1.xml")
    }

    func client(_ transport: MockTransport, includeReversions: Bool = false, maxPages: Int = 20, archive: RawArchive? = nil) -> ArxivClient {
        ArxivClient(transport: transport, rateLimiter: RateLimiter(minInterval: 3, sleep: { _ in }),
                    includeReversions: includeReversions, pageSize: 100, maxPages: maxPages, archive: archive, sleep: { _ in })
    }

    @Test func parsesPage0() throws {
        let papers = try ArxivClient.parse(page0)
        #expect(papers.count == 100)
        let first = try #require(papers.first)
        #expect(first.id == "2610.28632")
        #expect(first.version == 1)
        #expect(first.title == "Joints, Camera, Action! Co-Generating 3D Motion and Video for Arbitrary Rigs")
        #expect(first.abstract.hasPrefix("Video generation models can now depict"))
        #expect(first.categories == ["cs.CV", "cs.AI", "cs.GR", "cs.LG", "cs.RO"])
        #expect(first.primaryCategory == "cs.CV")
        #expect(first.absURL?.absoluteString == "https://arxiv.org/abs/2610.28632v1")
        #expect(first.pdfURL?.absoluteString == "https://arxiv.org/pdf/2610.28632v1")
        #expect(first.published == (try TestSupport.date("2026-10-20T17:59:56Z")))
        #expect(first.updated == (try TestSupport.date("2026-10-20T17:59:56Z")))
        #expect(first.authors.count == 8)
        #expect(first.authors.first == "Noam Rotstein")
        #expect(papers.allSatisfy { !$0.id.contains("v") && !$0.title.contains("\n") && $0.primaryCategory != nil && $0.absURL != nil && $0.pdfURL != nil })
        let versions = Dictionary(grouping: papers, by: \.version).mapValues(\.count)
        #expect(versions == [1: 64, 2: 21, 3: 11, 4: 2, 6: 2])
    }

    @Test func dropsReversionsUnlessIncluded() async throws {
        let since = try TestSupport.date("2026-10-20T16:51:30Z")
        let v1Only = try await client(MockTransport([.init(status: 200, body: page0), .init(status: 200, body: page1)]))
            .fetch(since: since, categories: ["cs.LG"]).papers
        #expect(v1Only.count == 64)
        #expect(v1Only.allSatisfy { $0.version == 1 })
        let all = try await client(MockTransport([.init(status: 200, body: page0), .init(status: 200, body: page1)]), includeReversions: true)
            .fetch(since: since, categories: ["cs.LG"]).papers
        #expect(all.count == 99)  // one entry on page 0 is older than `since`
    }

    @Test func paginationStopsWhenWholePageIsOld() async throws {
        // page 0 has one old entry (must not stop there); page 1 is entirely older than `since` -> stop.
        let transport = MockTransport([.init(status: 200, body: page0), .init(status: 200, body: page1), .init(status: 200, body: page1)])
        let archiveRoot = try TestSupport.tempDirectory()
        let papers = try await RunContext.$runID.withValue("run-x") {
            try await client(transport, archive: RawArchive(root: archiveRoot))
                .fetch(since: try TestSupport.date("2026-10-20T16:51:30Z"), categories: ["cs.LG", "stat.ML"]).papers
        }
        #expect(transport.requests.count == 2)
        #expect(papers.count == 64)
        let urls = transport.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.first == "https://export.arxiv.org/api/query?search_query=cat:cs.LG+OR+cat:stat.ML&sortBy=lastUpdatedDate&sortOrder=descending&start=0&max_results=100")
        #expect(urls.last?.contains("start=100&") == true)
        #expect(transport.requests.first?.value(forHTTPHeaderField: "User-Agent") == "brainmaxxing/0.1 (+https://github.com/brainmaxxing)")
        #expect(FileManager.default.fileExists(atPath: archiveRoot.appendingPathComponent("run-x/arxiv-page1.xml").path))
    }

    @Test func paginationContinuesThroughPartlyFreshPagesUpToCap() async throws {
        let transport = MockTransport([.init(status: 200, body: page0), .init(status: 200, body: page1), .init(status: 200, body: page1)])
        let result = try await client(transport, maxPages: 2).fetch(since: try TestSupport.date("2026-10-20T16:00:00Z"), categories: ["cs.LG"])
        #expect(transport.requests.count == 2)
        #expect(result.papers.count == 64 + 37)
        // The window ends on the last page (its oldest entry is before `since`): the cap did not cut it.
        #expect(!result.truncated)
    }

    @Test func retries429And503ThenGivesUp() async throws {
        let ok = MockTransport([.init(status: 429, body: Data()), .init(status: 503, body: Data()), .init(status: 200, body: page1)])
        #expect(try await client(ok, maxPages: 1).fetch(since: Date.distantPast, categories: ["cs.LG"]).papers.count == 100)
        #expect(ok.requests.count == 3)

        let failing = MockTransport(Array(repeating: .init(status: 503, body: Data()), count: 5))
        await #expect(throws: ArxivError.badStatus(503)) {
            try await client(failing).fetch(since: Date.distantPast, categories: ["cs.LG"])
        }
        #expect(failing.requests.count == 3)

        let notFound = MockTransport([.init(status: 400, body: Data()), .init(status: 200, body: page1)])
        await #expect(throws: ArxivError.badStatus(400)) {
            try await client(notFound).fetch(since: Date.distantPast, categories: ["cs.LG"])
        }
        #expect(notFound.requests.count == 1)
    }

    /// A minimal Atom feed: entries are (versioned id, published, updated).
    func feed(total: Int, _ entries: [(String, String, String)] = []) -> Data {
        let body = entries.map { id, published, updated in
            """
            <entry><id>http://arxiv.org/abs/\(id)</id><title>T \(id)</title><summary>S</summary>
            <published>\(published)</published><updated>\(updated)</updated><author><name>A</name></author>
            <arxiv:primary_category term="cs.LG"/><category term="cs.LG"/></entry>
            """
        }.joined()
        return Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/" xmlns:arxiv="http://arxiv.org/schemas/atom">
            <updated>2026-10-21T20:00:00Z</updated><opensearch:totalResults>\(total)</opensearch:totalResults>\(body)</feed>
            """.utf8)
    }

    @Test func defaultPagingIs1000PerPage() {
        #expect(ArxivClient().pageURL(start: 1000, categories: ["cs.LG"])?.absoluteString.hasSuffix("&start=1000&max_results=1000") == true)
    }

    @Test func versionFilterKeepsByPublishedNotVersion() async throws {
        let since = try TestSupport.date("2026-10-18T00:00:00Z")
        let page = feed(total: 3, [
            ("2610.00001v2", "2026-10-19T10:00:00Z", "2026-10-20T10:00:00Z"),  // new in the window, first seen as v2: kept
            ("2610.00002v1", "2026-10-19T09:00:00Z", "2026-10-19T09:00:00Z"),  // plain new v1: kept
            ("2401.00003v1", "2024-01-01T00:00:00Z", "2026-10-19T08:00:00Z"),  // old paper with a fresh `updated`: dropped
        ])
        let kept = try await client(MockTransport([.init(status: 200, body: page)])).fetch(since: since, categories: ["cs.LG"]).papers
        #expect(kept.map(\.id) == ["2610.00001", "2610.00002"])
        #expect(kept.first?.version == 2)  // version is still stored
        let all = try await client(MockTransport([.init(status: 200, body: page)]), includeReversions: true).fetch(since: since, categories: ["cs.LG"]).papers
        #expect(all.count == 3)
    }

    @Test func pageCapInsideWindowMarksTruncated() async throws {
        // Page 0's oldest entry (16:51) is still inside a 16:00 window when the 1-page cap stops paging.
        let result = try await client(MockTransport([.init(status: 200, body: page0)]), maxPages: 1)
            .fetch(since: try TestSupport.date("2026-10-20T16:00:00Z"), categories: ["cs.LG"])
        #expect(result.truncated)
        #expect(result.papers.count == 64)
        // A short last page is the end of the results, not a cut.
        let short = try await client(MockTransport([.init(status: 200, body: feed(total: 1, [("2610.00001v1", "2026-10-20T10:00:00Z", "2026-10-20T10:00:00Z")]))]), maxPages: 1)
            .fetch(since: try TestSupport.date("2026-10-20T00:00:00Z"), categories: ["cs.LG"])
        #expect(!short.truncated && short.papers.count == 1)
    }

    @Test func emptyPageInsideResultSetIsRetriedThenFails() async throws {
        let empty = feed(total: 817_468)
        let recovered = MockTransport([.init(status: 200, body: empty), .init(status: 200, body: page1)])
        let papers = try await client(recovered, maxPages: 1).fetch(since: Date.distantPast, categories: ["cs.LG"]).papers
        #expect(recovered.requests.count == 2)
        #expect(papers.count == 100)

        let broken = MockTransport(Array(repeating: .init(status: 200, body: empty), count: 5))
        await #expect(throws: ArxivError.emptyPage(start: 0)) {
            try await client(broken).fetch(since: Date.distantPast, categories: ["cs.LG"])
        }
        #expect(broken.requests.count == 3)

        // An empty page past the end of the results is a normal stop.
        let done = MockTransport([.init(status: 200, body: feed(total: 0))])
        #expect(try await client(done).fetch(since: Date.distantPast, categories: ["cs.LG"]).papers.isEmpty)
        #expect(done.requests.count == 1)
    }

    @Test func rateLimiterSpacesCallsThreeSeconds() async throws {
        let clock = FakeClock()
        let limiter = RateLimiter(minInterval: 3, clock: { clock.now }, sleep: { clock.sleep($0) })
        var times: [Date] = []
        for _ in 0..<3 {
            try await limiter.wait()
            times.append(clock.now)
        }
        #expect(clock.sleeps == [3, 3])
        #expect(zip(times, times.dropFirst()).allSatisfy { $1.timeIntervalSince($0) >= 3 })
        clock.advance(10)
        try await limiter.wait()
        #expect(clock.sleeps == [3, 3])  // enough time passed, no extra sleep
        clock.advance(1)
        try await limiter.wait()
        #expect(clock.sleeps == [3, 3, 2])
    }
}
