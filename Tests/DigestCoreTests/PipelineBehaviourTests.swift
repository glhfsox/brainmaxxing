import Foundation
import Synchronization
import Testing
@testable import DigestCore

// Behaviour checks that the pipeline suite does not cover: the real CostMeter
// inside a pipeline run, wire bytes of consecutive triage calls, the bundled prompt against its contract,
// `since` / done-today / empty-day semantics.

/// Answers Anthropic requests by scoring every id in the user turn; records the raw request bodies.
final class ScoringTransport: HTTPTransport {
    let usage: String
    private let bodies = Mutex<[Data]>([])
    init(usage: String) { self.usage = usage }
    var requestBodies: [Data] { bodies.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody ?? Data()
        bodies.withLock { $0.append(body) }
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let text = try #require((messages.first?["content"] as? [[String: Any]])?.first?["text"] as? String)
        let batch = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        let ids = batch.compactMap { $0["id"] as? String }
        let input = String(decoding: try JSONEncoder().encode(scoreAll(ids)), as: UTF8.self)
        let url = try #require(request.url)
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (anthropicToolResponse(input: input, usage: usage), http)
    }
}

/// Records the `since` it was asked for.
final class SinceRecordingSource: PaperSource {
    let id = SourceID.arxiv
    let papers: [RawPaper]
    private let seen = Mutex<[Date]>([])
    init(papers: [RawPaper] = []) { self.papers = papers }
    var sinceValues: [Date] { seen.withLock { $0 } }
    func fetch(since: Date, categories: [String]) async throws -> SourceFetch {
        seen.withLock { $0.append(since) }
        return SourceFetch(papers: papers)
    }
}

@Suite struct PipelineBehaviourTests {
    let fixturePapers: [RawPaper]
    init() throws {
        fixturePapers = try ArxivClient.parse(try TestSupport.fixture("arxiv/query-page0.xml")).filter { $0.version == 1 }
    }

    func pipeline(_ store: Store, _ sources: [PaperSource], _ llm: LLMClient, prompts: PromptLoader? = nil, config: Config = Config()) throws -> Pipeline {
        Pipeline(store: store, sources: sources, llm: llm, prompts: try prompts ?? PromptLoader(directory: testTriagePromptDirectory()), config: config)
    }

    // MARK: Money

