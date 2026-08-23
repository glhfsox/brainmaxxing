import Foundation
import Testing
@testable import DigestCore

/// SSE streaming in `AnthropicClient`, driven by canned transcripts in `Fixtures/anthropic/`.
@Suite struct StreamingTests {
    func request(maxTokens: Int = 64000, effort: String? = "high") -> LLMRequest {
        LLMRequest(model: "claude-opus-5-5", system: [LLMTextBlock(text: "sys", cache: true)],
                   messages: [LLMMessage(role: .user, content: [.text("bundle", cache: true), .text("go", cache: false)])],
                   tools: [ToolDefinition(name: "digest", description: "", inputSchema: .object([:]), strict: true)],
                   toolChoice: .auto, maxTokens: maxTokens, stage: .digest, promptName: "digest", promptVersion: 1, effort: effort)
    }

    func client(_ fixture: String) throws -> (AnthropicClient, MockTransport, Store) {
        let store = try tempStore()
        let transport = MockTransport([.init(status: 200, body: try TestSupport.fixture("anthropic/\(fixture)"))])
        return (AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 10), transport: transport, sleep: { _ in }),
                transport, store)
    }

    @Test func bodyStreamsAboveThresholdAndCarriesEffort() throws {
        let streamed = try #require(try JSONSerialization.jsonObject(with: AnthropicClient.encodeBody(request())) as? [String: Any])
        #expect(streamed["stream"] as? Bool == true)
        #expect((streamed["output_config"] as? [String: String]) == ["effort": "high"])
        let plain = try #require(try JSONSerialization.jsonObject(with: AnthropicClient.encodeBody(request(maxTokens: 8192, effort: nil))) as? [String: Any])
        #expect(plain["stream"] == nil)
        #expect(plain["output_config"] == nil)
    }

    @Test func multiChunkToolUseIsAssembledAndBilled() async throws {
        let (client, _, store) = try client("stream-tool-multichunk.sse")
        try await store.startRun(id: "s1", startedAt: Date(), force: true, since: nil, stages: .all)
        let response = try await RunContext.$runID.withValue("s1") { try await client.complete(request()) }
        #expect(response.stopReason == "tool_use")
        #expect(response.model == "claude-opus-5-5")
        #expect(response.usage == LLMUsage(inputTokens: 1200, outputTokens: 5400, cacheReadTokens: 0, cacheWriteTokens: 30000))
        #expect(response.content.count == 2)  // thinking dropped; text + tool_use
        #expect(response.content.first == .text("Calling the tool.", cache: false))
        struct Out: Decodable { struct P: Decodable { let id: String; let figure_index: Int }; let title: String; let papers: [P]; let note: String }
        let out = try response.toolInput("digest", as: Out.self)
        #expect(out.title == "Rigs and motion")
        #expect(out.papers.first?.id == "2610.28632" && out.papers.first?.figure_index == 2)
        #expect(out.note == "ünïcødé")
        let calls = try await store.llmCalls(runID: "s1")
        #expect(calls.count == 1 && calls.first?.usage.outputTokens == 5400 && calls.first?.stage == .digest)
    }

    @Test func maxTokensEndingReportsStopReasonWithoutThrowing() async throws {
        let (client, _, store) = try client("stream-max-tokens.sse")
        try await store.startRun(id: "s2", startedAt: Date(), force: true, since: nil, stages: .all)
        let response = try await RunContext.$runID.withValue("s2") { try await client.complete(request()) }
        #expect(response.stopReason == "max_tokens")
        #expect(response.content == [.toolUse(id: "toolu_02", name: "digest", input: .null)])
        #expect(try await store.llmCalls(runID: "s2").first?.usage.outputTokens == 64000)
    }

    @Test func midStreamErrorThrowsAfterBilling() async throws {
        let (client, transport, store) = try client("stream-error.sse")
        try await store.startRun(id: "s3", startedAt: Date(), force: true, since: nil, stages: .all)
        await #expect(throws: LLMError.streamError(type: "overloaded_error", message: "Overloaded")) {
            try await RunContext.$runID.withValue("s3") { try await client.complete(request()) }
        }
        #expect(transport.requests.count == 1)  // not retried
        // Billed at its worst case: the reported prompt, max_tokens of output.
        let call = try #require(try await store.llmCalls(runID: "s3").first)
        #expect(call.usage.inputTokens == 1000 && call.usage.outputTokens == 64000 && call.estimated)
    }

    /// A streamed call that may have reached the API and failed without usage is recorded as an estimate;
    /// one that never left the machine is not recorded.
    @Test(arguments: [(URLError.Code.timedOut, true), (.networkConnectionLost, true), (.notConnectedToInternet, false)])
    func failedStreamWithoutUsageIsRecordedAsEstimate(code: URLError.Code, recorded: Bool) async throws {
        let store = try tempStore()
        try await store.startRun(id: "s4", startedAt: Date(), force: true, since: nil, stages: .all)
        let client = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 10), transport: FailingTransport(code: code),
                                     sleep: { _ in })
        await #expect(throws: LLMError.self) { try await RunContext.$runID.withValue("s4") { try await client.complete(request()) } }
        let calls = try await store.llmCalls(runID: "s4")
        #expect(calls.count == (recorded ? 1 : 0))
        if recorded {
            let promptTokens = try AnthropicClient.encodeBody(request()).count / 3
            #expect(calls.first?.usage == LLMUsage(inputTokens: promptTokens, outputTokens: 64000))
            #expect(calls.first?.estimated == true)
        }
    }

    @Test func okStatusWithoutMessageStartIsRecordedAsEstimate() async throws {
        let store = try tempStore()
        try await store.startRun(id: "s5", startedAt: Date(), force: true, since: nil, stages: .all)
        let client = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 10),
                                     transport: MockTransport([.init(status: 200, body: Data())]), sleep: { _ in })
        await #expect(throws: LLMError.self) { try await RunContext.$runID.withValue("s5") { try await client.complete(request()) } }
        #expect(try await store.llmCalls(runID: "s5").map(\.estimated) == [true])
    }

    @Test func truncatedStreamIsAnError() {
        let cut = Data("event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"model\":\"m\",\"usage\":{\"input_tokens\":5,\"output_tokens\":1}}}\n\n".utf8)
        let parsed = AnthropicClient.parseStream(cut)
        #expect(parsed.usage == LLMUsage(inputTokens: 5, outputTokens: 1))
        #expect(throws: LLMError.self) { try parsed.result.get() }
    }
}

/// Throws `URLError(code)` on every send.
struct FailingTransport: HTTPTransport {
    let code: URLError.Code
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(code) }
}
