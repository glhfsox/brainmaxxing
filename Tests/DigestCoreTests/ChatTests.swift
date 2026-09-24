import Foundation
import Synchronization
import Testing
@testable import DigestCore

/// Scripted streaming LLM: each call gets the next response; text blocks are streamed as two deltas.
final class ScriptedLLM: LLMStreamingClient {
    private let state: Mutex<(script: [LLMResponse], requests: [LLMRequest])>
    private let fallback: LLMResponse?

    init(_ script: [LLMResponse], fallback: LLMResponse? = nil) {
        state = Mutex((script, []))
        self.fallback = fallback
    }

    var requests: [LLMRequest] { state.withLock { $0.requests } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let next: LLMResponse? = state.withLock { s in
            s.requests.append(request)
            return s.script.isEmpty ? fallback : s.script.removeFirst()
        }
        guard let next else { throw LLMError.invalidResponse("script exhausted") }
        return next
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { c in
            Task {
                do {
                    let r = try await self.complete(request)
                    for block in r.content {
                        switch block {
                        case let .text(t, _):
                            let mid = t.index(t.startIndex, offsetBy: t.count / 2)
                            c.yield(.textDelta(String(t[..<mid])))
                            c.yield(.textDelta(String(t[mid...])))
                        case let .toolUse(id, name, input): c.yield(.toolUse(id: id, name: name, input: input))
                        default: break
                        }
                    }
                    c.yield(.completed(r))
                    c.finish()
                } catch {
                    c.finish(throwing: error)
                }
            }
        }
    }
}

final class FakeTools: ToolProvider {
    private let calls = Mutex<[(String, JSONValue)]>([])
    var recorded: [(String, JSONValue)] { calls.withLock { $0 } }

    func listTools() async throws -> [ToolSpec] {
        [ToolSpec(name: "get_paper", description: "d", inputSchema: .object(["type": .string("object")]))]
    }

    func call(_ name: String, input: JSONValue) async throws -> ToolResult {
        calls.withLock { $0.append((name, input)) }
        return ToolResult(text: #"{"id":"2610.00001","title":"Sinks"}"#)
    }
}

func toolUseResponse(_ id: String = "toolu_1") -> LLMResponse {
    LLMResponse(content: [.opaque(.object(["type": .string("thinking"), "thinking": .string("t"), "signature": .string("sig")])),
                          .toolUse(id: id, name: "get_paper", input: .object(["id": .string("2610.00001")]))],
                stopReason: "tool_use", usage: LLMUsage(inputTokens: 10, outputTokens: 5), model: "claude-sonnet-5-5")
}

func textResponse(_ text: String) -> LLMResponse {
    LLMResponse(content: [.text(text, cache: false)], stopReason: "end_turn", usage: LLMUsage(inputTokens: 10, outputTokens: 5),
                model: "claude-sonnet-5-5")
}

@Suite struct ChatSessionTests {
    let date = "2026-10-22"

    func store(withDigest: Bool = true) async throws -> Store {
        let store = try Store(url: try TestSupport.tempDirectory().appendingPathComponent("digest.sqlite"))
        if withDigest {
            try await store.startRun(id: "r1", startedAt: Date(), force: true, since: nil, stages: .all)
            try await store.saveDigest(Digest(
                title: "Attention sinks day", summary: "s", clusters: [], papers: [], hfSection: [], trendNotes: "", date: date,
                runID: "r1", generatedAt: Date(timeIntervalSince1970: 1_800_000_000), partial: false, empty: false,
                counts: RunCounts(), promptVersion: 1, model: "claude-opus-5-5", costUSD: 1))
        }
        return store
    }

    func collect(_ stream: AsyncStream<ChatEvent>) async -> [ChatEvent] {
        var out: [ChatEvent] = []
        for await e in stream { out.append(e) }
        return out
    }

