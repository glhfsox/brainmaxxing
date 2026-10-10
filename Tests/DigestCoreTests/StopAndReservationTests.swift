import Foundation
import Synchronization
import Testing
@testable import DigestCore

/// Stopping a run mid-digest (SIGTERM -> task cancel) and in-flight budget reservations.
@Suite struct StopAndReservationTests {
    /// Triage from `MockLLM`; the digest goes through the real `AnthropicClient` whose transport hangs until cancelled.
    struct DigestThroughClient: LLMClient {
        let triage = MockLLM { _, ids in scoreAll(ids) }
        let client: AnthropicClient
        func complete(_ request: LLMRequest) async throws -> LLMResponse {
            request.stage == .digest ? try await client.complete(request) : try await triage.complete(request)
        }
    }

    /// Sends nothing back until the calling task is cancelled (an Opus call the user stops).
    final class HangingSend: HTTPTransport {
        private let sent = Mutex(0)
        var requests: Int { sent.withLock { $0 } }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            sent.withLock { $0 += 1 }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
    }

    @Test func cancelledRunBillsTheDigestEstimateAndEndsPartial() async throws {
        let store = try tempStore()
        let transport = HangingSend()
        let client = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 10), transport: transport, sleep: { _ in })
        let pipeline = Pipeline(store: store, sources: [FixtureSource(id: .arxiv, papers: try digestPapers())],
                                llm: DigestThroughClient(client: client), prompts: PromptLoader(directory: try testPromptDirectory()),
                                config: Config(), fullText: FakeFullText())
        let run = Task { try await pipeline.run(force: true) }
        for _ in 0..<500 where transport.requests == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(transport.requests == 1)
        run.cancel()
        await #expect(throws: PipelineError.self) { _ = try await run.value }

        let record = try #require(try await store.latestRun(reaching: .select))
        #expect(record.status == .partial && record.partial)
        #expect(record.lastStage == .fulltext)
        #expect(record.errors[.digest] == "stopped by user")
        #expect(record.finishedAt != nil)
        let digestCalls = try await store.llmCalls(runID: record.id).filter { $0.stage == .digest }
        #expect(digestCalls.count == 1)
        #expect(digestCalls.first?.estimated == true)
        #expect((digestCalls.first?.usage.outputTokens ?? 0) > AnthropicClient.streamingThreshold)  // worst case: max_tokens
        #expect(try await store.digest(date: LocalDate.string(record.startedAt)) == nil)
    }

    /// Two callers near the cap: only one worst case fits, so exactly one passes; its release frees the room again.
    @Test func concurrentAuthorizationsReserveTheirWorstCase() async throws {
        // Haiku, 1000 prompt + 4096 output: worst case $0.002173. Room for one, not two.
        let meter = CostMeter(store: try tempStore(), dailyBudgetUSD: 0.003)
        func authorize() async -> CostMeter.Reservation? {
            try? await meter.authorize(model: "claude-haiku-5-5", estimatedPromptTokens: 1000, maxOutputTokens: 4096)
        }
        async let a = authorize()
        async let b = authorize()
        let granted = await [a, b].compactMap { $0 }
        #expect(granted.count == 1)
        #expect(abs(await meter.inFlightUSD - 0.002173) < 1e-9)
        await #expect(throws: LLMError.self) {
            try await meter.authorize(model: "claude-haiku-5-5", estimatedPromptTokens: 1000, maxOutputTokens: 4096)
        }
        for r in granted { await meter.release(r) }
        #expect(await meter.inFlightUSD == 0)
        #expect(await authorize() != nil)
    }

    /// The client releases its reservation after recording a call and after a call that failed unbilled.
    @Test func clientReleasesItsReservation() async throws {
        let store = try tempStore()
        let meter = CostMeter(store: store, dailyBudgetUSD: 5)
        let request = LLMRequest(model: "claude-haiku-5-5", system: [], messages: [LLMMessage(role: .user, content: [.text("x", cache: false)])],
                                 maxTokens: 100, stage: .triage)
        let ok = AnthropicClient(apiKey: "k", costMeter: meter, transport: MockTransport([.init(status: 200, body: anthropicToolResponse(input: "{}"))]),
                                 sleep: { _ in })
        _ = try await ok.complete(request)
        #expect(await meter.inFlightUSD == 0)
        #expect(try await store.costSince(.distantPast) > 0)
        let refused = AnthropicClient(apiKey: "k", costMeter: meter, transport: MockTransport([]), sleep: { _ in })
        await #expect(throws: LLMError.self) { try await refused.complete(request) }
        #expect(await meter.inFlightUSD == 0)
    }
}
