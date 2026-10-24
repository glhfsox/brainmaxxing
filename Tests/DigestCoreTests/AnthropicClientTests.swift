import Foundation
import Testing
@testable import DigestCore

@Suite struct AnthropicClientTests {
    static let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["x": .object(["type": .string("integer")])])])

    func request(system: String = "You are a triage model. Profile: X.", user: String = "[]") -> LLMRequest {
        LLMRequest(
            model: "claude-haiku-5-5", system: [LLMTextBlock(text: system, cache: true)],
            messages: [LLMMessage(role: .user, content: [.text(user, cache: false)])],
            tools: [ToolDefinition(name: "triage_result", description: "Score papers.", inputSchema: Self.schema, strict: false)],
            toolChoice: .tool("triage_result"), maxTokens: 4096, stage: .triage, promptName: "triage", promptVersion: 1)
    }

    func makeClient(_ responses: [MockTransport.Canned], budget: Double = 4) throws -> (AnthropicClient, MockTransport, Store) {
        let store = try tempStore()
        let transport = MockTransport(responses)
        let client = AnthropicClient(apiKey: "test-key", costMeter: CostMeter(store: store, dailyBudgetUSD: budget),
                                     transport: transport, sleep: { _ in })
        return (client, transport, store)
    }

    func json(_ data: Data?) throws -> [String: Any] {
        let bytes = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    @Test func requestHasCacheControlAndForcedTool() async throws {
        let (client, transport, _) = try makeClient([.init(status: 200, body: anthropicToolResponse(input: #"{"x":1}"#))])
        _ = try await client.complete(request())
        let sent = try #require(transport.requests.first)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "test-key")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try json(sent.httpBody)
        let system = try #require(body["system"] as? [[String: Any]])
        #expect((system.last?["cache_control"] as? [String: String]) == ["type": "ephemeral"])
        #expect((body["tool_choice"] as? [String: String]) == ["type": "tool", "name": "triage_result"])
        let tool = try #require((body["tools"] as? [[String: Any]])?.first)
        #expect(tool["strict"] as? Bool == false)
        #expect(tool["description"] as? String == "Score papers.")
        #expect(body["temperature"] == nil)
        #expect(body["thinking"] == nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let firstBlock = try #require((messages.first?["content"] as? [[String: Any]])?.first)
        #expect(firstBlock["cache_control"] == nil)
    }

    @Test func sameSystemPrefixSendsIdenticalBytes() throws {
        func systemAndTools(_ data: Data) throws -> Data {
            // With sorted keys, "system" ... "tools" precede nothing volatile; slice from "system" to the end.
            let text = String(decoding: data, as: UTF8.self)
            let range = try #require(text.range(of: #""system":"#))
            return Data(text[range.lowerBound...].utf8)
        }
        let a = try AnthropicClient.encodeBody(request(user: #"[{"id":"1"}]"#))
        let b = try AnthropicClient.encodeBody(request(user: #"[{"id":"2"}]"#))
        #expect(a != b)
        #expect(try systemAndTools(a) == systemAndTools(b))
        #expect(try AnthropicClient.encodeBody(request()) == AnthropicClient.encodeBody(request()))
    }

    @Test func usageParsedAndRecorded() async throws {
        let (client, _, store) = try makeClient([.init(status: 200, body: anthropicToolResponse(input: #"{"x":7}"#))])
        try await store.startRun(id: "run-a", startedAt: Date(), force: true, since: nil, stages: .all)
        let response = try await RunContext.$runID.withValue("run-a") { try await client.complete(request()) }
        #expect(response.usage == LLMUsage(inputTokens: 1000, outputTokens: 200, cacheReadTokens: 3000, cacheWriteTokens: 500))
        struct Out: Decodable { let x: Int }
        #expect(try response.toolInput("triage_result", as: Out.self).x == 7)
        let calls = try await store.llmCalls(runID: "run-a")
        #expect(calls.count == 1)
        // 1000x0.10 + 200x0.50 + 3000x0.01 + 500x0.125 per 1M
        #expect(abs((calls.first?.usdEstimate ?? 0) - 0.0002925) < 1e-12)
        #expect(calls.first?.promptName == "triage")
        #expect(calls.first?.stage == .triage)
    }

    @Test func budgetExceededNeverCallsTransport() async throws {
        let (client, transport, store) = try makeClient([.init(status: 200, body: anthropicToolResponse(input: "{}"))], budget: 1.0)
        try await store.recordLLMCall(LLMCallRecord(runID: nil, stage: .triage, model: "claude-haiku-5-5", promptName: nil, promptVersion: nil,
                                                    usage: LLMUsage(inputTokens: 0, outputTokens: 0), usdEstimate: 1.0, createdAt: Date()))
        await #expect(throws: LLMError.budgetExceeded(spentUSD: 1.0, capUSD: 1.0)) { try await client.complete(request()) }
        #expect(transport.requests.isEmpty)
    }

    @Test func unknownModelRefused() async throws {
        let (client, transport, _) = try makeClient([])
        var r = request()
        r.model = "claude-mystery-1"
        await #expect(throws: LLMError.unknownModelPricing("claude-mystery-1")) { try await client.complete(r) }
        #expect(transport.requests.isEmpty)
    }

    @Test func retries429ButNot400() async throws {
        let rateLimited = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8)
        let (client, transport, _) = try makeClient([
            .init(status: 429, body: rateLimited), .init(status: 529, body: Data("{}".utf8)),
            .init(status: 200, body: anthropicToolResponse(input: "{}")),
        ])
        _ = try await client.complete(request())
        #expect(transport.requests.count == 3)

        let bad = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"nope"}}"#.utf8)
        let (client2, transport2, _) = try makeClient([.init(status: 400, body: bad), .init(status: 200, body: anthropicToolResponse(input: "{}"))])
        await #expect(throws: LLMError.http(status: 400, type: "invalid_request_error", message: "nope")) { try await client2.complete(request()) }
        #expect(transport2.requests.count == 1)

        let (client3, transport3, _) = try makeClient(Array(repeating: .init(status: 500, body: Data()), count: 5))
        await #expect(throws: LLMError.self) { try await client3.complete(request()) }
        #expect(transport3.requests.count == 3)
    }

    @Test func missingKeyResolution() throws {
        #expect(throws: LLMError.missingAPIKey) { try KeychainStore.resolveAnthropicKey(environment: [:], keychain: { _ in nil }) }
        #expect(try KeychainStore.resolveAnthropicKey(environment: ["ANTHROPIC_API_KEY": "env"], keychain: { _ in "kc" }) == "env")
        #expect(try KeychainStore.resolveAnthropicKey(environment: [:], keychain: { _ in "kc" }) == "kc")
        // The env var wins in both modes; a Keychain item needing a dialog fails fast in non-interactive mode.
        let denied: (String) throws -> String? = { _ in throw LLMError.keychainInteractionRequired }
        #expect(try KeychainStore.resolveAnthropicKey(mode: .nonInteractive, environment: ["ANTHROPIC_API_KEY": "env"], keychain: denied) == "env")
        #expect(throws: LLMError.keychainInteractionRequired) {
            try KeychainStore.resolveAnthropicKey(mode: .nonInteractive, environment: [:], keychain: denied)
        }
        // A denied interactive read is not "no key": the error reaches the caller unchanged, and the env var still wins.
        let refused: (String) throws -> String? = { _ in throw LLMError.keychainAccessDenied }
        #expect(throws: LLMError.keychainAccessDenied) { try KeychainStore.resolveAnthropicKey(environment: [:], keychain: refused) }
        #expect(try KeychainStore.resolveAnthropicKey(environment: ["ANTHROPIC_API_KEY": "env"], keychain: refused) == "env")
    }

    @Test func usageIsRecordedEvenWhenContentFailsToDecode() async throws {
        let body = Data(#"{"model":"claude-haiku-5-5","stop_reason":"tool_use","content":"not-an-array","usage":{"input_tokens":1000,"output_tokens":200}}"#.utf8)
        let (client, _, store) = try makeClient([.init(status: 200, body: body)])
        try await store.startRun(id: "run-b", startedAt: Date(), force: true, since: nil, stages: .all)
        await #expect(throws: LLMError.self) {
            try await RunContext.$runID.withValue("run-b") { try await client.complete(request()) }
        }
        let calls = try await store.llmCalls(runID: "run-b")
        #expect(calls.count == 1)
        #expect(calls.first?.usage == LLMUsage(inputTokens: 1000, outputTokens: 200))
    }
}