    @Test func toolUseThenTextStreamsEventsAndAppendsToolResult() async throws {
        let store = try await store()
        let llm = ScriptedLLM([toolUseResponse(), textResponse("Sinks are [2610.00001].")])
        let tools = FakeTools()
        let session = ChatSession(store: store, llm: llm, tools: tools, prompts: try PromptLoader.bundled(), config: Config(),
                                  digestDate: date)
        let quote = Quote(paperID: "2610.00001", title: "Sinks \"v2\"", clusterID: nil, text: "a sink token")
        let events = await collect(await session.send("why?", quotes: [quote]))

        #expect(events.count == 5)
        #expect(events[0] == .toolCall(name: "get_paper", input: .object(["id": .string("2610.00001")])))
        #expect(events[1] == .toolResult(name: "get_paper", summary: #"{"id":"2610.00001","title":"Sinks"}"#, isError: false))
        let deltas = events[2...3].compactMap { if case let .delta(d) = $0 { d } else { nil } }
        #expect(deltas.count == 2 && deltas.joined() == "Sinks are [2610.00001].")
        guard case let .done(message) = events[4] else { Issue.record("no done"); return }
        #expect(message.role == .assistant && message.content == "Sinks are [2610.00001].")
        #expect(message.toolCalls.map(\.name) == ["get_paper"])
        #expect(tools.recorded.count == 1)

        let requests = llm.requests
        #expect(requests.count == 2)
        // System: chat prompt + digest block, both cache-breakpointed.
        #expect(requests[0].system.count == 2 && requests[0].system.allSatisfy(\.cache))
        #expect(requests[0].system[1].text.hasPrefix("<digest date=\"2026-10-22\">"))
        #expect(requests[0].tools.map(\.name) == ["get_paper"] && requests[0].toolChoice == .auto)
        #expect(requests[0].model == "claude-sonnet-5-5" && requests[0].maxTokens == 16000 && requests[0].effort == nil)
        #expect(requests.allSatisfy { $0.stage == .chat })
        guard case let .text(userTurn, _)? = requests[0].messages.last?.content.first else { Issue.record("no user turn"); return }
        #expect(userTurn == "<quote paper=\"2610.00001\" title=\"Sinks &quot;v2&quot;\">a sink token</quote>\nwhy?")
        // Second request: assistant turn replayed with its thinking block, then the tool result.
        let second = requests[1].messages
        #expect(second.count == 3)
        #expect(second[1].role == .assistant && second[1].content == toolUseResponse().content)
        #expect(second[2].content == [.toolResult(toolUseId: "toolu_1", content: #"{"id":"2610.00001","title":"Sinks"}"#, isError: false)])

        let stored = try await store.messages(conversationID: "digest-\(date)")
        #expect(stored.map(\.role) == [.user, .assistant])
        #expect(stored[0].quotes == [quote])
    }

    /// The digest block holds every edition of the date (quotes may come from edition 1), and `reloadDigest()`
    /// picks up an edition written after the session loaded the block.
    @Test func digestBlockHasEveryEditionAndReloads() async throws {
        let store = try await store()
        func second(_ title: String, run: String) async throws {
            try await store.startRun(id: run, startedAt: Date(), force: true, since: nil, stages: .all)
            try await store.saveDigest(Digest(
                title: title, summary: "s", clusters: [], papers: [], hfSection: [], trendNotes: "", date: date, runID: run,
                generatedAt: Date(timeIntervalSince1970: 1_800_000_100), partial: false, empty: false, counts: RunCounts(),
                promptVersion: 1, model: "claude-opus-5-5", costUSD: 1))
        }
        try await second("Second edition", run: "r2")
        let llm = ScriptedLLM([textResponse("a"), textResponse("b"), textResponse("c")])
        let session = ChatSession(store: store, llm: llm, tools: FakeTools(), prompts: try PromptLoader.bundled(), config: Config(),
                                  digestDate: date)
        func editions(_ request: LLMRequest) throws -> [JSONValue] {
            let text = request.system[1].text
            #expect(text.hasPrefix("<digest date=\"\(date)\">\n") && text.hasSuffix("\n</digest>"))
            let body = text.split(separator: "\n").dropFirst().dropLast().joined(separator: "\n")
            guard case let .array(items) = try JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)) else { return [] }
            return items
        }
        _ = await collect(await session.send("one", quotes: []))
        let first = try editions(llm.requests[0])
        #expect(first.map { $0["edition"] } == [.number(1), .number(2)])
        #expect(first.map { $0["title"]?.stringValue } == ["Attention sinks day", "Second edition"])
        #expect(llm.requests[0].system.count == 2 && llm.requests[0].system[1].cache)

