import Foundation
import Testing
@testable import DigestCore

/// Budget cap on the digest call, same-day retry after a digest failure, and carry-over of shown papers.
@Suite struct BudgetAndRetryTests {
    func pipeline(_ store: Store, _ llm: LLMClient) throws -> Pipeline {
        Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try digestPapers())], llm: llm,
                 prompts: PromptLoader(directory: try testPromptDirectory()), config: Config(), fullText: FakeFullText())
    }

    /// Money: the 64k-token Opus call is refused before any byte is sent when today's spend + worst case > cap.
    @Test func opusCallIsRefusedBeforeSendingWhenBudgetIsShort() async throws {
        let store = try tempStore()
        try await store.recordLLMCall(LLMCallRecord(runID: nil, stage: .triage, model: "claude-haiku-5-5", promptName: "triage",
                                                    promptVersion: 1, usage: LLMUsage(inputTokens: 1, outputTokens: 1),
                                                    usdEstimate: 3.0, createdAt: Date()))
        let transport = MockTransport([])
        let client = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 4), transport: transport, sleep: { _ in })
        let request = LLMRequest(model: "claude-opus-5-5", system: [], messages: [LLMMessage(role: .user, content: [.text("b", cache: true)])],
                                 tools: [], toolChoice: .auto, maxTokens: 64000, stage: .digest, promptName: "digest", promptVersion: 1)
        await #expect(throws: LLMError.self) { try await client.complete(request) }
        #expect(transport.requests.isEmpty)
    }

    /// `max_tokens` on the digest means no automatic retry. The run stays partial with no digest and the policy
    /// says due, but a deterministic digest failure today is not repeated by an unforced run.
    @Test func truncatedDigestIsNotRetriedByTheNextScheduledRun() async throws {
        let store = try tempStore()
        let llm = StagedLLM { _, r in try StagedLLM.canned(r, stopReason: "max_tokens") }
        let first = try await pipeline(store, llm).run(force: false)
        #expect(first.errors[.digest] as? DigestError == .outputTruncated)
        // What `run --if-due` checks before running again an hour later:
        #expect(try await store.digest(date: LocalDate.string(Date())) == nil)
        let last = try await store.lastSuccessfulRun(reaching: Pipeline.completionStage)
        var config = Config()
        config.schedule.windowStart = 0
        config.schedule.windowEnd = 24
        let decision = await DefaultRunPolicy(config: config, idle: FakeIdle(idle: 3600)).shouldRun(now: Date(), lastSuccess: last?.startedAt)
        #expect(decision.run)
        #expect(try await store.deterministicDigestFailure(onDayOf: Date())?.id == first.runID)
        let second = try await pipeline(store, llm).run(force: false)
        #expect(llm.digestCalls.count == 1)
        guard case .digestFailedToday(runID: first.runID, reason: _)? = second.errors[.digest] as? PipelineError else {
            Issue.record("expected digestFailedToday, got \(String(describing: second.errors[.digest]))")
            return
        }
    }

    /// Carry-over: a paper shown in a digest is never shown again. A same-day `run --force` with nothing new keeps the
    /// morning's digest (no empty edition 2) and its papers stay shown.
    @Test func forcedRerunSameDayKeepsShownPapersShown() async throws {
        let store = try tempStore()
        let llm = StagedLLM()
        let morning = try await pipeline(store, llm).run(force: true)
        #expect(morning.counts.selected == 3)
        _ = try await pipeline(store, llm).run(force: true)
        let today = try #require(try await store.digest(date: LocalDate.string(Date())))
        let pool = try await store.selectionPool(windowStart: .distantPast).map(\.paper.id)
        #expect(!today.empty && today.papers.count == 3 && today.edition == 1)
        #expect(!pool.contains("2610.00019"))
    }
}
