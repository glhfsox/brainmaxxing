import Foundation
import Synchronization
import Testing
@testable import DigestCore

/// Chat money paths through the real `AnthropicClient` (mock transport, no network).
@Suite struct ChatBillingTests {
    static func sse(model: String = "claude-sonnet-5-5", blocks: [String], stop: String, input: Int = 2000, output: Int = 50) -> Data {
        var events = [#"{"type":"message_start","message":{"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":1}}}"#]
        events += blocks
        events.append(#"{"type":"message_delta","delta":{"stop_reason":"\#(stop)"},"usage":{"output_tokens":\#(output)}}"#)
        events.append(#"{"type":"message_stop"}"#)
        return Data(events.map { "data: \($0)\n\n" }.joined().utf8)
    }

    static let toolUseBlocks = [
        #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"get_paper","input":{}}}"#,
        #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"id\":\"2610.00001\"}"}}"#,
        #"{"type":"content_block_stop","index":0}"#,
    ]
    static func textBlocks(_ t: String) -> [String] {
        [#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
         #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(t)"}}"#,
         #"{"type":"content_block_stop","index":0}"#]
    }

    func newStore() throws -> Store {
        try Store(url: try TestSupport.tempDirectory().appendingPathComponent("digest.sqlite"))
    }

    func drain(_ s: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var out: [ChatEvent] = []
        for await e in s { out.append(e) }
        return out
    }

    /// One `llm_calls` row per API call: tool round + final answer = 2 rows, both `stage = chat`.
    @Test func toolRoundAndAnswerAreEachRecordedOnceAsChat() async throws {
        let store = try newStore()
        let transport = MockTransport([.init(status: 200, body: Self.sse(blocks: Self.toolUseBlocks, stop: "tool_use")),
                                       .init(status: 200, body: Self.sse(blocks: Self.textBlocks("ok [2610.00001]"), stop: "end_turn"))])
        let llm = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 5), transport: transport, sleep: { _ in })
        let session = ChatSession(store: store, llm: llm, tools: FakeTools(), prompts: try PromptLoader.bundled(), config: Config())
        let events = await drain(await session.send("hi", quotes: []))
        guard case .done? = events.last else { Issue.record("no done: \(events)"); return }
        let days = try await store.dailyCosts(since: .distantPast)
        #expect(days.map(\.calls).reduce(0, +) == 2)
        #expect(days.map(\.chatUSD).reduce(0, +) == days.map(\.usd).reduce(0, +))
        #expect(transport.requests.count == 2)
    }

    /// Over budget: refused before any request, shown as `.error`, user message kept, nothing billed.
    @Test func budgetRefusalIsAnErrorEventNotACrash() async throws {
        let store = try newStore()
        let transport = MockTransport([])
        let llm = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 0.01), transport: transport, sleep: { _ in })
        let session = ChatSession(store: store, llm: llm, tools: FakeTools(), prompts: try PromptLoader.bundled(), config: Config())
        let events = await drain(await session.send("hi", quotes: []))
        guard case let .error(message)? = events.last else { Issue.record("no error: \(events)"); return }
        #expect(message.contains("budget"))
        #expect(transport.requests.isEmpty)
        #expect(try await store.messages(conversationID: "general").map(\.role) == [.user])
    }

    /// Compaction triggers at ~60k tokens estimated as chars/4, but `CostMeter` estimates prompts as bytes/3 and refuses
    /// Haiku prompts over its 100k flat-rate tier. Cyrillic is 2 bytes per char in UTF-8 and `language` defaults to "ru",
    /// so for a Russian conversation the compact call is refused every time and the history is never compacted.
    @Test(arguments: ["e", "ж"])
    func longConversationIsCompacted(letter: String) async throws {
        let store = try newStore()
        let conv = try await store.conversation(forDigestDate: nil)
        let body = String(repeating: letter, count: 3_000)
        for i in 0..<100 {
            try await store.appendMessage(ChatMessage(conversationID: conv, role: .user, content: "q\(i) \(body)",
                                                      createdAt: Date(timeIntervalSince1970: Double(2 * i))))
            try await store.appendMessage(ChatMessage(conversationID: conv, role: .assistant, content: "a\(i)",
                                                      createdAt: Date(timeIntervalSince1970: Double(2 * i + 1))))
        }
        let transport = MockTransport([
            .init(status: 200, body: anthropicToolResponse(name: "compact", input: #"{"summary":"S"}"#)),
            .init(status: 200, body: Self.sse(blocks: Self.textBlocks("ok"), stop: "end_turn")),
        ])
        let llm = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 50), transport: transport, sleep: { _ in })
        let session = ChatSession(store: store, llm: llm, tools: FakeTools(), prompts: try PromptLoader.bundled(), config: Config(),
                                  now: { Date(timeIntervalSince1970: 10_000) })
        _ = await drain(await session.send("next", quotes: []))
        let summaries = try await store.messages(conversationID: conv).filter { $0.role == .summary }
        #expect(summaries.count == 1, "no summary stored for letter \(letter); requests sent: \(transport.requests.count)")
    }

    /// A chat stream the user cancels mid-answer is billed at its worst case.
    @Test func cancelledStreamIsBilled() async throws {
        let store = try newStore()
        let llm = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 5), transport: HangingLines(), sleep: { _ in })
        let request = LLMRequest(model: "claude-sonnet-5-5", system: [], messages: [LLMMessage(role: .user, content: [.text("hi", cache: false)])],
                                 maxTokens: 16000, stage: .chat)
        let gotDelta = Mutex(false)
        let consumer = Task {
            for try await e in llm.stream(request) {
                if case .textDelta = e { gotDelta.withLock { $0 = true } }
            }
        }
        for _ in 0..<200 where !gotDelta.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(gotDelta.withLock { $0 })
        consumer.cancel()
        _ = await consumer.result
        var cost = 0.0
        for _ in 0..<200 where cost == 0 {
            try await Task.sleep(for: .milliseconds(10))
            cost = try await store.costSince(.distantPast)
        }
        #expect(cost >= 0.16, "cancelled stream left no llm_calls row")
    }
}

/// Streams `message_start` and one text delta, then hangs until cancelled (a long answer the user abandons).
final class HangingLines: HTTPLineStreamingTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.cannotConnectToHost) }

    func lines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        guard let url = request.url, let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else { throw URLError(.badURL) }
        let stream = AsyncThrowingStream<String, Error> { c in
            c.yield(#"data: {"type":"message_start","message":{"model":"claude-sonnet-5-5","usage":{"input_tokens":2000,"output_tokens":1}}}"#)
            c.yield(#"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
            c.yield(#"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#)
            let task = Task {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                c.finish(throwing: CancellationError())
            }
            c.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}
