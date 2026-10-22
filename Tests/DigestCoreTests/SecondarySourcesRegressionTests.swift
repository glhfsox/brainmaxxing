import Foundation
import Testing
@testable import DigestCore

/// Regression tests for the OpenAlex and HF Daily Papers sources; each pins a fixed defect.
@Suite struct SecondarySourcesRegressionTests {
    func prompts() throws -> PromptLoader { PromptLoader(directory: try testPromptDirectory()) }

    /// The ids sent to triage across all batches.
    func triagedIDs(_ llm: StagedLLM) -> Set<String> {
        Set(llm.triage.requests.flatMap { r -> [String] in
            guard case let .text(t, _)? = r.messages.first?.content.first else { return [] }
            return ((try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        })
    }

    /// `published` of an OpenAlex row is 00:00 UTC of its `publication_date`, and the selection pool needs
    /// `published >= since` (an instant later that day). The client therefore asks OpenAlex from the UTC day after
    /// since's: the first day it can return is triaged and selectable.
    @Test func openAlexPaperOnTheWindowsFirstDayIsTriagedAndSelectable() async throws {
        let store = try tempStore()
        let config = Config()
        // Empty store: since = now - window_cap_days (Pipeline.windowStart).
        let since = Pipeline.windowStart(now: Date(), lastCompleteRunStart: nil, config: config)
        let firstDay = OpenAlexClient.utcDay(since.addingTimeInterval(86_400))
        // One recorded row re-dated to the first day the client requests.
        var page = try #require(try JSONSerialization.jsonObject(with: TestSupport.fixture("openalex/works-page1.json")) as? [String: Any])
        var rows = try #require(page["results"] as? [[String: Any]])
        rows = rows.filter { ($0["id"] as? String)?.hasSuffix("W7161550517") == true }.map { var r = $0; r["publication_date"] = firstDay; return r }
        page["results"] = rows
        let transport = MockTransport([.init(status: 200, body: try JSONSerialization.data(withJSONObject: page))])
        let openalex = OpenAlexClient(transport: transport, rateLimiter: instantLimiter(FakeClock()))
        let llm = StagedLLM()
        let report = try await Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try digestPapers()), openalex],
                                        llm: llm, prompts: try prompts(), config: config).run(force: true, stages: Stage.select.throughHere)
        #expect(transport.requests.first?.url?.query(percentEncoded: false)?.contains("from_publication_date:\(firstDay),") == true)
        #expect(triagedIDs(llm).contains("W7161550517"))  // money was spent on it
        let selected = try await store.rankedPapers(runID: report.runID, selectedOnly: true).map(\.paper.id)
        #expect(selected.contains("W7161550517"))  // digitScore 7 >= min_score
    }

    /// `run --stage digest` rebuilds the same run's edition: the HF papers it listed stay eligible (not excluded as
    /// "already in an HF section"), and the original run's secondary-source warning should survive in `error_summary`.
    @Test func rerunDigestKeepsHFSectionAndSecondarySourceWarning() async throws {
        let store = try tempStore()
        var config = Config()
        config.hfTopK = 3
        let listing = try hfFixture("2026-10-22")
        func pipeline(_ llm: StagedLLM) throws -> Pipeline {
            Pipeline(store: store, sources: [FailingSource(), FixtureSource(id: .arxiv, papers: try digestPapers())], llm: llm,
                     prompts: try prompts(), config: config,
                     fullText: FakeFullText(), hfPapers: HFPapersClient(transport: MockTransport([.init(status: 200, body: listing)])))
        }
        let first = try await pipeline(StagedLLM()).run(force: true)
        let before = try #require(try await store.latestDigest())
        #expect(!first.partial && before.hfSection.count == 3)
        #expect(try await store.lastRun()?.errorSummary?.contains("source openalex failed") == true)

        let rerunLLM = StagedLLM()
        let rerun = try await pipeline(rerunLLM).rerunDigest()
        let after = try #require(try await store.latestDigest())
        #expect(rerun.runID == first.runID && after.edition == before.edition)
        #expect(after.hfSection.map(\.id) == before.hfSection.map(\.id))
        let bundle = try #require(rerunLLM.digestCalls.first.flatMap { r -> String? in
            if case let .text(t, true)? = r.messages.first?.content.first { return t } else { return nil } })
        #expect(!bundle.contains("<hf_papers>\n(none)"))

        let summary = try await store.run(id: first.runID)?.errorSummary
        #expect(summary?.contains("source openalex failed") == true)
        #expect(rerun.warnings.count == 1 && !rerun.partial)
    }

    /// A malformed HF body is a warning, not a partial run, and the digest is still written.
    @Test func malformedHFListingIsAWarningNotPartial() async throws {
        let store = try tempStore()
        let hf = HFPapersClient(transport: MockTransport([.init(status: 200, body: Data("{\"error\":\"oops\"".utf8))]))
        let llm = StagedLLM()
        let report = try await Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try digestPapers())], llm: llm,
                                        prompts: try prompts(), config: Config(), fullText: FakeFullText(), hfPapers: hf).run(force: true)
        #expect(!report.partial && report.errors.isEmpty && llm.digestCalls.count == 1)
        let run = try #require(try await store.lastRun())
        #expect(run.status == .succeeded && run.errorSummary?.contains("cannot parse HF Daily Papers response") == true)
        #expect(try await store.latestDigest()?.hfSection == [])
    }

    /// One entry without `paper.id` must not make the whole day's listing unparseable (no strict `[Entry]` decode).
    @Test func oneMalformedHFEntryDoesNotDropTheDay() throws {
        let body = Data(#"[{"paper":{"id":"2610.00001","title":"Good","summary":"S.","upvotes":3}},{"paper":{"title":"No id"}}]"#.utf8)
        let ids = (try? HFPapersClient.parse(body))?.map(\.arxivID)
        #expect(ids == ["2610.00001"])
    }

    /// No request made by either secondary client carries an email, `mailto` or an API key.
    @Test func secondarySourceRequestsCarryNoIdentity() async throws {
        let oa = MockTransport((0..<3).map { _ in .init(status: 200, body: Data(#"{"meta":{"count":0},"results":[]}"#.utf8)) })
        let client = OpenAlexClient(transport: oa, rateLimiter: instantLimiter(FakeClock()))
        _ = try await client.fetch(since: Date(), categories: [])
        _ = try await client.search(query: "x", limit: 3)
        _ = try await client.citedBy(of: OpenAlexWork(paper: try samplePaper("W1"), citedByCount: 0, publicationYear: nil, arxivID: nil), limit: 3)
        let hf = MockTransport([.init(status: 200, body: Data("[]".utf8))])
        _ = try await HFPapersClient(transport: hf).daily(date: "2026-10-22")
        for r in oa.requests + hf.requests {
            let s = (r.url?.absoluteString ?? "").lowercased()
            #expect(!s.contains("mailto") && !s.contains("api_key") && !s.contains("@"), "\(s)")
            #expect(r.value(forHTTPHeaderField: "Authorization") == nil && r.value(forHTTPHeaderField: "From") == nil)
        }
    }
}