    @Test func meterWorstCaseIsPromptPlusMaxTokensAtTablePrices() async throws {
        let store = try tempStore()
        // Worst case for 1000 prompt tokens + 4096 output on Haiku, prompt at max(input, cache write):
        // (1000x0.125 + 4096x0.50) / 1M = 0.002173.
        let worst = 0.002173
        func meter(remaining: Double) async throws -> CostMeter {
            let s = try tempStore()
            try await s.recordLLMCall(LLMCallRecord(runID: nil, stage: .triage, model: "claude-haiku-5-5", promptName: nil, promptVersion: nil,
                                                    usage: LLMUsage(inputTokens: 0, outputTokens: 0), usdEstimate: 1.0 - remaining, createdAt: Date()))
            return CostMeter(store: s, dailyBudgetUSD: 1.0)
        }
        try await meter(remaining: worst + 1e-6).authorize(model: "claude-haiku-5-5", estimatedPromptTokens: 1000, maxOutputTokens: 4096)
        await #expect(throws: LLMError.self) {
            try await meter(remaining: worst - 1e-6).authorize(model: "claude-haiku-5-5", estimatedPromptTokens: 1000, maxOutputTokens: 4096)
        }
        let m = CostMeter(store: store, dailyBudgetUSD: 100)
        await #expect(throws: LLMError.promptTooLongForPricing(model: "claude-haiku-5-5", estimatedTokens: 100_001)) {
            try await m.authorize(model: "claude-haiku-5-5", estimatedPromptTokens: 100_001, maxOutputTokens: 1)
        }
        await #expect(throws: LLMError.unknownModelPricing("claude-haiku-4")) {
            try await m.authorize(model: "claude-haiku-4", estimatedPromptTokens: 1, maxOutputTokens: 1)
        }
        // Opus / Sonnet rows of the pricing table.
        let opus = try await m.price(for: "claude-opus-5-5")
        #expect(abs(opus.usd(LLMUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000)) - 29.2) < 1e-9)
        let sonnet = try await m.price(for: "claude-sonnet-5-5")
        #expect(abs(sonnet.usd(LLMUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheReadTokens: 1_000_000, cacheWriteTokens: 1_000_000)) - 14.7) < 1e-9)
    }

    @Test func retryRecordsCostOnceAndRejectedCallsRecordNothing() async throws {
        let store = try tempStore()
        let transport = MockTransport([
            .init(status: 429, body: Data()), .init(status: 529, body: Data()),
            .init(status: 200, body: anthropicToolResponse(input: "{}")),
            .init(status: 400, body: Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"no"}}"#.utf8)),
        ])
        let client = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 4), transport: transport, sleep: { _ in })
        let request = LLMRequest(model: "claude-haiku-5-5", system: [LLMTextBlock(text: "s", cache: true)],
                                 messages: [LLMMessage(role: .user, content: [.text("[]", cache: false)])], maxTokens: 10, stage: .triage)
        _ = try await client.complete(request)
        await #expect(throws: LLMError.self) { try await client.complete(request) }
        #expect(transport.requests.count == 4)
        let spent = try await store.costSince(.distantPast)
        #expect(abs(spent - 0.0002925) < 1e-12)  // one successful call, recorded once
    }

    /// The brief's money rule end to end: real AnthropicClient + CostMeter, budget runs out before batch 3.
    @Test func realMeterStopsTriageMidRunAndKeepsScoredBatches() async throws {
        let store = try tempStore()
        // Each call bills 10 000 input + 4 000 output = $0.003.
        let transport = ScoringTransport(usage: #"{"input_tokens":10000,"output_tokens":4000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}"#)
        let budget = 0.0075
        // Preconditions on worst-case estimates so the expected stop point is batch 3.
        let prompt = try testTriagePrompt()
        let system = try Triage.systemText(prompt, config: Config())
        let worst = try Triage.batches(fixturePapers).map { batch in
            let body = try AnthropicClient.encodeBody(try Triage.request(batch: batch, prompt: prompt, system: system, model: "claude-haiku-5-5"))
            return Double(body.count / 3) * 0.125 / 1e6 + 4096 * 0.50 / 1e6
        }
        #expect(worst.count == 3)
        #expect(worst[0] <= budget && 0.003 + worst[1] <= budget && 0.006 + worst[2] > budget)

        let llm = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: budget), transport: transport, sleep: { _ in })
        let report = try await pipeline(store, [FixtureSource(id: .arxiv, papers: fixturePapers)], llm).run(force: true, stages: Stage.select.throughHere)
        #expect(transport.requestBodies.count == 2)  // the third call was refused before sending
        #expect(report.partial)
        #expect(report.counts.triaged == 50)
        #expect(report.counts.selected == 15)
        #expect(abs(report.totalCost - 0.006) < 1e-12)
        #expect(try await store.costSince(.distantPast) <= budget)
        #expect(try await store.rankedPapers(runID: report.runID).count == 50)
        #expect(try await store.lastRun()?.status == .partial)
        #expect(try await store.lastSuccessfulRun(reaching: .select) == nil)  // does not advance `since`
    }

    /// Cache prefix: tools + system bytes must be identical on the wire for every batch of a run.
    @Test func consecutiveTriageCallsSendByteIdenticalToolsAndSystem() async throws {
        let store = try tempStore()
        let transport = ScoringTransport(usage: #"{"input_tokens":10,"output_tokens":10}"#)
        let llm = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 4), transport: transport, sleep: { _ in })
        _ = try await pipeline(store, [FixtureSource(id: .arxiv, papers: fixturePapers)], llm, prompts: try PromptLoader.bundled())
            .run(force: true, stages: Stage.select.throughHere)
        let bodies = transport.requestBodies
        #expect(bodies.count == 3)
        // Sorted keys put max_tokens, messages, model before system, tool_choice, tools: slice raw bytes.
        func prefix(_ d: Data) throws -> Data {
            let text = String(decoding: d, as: UTF8.self)
            let r = try #require(text.range(of: #","system":["#))
            return Data(text[r.lowerBound...].utf8)
        }
        let first = try prefix(bodies[0])
        for body in bodies.dropFirst() { #expect(try prefix(body) == first) }
        #expect(bodies[0] != bodies[1])
        let json = try #require(try JSONSerialization.jsonObject(with: bodies[1]) as? [String: Any])
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect((system[0]["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        // >= 512 tokens or the API silently writes no cache; ~4 bytes/token is generous.
        #expect(((system[0]["text"] as? String)?.utf8.count ?? 0) / 4 >= 512)
    }

    // MARK: Prompt contract

    @Test func bundledTriagePromptMatchesContract() throws {
        let p = try PromptLoader.bundled().load("triage")
        // The contract, not a version: any promoted triage.vN must satisfy it.
        #expect(p.name == "triage" && p.version >= 1 && p.toolName == "triage_result")
        #expect(ModelPricing.table[p.model] != nil, "triage model \(p.model) has no pricing; CostMeter would refuse it")
        #expect(p.cacheBreakpoints == ["system"])
        #expect(Set(p.placeholders) == ["interest_profile", "feedback_examples", "language"])
        for language in ["ru", "en"] {
            let text = try Triage.systemText(p, config: Config(language: language))
            #expect(!text.contains("{{"))
            #expect(text.contains(Config.defaultInterestProfile))
        }
        func stripDescriptions(_ v: JSONValue) -> JSONValue {
            switch v {
            case let .object(o): .object(o.filter { $0.key != "description" }.mapValues(stripDescriptions))
            case let .array(a): .array(a.map(stripDescriptions))
            default: v
            }
        }
        let contract = #"""
        {"type":"object","additionalProperties":false,"required":["results"],"properties":{"results":{"type":"array","items":{
         "type":"object","additionalProperties":false,"required":["id","one_line","tags","score"],"properties":{
          "id":{"type":"string"},"one_line":{"type":"string","maxLength":200},
          "tags":{"type":"array","items":{"type":"string"},"maxItems":5},
          "score":{"type":"integer","minimum":0,"maximum":10}}}}}}
        """#
        let expected = try JSONDecoder().decode(JSONValue.self, from: Data(contract.utf8))
        #expect(stripDescriptions(try #require(p.schema)) == expected)
    }

    @Test func toolInputScoresZeroAndOneDecodeAsIntegers() throws {
        // JSONValue tries Bool before Double; 0/1 scores must survive the round trip into TriageItem.score.
        let body = anthropicToolResponse(input: #"{"results":[{"id":"a","one_line":"x","tags":[],"score":0},{"id":"b","one_line":"y","tags":[],"score":1}]}"#)
        let r = try AnthropicClient.decodeResponse(body).toolInput("triage_result", as: TriageResult.self)
        #expect(r.results.map(\.score) == [0, 1])
    }

    // MARK: Data

    @Test func sinceIsCapOnEmptyDatabaseThenLastCompleteRunStartMinusLag() async throws {
        let store = try tempStore()
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let source = SinceRecordingSource()
        let before = Date()
        // Nothing fetched -> empty digest without an LLM call, so the run is complete (reaches .digest).
        _ = try await pipeline(store, [source], llm).run(force: true)
        let first = try #require(source.sinceValues.first)
        #expect(abs(first.timeIntervalSince(before.addingTimeInterval(-7 * 86_400))) < 5)

        let lastStart = try #require(try await store.lastSuccessfulRun(reaching: Pipeline.completionStage)?.startedAt)
        _ = try await pipeline(store, [source], llm).run(force: true, stages: Stage.select.throughHere)
        // The window reaches announce_lag_days (4) before the last complete run's start.
        #expect(abs(try #require(source.sinceValues.last).timeIntervalSince(lastStart.addingTimeInterval(-4 * 86_400))) < 0.01)

        // A complete run older than the cap does not widen the window past 7 days.
        let old = try tempStore()
        try await old.startRun(id: "old", startedAt: Date().addingTimeInterval(-10 * 86_400), force: false, since: nil, stages: .all)
        try await old.finishRun("old", status: .succeeded, partial: false, counts: RunCounts(), promptVersions: [:], errorSummary: nil, finishedAt: Date())
        try await old.markStageReached("old", stage: .digest)
        let s2 = SinceRecordingSource()
        _ = try await pipeline(old, [s2], llm).run(force: true, stages: Stage.select.throughHere)
        #expect(abs(try #require(s2.sinceValues.first).timeIntervalSince(Date().addingTimeInterval(-7 * 86_400))) < 5)
    }

    @Test func doneTodayUsesStartOfLastCompleteRunInLocalDay() async throws {
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        // Started 23:50 yesterday, finished after midnight: today is not done.
        let store = try tempStore()
        try await store.startRun(id: "late", startedAt: startOfToday.addingTimeInterval(-600), force: false, since: nil, stages: .all)
        try await store.finishRun("late", status: .succeeded, partial: false, counts: RunCounts(), promptVersions: [:], errorSummary: nil,
                                  finishedAt: startOfToday.addingTimeInterval(600))
        try await store.markStageReached("late", stage: .digest)
        _ = try await pipeline(store, [SinceRecordingSource()], llm).run(force: false, stages: Stage.select.throughHere)
        // Started 00:10 today: refused without --force.
        let store2 = try tempStore()
        try await store2.startRun(id: "early", startedAt: startOfToday.addingTimeInterval(600), force: false, since: nil, stages: .all)
        try await store2.finishRun("early", status: .succeeded, partial: false, counts: RunCounts(), promptVersions: [:], errorSummary: nil,
                                   finishedAt: startOfToday.addingTimeInterval(900))
        try await store2.markStageReached("early", stage: .digest)
        await #expect(throws: PipelineError.self) {
            try await pipeline(store2, [SinceRecordingSource()], llm).run(force: false, stages: Stage.select.throughHere)
        }
        // A partial run today does not block the next one.
        let store3 = try tempStore()
        try await store3.startRun(id: "part", startedAt: Date(), force: false, since: nil, stages: .all)
        try await store3.finishRun("part", status: .partial, partial: true, counts: RunCounts(), promptVersions: [:], errorSummary: nil, finishedAt: Date())
        try await store3.markStageReached("part", stage: .digest)
        _ = try await pipeline(store3, [SinceRecordingSource()], llm).run(force: false, stages: Stage.select.throughHere)
    }

    @Test func emptyFetchMakesNoCallAndInventsNothing() async throws {
        let store = try tempStore()
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let report = try await pipeline(store, [SinceRecordingSource()], llm).run(force: true, stages: Stage.select.throughHere)
        #expect(llm.requests.isEmpty)
        #expect(report.counts == RunCounts())
        #expect(!report.partial && report.errors.isEmpty)
        #expect(try await store.rankedPapers(runID: report.runID).isEmpty)
        #expect(try await store.paperCount() == 0)
        #expect(try await store.lastRun()?.status == .succeeded)
    }

    @Test func dedupAcrossSourcesKeepsOneRowPerArxivId() async throws {
        let store = try tempStore()
        let llm = MockLLM { _, ids in scoreAll(ids) }
        let page1 = try ArxivClient.parse(try TestSupport.fixture("arxiv/query-page1.xml")).filter { $0.version == 1 }
        // Same arXiv papers arriving from a second source (e.g. OpenAlex mapped via ids.arxiv) must not be triaged twice.
        let other = fixturePapers.prefix(10).map { p -> RawPaper in var q = p; q.source = .openalex; q.title = p.title.uppercased(); return q }
        let report = try await pipeline(store, [FixtureSource(id: .arxiv, papers: fixturePapers + page1), FixtureSource(id: .openalex, papers: Array(other))], llm)
            .run(force: true, stages: Stage.select.throughHere)
        let unique = Set((fixturePapers + page1).map(\.id)).count
        #expect(report.counts.fetched == fixturePapers.count + page1.count + 10)
        #expect(report.counts.deduped == unique)
        #expect(report.counts.triaged == unique)
        #expect(Set(llm.requests.flatMap { r -> [String] in
            guard case let .text(t, _)? = r.messages.first?.content.first,
                  let a = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [[String: Any]] else { return [] }
            return a.compactMap { $0["id"] as? String }
        }).count == unique)
    }

    /// arXiv `<updated>` of a v1 is its submission time; the paper appears in the API only at the next
    /// announcement (~20:00 ET, hours to days later). Every fixture entry has `updated` <= 2026-10-20T18:00Z
    /// but was served on 2026-10-21. A complete run that started at 2026-10-20T19:00Z could not have seen
    /// them; the next run must still fetch them.
    @Test func nextRunStillSeesPapersAnnouncedAfterLastRunStarted() async throws {
        let lastRunStart = try TestSupport.date("2026-10-20T19:00:00Z")
        let nextRun = try TestSupport.date("2026-10-21T21:00:00Z")
        let since = Pipeline.windowStart(now: nextRun, lastCompleteRunStart: lastRunStart, config: Config())
        let transport = MockTransport([.init(status: 200, body: try TestSupport.fixture("arxiv/query-page0.xml")),
                                       .init(status: 200, body: try TestSupport.fixture("arxiv/query-page1.xml"))])
        let client = ArxivClient(transport: transport, rateLimiter: RateLimiter(minInterval: 3, sleep: { _ in }), pageSize: 100, maxPages: 2, sleep: { _ in })
        let papers = try await client.fetch(since: since, categories: ["cs.LG"]).papers
        #expect(papers.count > 0)
    }
}