        try await second("Third edition", run: "r3")
        _ = await collect(await session.send("two", quotes: []))
        #expect(try editions(llm.requests[1]).count == 2)  // cached until reloaded
        await session.reloadDigest()
        _ = await collect(await session.send("three", quotes: []))
        #expect(try editions(llm.requests[2]).map { $0["title"]?.stringValue } == ["Attention sinks day", "Second edition", "Third edition"])
    }

    /// `cancel()` mid-stream: `.error(cancelled)` then the stream finishes; the user message and the streamed text
    /// stay stored; the stopped request is billed once at its estimate as chat. No-op when idle.
    @Test func cancelMidStreamEndsWithErrorAndBillsEstimate() async throws {
        let store = try await store(withDigest: false)
        let llm = AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 5), transport: HangingLines(), sleep: { _ in })
        let session = ChatSession(store: store, llm: llm, tools: FakeTools(), prompts: try PromptLoader.bundled(), config: Config())
        await session.cancel()  // idle: nothing happens
        var events: [ChatEvent] = []
        for await e in await session.send("long answer please", quotes: []) {
            events.append(e)
            if case .delta = e { await session.cancel() }
        }
        #expect(events == [.delta("Hel"), .error(ChatSession.cancelledMessage)])
        let stored = try await store.messages(conversationID: "general")
        #expect(stored.map(\.role) == [.user, .assistant] && stored.first?.content == "long answer please")
        #expect(stored.last?.content == "Hel")

        var days: [DailyCost] = []
        for _ in 0..<200 where days.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            days = try await store.dailyCosts(since: .distantPast)
        }
        #expect(days.map(\.calls).reduce(0, +) == 1)
        #expect(days.map(\.usd).reduce(0, +) > 0 && days.map(\.chatUSD).reduce(0, +) == days.map(\.usd).reduce(0, +))
    }

    @Test func toolRoundsAreCappedAtEight() async throws {
        let llm = ScriptedLLM([], fallback: toolUseResponse())
        let tools = FakeTools()
        let session = ChatSession(store: try await store(withDigest: false), llm: llm, tools: tools,
                                  prompts: try PromptLoader.bundled(), config: Config())
        let events = await collect(await session.send("loop", quotes: []))
        #expect(tools.recorded.count == ChatSession.maxToolRounds)
        #expect(llm.requests.count == ChatSession.maxToolRounds + 2)  // 8 tool rounds, the limit notice, the last answer
        #expect(llm.requests[0].system.count == 1)  // general conversation: no digest block
        guard case .done? = events.last else { Issue.record("expected done, got \(String(describing: events.last))"); return }
        guard case let .toolResult(_, content, isError)? = llm.requests.last?.messages.last?.content.first else { Issue.record("no limit notice"); return }
        #expect(isError && content.contains("limit"))
    }

    @Test func llmFailureEmitsErrorAndKeepsUserMessage() async throws {
        let store = try await store(withDigest: false)
        let session = ChatSession(store: store, llm: ScriptedLLM([]), tools: FakeTools(), prompts: try PromptLoader.bundled(), config: Config())
        let events = await collect(await session.send("hi", quotes: []))
        guard case .error? = events.last else { Issue.record("expected error"); return }
        #expect(try await store.messages(conversationID: "general").map(\.role) == [.user])
    }

    @Test func longHistoryIsCompactedKeepingLastTenTurns() async throws {
        let store = try await store()
        let conv = try await store.conversation(forDigestDate: date)
        let big = String(repeating: "x", count: 20_000)
        for i in 0..<15 {
            try await store.appendMessage(ChatMessage(conversationID: conv, role: .user, content: "q\(i) \(big)", createdAt: Date(timeIntervalSince1970: Double(2 * i))))
            try await store.appendMessage(ChatMessage(conversationID: conv, role: .assistant, content: "a\(i)", createdAt: Date(timeIntervalSince1970: Double(2 * i + 1))))
        }
        let compact = LLMResponse(content: [.toolUse(id: "c", name: "compact", input: .object(["summary": .string("S")]))],
                                  stopReason: "tool_use", usage: LLMUsage(inputTokens: 1, outputTokens: 1), model: "claude-haiku-5-5")
        let llm = ScriptedLLM([compact, textResponse("ok")])
        let session = ChatSession(store: store, llm: llm, tools: FakeTools(), prompts: try PromptLoader.bundled(), config: Config(),
                                  digestDate: date, now: { Date(timeIntervalSince1970: 1000) })
        _ = await collect(await session.send("next", quotes: []))

        let compactRequest = llm.requests[0]
        #expect(compactRequest.model == "claude-haiku-5-5" && compactRequest.toolChoice == .tool("compact"))
        guard case let .text(input, _)? = compactRequest.messages.first?.content.first else { Issue.record("no compact input"); return }
        #expect(input.hasPrefix("<conversation digest_date=\"2026-10-22\">\n<turn role=\"user\">q0 "))
        #expect(input.contains("<turn role=\"assistant\">a4</turn>") && !input.contains("a5<"))
        #expect(input.hasSuffix("Summarize the conversation above by calling the compact tool."))

        let chat = llm.requests[1].messages
        guard case let .text(first, _)? = chat.first?.content.first else { Issue.record("no summary turn"); return }
        #expect(first == "<conversation_summary>\nS\n</conversation_summary>")
        #expect(chat.filter { $0.role == .user }.count == 11)  // summary merged with turn 5, turns 6...14, the new one

        // On reload the summary still covers exactly turns 0...4.
        let (summary, verbatim) = ChatSession.effectiveHistory(try await store.messages(conversationID: conv))
        #expect(summary?.content == "S")
        #expect(verbatim.first?.content.hasPrefix("q5 ") == true && verbatim.last?.content == "ok")
    }

    /// Older turns over the compact input cap: the oldest part is summarized, the summary sits right before the turn
    /// `keptTurns` after the last summarized one, and everything not summarized is still replayed.
    @Test func oversizedBacklogIsCompactedOldestFirst() async throws {
        let store = try await store(withDigest: false)
        let conv = try await store.conversation(forDigestDate: nil)
        let big = String(repeating: "x", count: 20_000)
        for i in 0..<40 {
            try await store.appendMessage(ChatMessage(conversationID: conv, role: .user, content: "q\(i) \(big)", createdAt: Date(timeIntervalSince1970: Double(2 * i))))
            try await store.appendMessage(ChatMessage(conversationID: conv, role: .assistant, content: "a\(i)", createdAt: Date(timeIntervalSince1970: Double(2 * i + 1))))
        }
        let compact = LLMResponse(content: [.toolUse(id: "c", name: "compact", input: .object(["summary": .string("S")]))],
                                  stopReason: "tool_use", usage: LLMUsage(inputTokens: 1, outputTokens: 1), model: "claude-haiku-5-5")
        let llm = ScriptedLLM([compact, textResponse("ok")])
        let session = ChatSession(store: store, llm: llm, tools: FakeTools(), prompts: try PromptLoader.bundled(), config: Config(),
                                  now: { Date(timeIntervalSince1970: 1000) })
        _ = await collect(await session.send("next", quotes: []))

        guard case let .text(input, _)? = llm.requests[0].messages.first?.content.first else { Issue.record("no compact input"); return }
        #expect(input.utf8.count <= ChatSession.compactInputMaxBytes)
        #expect(input.contains("<turn role=\"assistant\">a8</turn>") && !input.contains("q9 "))
        let chat = llm.requests[1].messages
        guard case let .text(first, _)? = chat.first?.content.first else { Issue.record("no summary turn"); return }
        #expect(first == "<conversation_summary>\nS\n</conversation_summary>")
        #expect(chat.filter { $0.role == .user }.count == 32)  // summary merged with turn 9, turns 10...39, the new one

        let (summary, verbatim) = ChatSession.effectiveHistory(try await store.messages(conversationID: conv))
        #expect(summary?.content == "S")
        #expect(verbatim.first?.content.hasPrefix("q9 ") == true && verbatim.last?.content == "ok")
    }
}

