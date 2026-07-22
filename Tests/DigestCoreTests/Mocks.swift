import Foundation
import Synchronization
@testable import DigestCore

/// Canned HTTP responses, served in order; records every request.
final class MockTransport: HTTPTransport {
    struct Canned: Sendable { let status: Int; let body: Data; var headers: [String: String] = [:] }
    private let state: Mutex<(queue: [Canned], requests: [URLRequest])>

    init(_ responses: [Canned]) { state = Mutex((responses, [])) }

    var requests: [URLRequest] { state.withLock { $0.requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: Canned? = state.withLock { s in
            s.requests.append(request)
            return s.queue.isEmpty ? nil : s.queue.removeFirst()
        }
        guard let next, let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: next.status, httpVersion: nil, headerFields: next.headers)
        else { throw URLError(.cannotConnectToHost) }
        return (next.body, http)
    }
}

/// A fake clock whose `sleep` advances time instantly and records the requested durations.
final class FakeClock: Sendable {
    private let state: Mutex<(now: Date, sleeps: [TimeInterval])>
    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { state = Mutex((start, [])) }
    var now: Date { state.withLock { $0.now } }
    var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }
    func advance(_ s: TimeInterval) { state.withLock { $0.now.addTimeInterval(s) } }
    func sleep(_ s: TimeInterval) { state.withLock { $0.sleeps.append(s); $0.now.addTimeInterval(s) } }
}

/// Canned Anthropic success body with one tool_use block.
func anthropicToolResponse(name: String = "triage_result", input: String, usage: String = #"{"input_tokens":1000,"output_tokens":200,"cache_read_input_tokens":3000,"cache_creation_input_tokens":500}"#) -> Data {
    Data("""
    {"id":"msg_1","type":"message","role":"assistant","model":"claude-haiku-5-5","stop_reason":"tool_use",
     "content":[{"type":"tool_use","id":"toolu_1","name":"\(name)","input":\(input)}],"usage":\(usage)}
    """.utf8)
}

/// Mock LLM: answers each triage request by calling `respond` with the batch's ids; records requests.
final class MockLLM: LLMClient {
    private let state = Mutex<[LLMRequest]>([])
    private let respond: @Sendable (_ callIndex: Int, _ ids: [String]) throws -> TriageResult
    private let stopReason: @Sendable (_ ids: [String]) -> String

    init(stopReason: @escaping @Sendable (_ ids: [String]) -> String = { _ in "tool_use" },
         respond: @escaping @Sendable (_ callIndex: Int, _ ids: [String]) throws -> TriageResult) {
        self.respond = respond
        self.stopReason = stopReason
    }

    var requests: [LLMRequest] { state.withLock { $0 } }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let index = state.withLock { s in s.append(request); return s.count - 1 }
        guard case let .text(user, _)? = request.messages.first?.content.first,
              let batch = try JSONSerialization.jsonObject(with: Data(user.utf8)) as? [[String: Any]]
        else { throw LLMError.invalidResponse("mock: no batch") }
        let ids = batch.compactMap { $0["id"] as? String }
        let result = try respond(index, ids)
        let input = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(result))
        return LLMResponse(content: [.toolUse(id: "toolu_\(index)", name: "triage_result", input: input)], stopReason: stopReason(ids),
                           usage: LLMUsage(inputTokens: 100, outputTokens: 10), model: request.model)
    }
}

/// Deterministic fake scoring: score = last digit of the id.
func digitScore(_ id: String) -> Int { Int(String(id.suffix(1))) ?? 0 }

func scoreAll(_ ids: [String]) -> TriageResult {
    TriageResult(results: ids.map { TriageItem(id: $0, oneLine: "why \($0)", tags: ["Tag"], score: digitScore($0)) })
}

/// A temp prompt directory with a triage prompt ~ the real one's shape (system text from a file, even in tests).
func testTriagePromptDirectory() throws -> URL {
    let dir = try TestSupport.tempDirectory()
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("schemas"), withIntermediateDirectories: true)
    try Data(#"{"description":"Triage batch.","type":"object","properties":{"results":{"type":"array"}}}"#.utf8)
        .write(to: dir.appendingPathComponent("schemas/triage.json"))
    try Data("""
        ---
        name: triage
        version: 1
        model: claude-haiku-5-5
        schema: schemas/triage.json
        tool_name: triage_result
        cache_breakpoints: [system]
        placeholders: [interest_profile, feedback_examples, language]
        ---
        Reader: {{interest_profile}}
        Examples: {{feedback_examples}}
        Language: {{language}}
        """.utf8).write(to: dir.appendingPathComponent("triage.v1.md"))
    return dir
}

func testTriagePrompt() throws -> Prompt {
    try PromptLoader(directory: testTriagePromptDirectory()).load("triage")
}