@Suite struct AnthropicStreamTests {
    func client(_ responses: [MockTransport.Canned]) throws -> (AnthropicClient, Store) {
        let store = try Store(url: try TestSupport.tempDirectory().appendingPathComponent("digest.sqlite"))
        return (AnthropicClient(apiKey: "k", costMeter: CostMeter(store: store, dailyBudgetUSD: 10),
                                transport: MockTransport(responses), sleep: { _ in }), store)
    }

    let request = LLMRequest(model: "claude-opus-5-5", system: [], messages: [LLMMessage(role: .user, content: [.text("hi", cache: false)])],
                             maxTokens: 100, stage: .digest)

    @Test func streamsDeltasToolUseAndKeepsThinking() async throws {
        let sse = try TestSupport.fixture("anthropic/stream-tool-multichunk.sse")
        let (client, store) = try client([.init(status: 529, body: Data(#"{"error":{"type":"overloaded_error","message":"x"}}"#.utf8)),
                                          .init(status: 200, body: sse)])
        var deltas: [String] = []
        var tools: [String] = []
        var final: LLMResponse?
        for try await e in client.stream(request) {
            switch e {
            case let .textDelta(t): deltas.append(t)
            case let .toolUse(_, name, _): tools.append(name)
            case let .completed(r): final = r
            }
        }
        #expect(deltas == ["Calling the ", "tool."])
        #expect(tools == ["digest"])
        guard case let .opaque(thinking)? = final?.content.first else { Issue.record("thinking block missing"); return }
        #expect(thinking["signature"]?.stringValue == "c2lnbmF0dXJl" && thinking["thinking"]?.stringValue == "Two papers share a problem.")
        #expect(try await store.costSince(.distantPast) > 0)
        #expect(try AnthropicClient.encodeBody(request, stream: true).range(of: Data(#""stream":true"#.utf8)) != nil)
    }

    @Test func midStreamErrorIsThrownAfterBilling() async throws {
        let (client, store) = try client([.init(status: 200, body: try TestSupport.fixture("anthropic/stream-error.sse"))])
        await #expect(throws: LLMError.self) { for try await _ in client.stream(request) {} }
        // Worst case: 100 max_tokens of Opus output on top of the reported prompt.
        #expect(try await store.costSince(.distantPast) >= 100 * 20 / 1_000_000)
    }
}
