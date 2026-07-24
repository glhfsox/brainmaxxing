import Foundation
import os

/// Anthropic Messages API client. Every LLM call in brainmaxxing goes through here:
/// it asks `CostMeter` before sending and records usage into `llm_calls` after.
public struct AnthropicClient: LLMClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")
    public static let apiVersion = "2023-06-01"
    /// Requests with a larger `max_tokens` are streamed: long generations must not sit on one idle response.
    public static let streamingThreshold = 8192
    /// Per-request idle timeout; Opus with 64k output tokens can think for minutes before the first byte.
    public static let requestTimeout: TimeInterval = 900

    private let apiKey: String
    private let transport: HTTPTransport
    private let costMeter: CostMeter
    private let maxAttempts: Int
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "anthropic")

    public init(
        apiKey: String, costMeter: CostMeter, transport: HTTPTransport = URLSessionTransport.llm, maxAttempts: Int = 3,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.apiKey = apiKey
        self.costMeter = costMeter
        self.transport = transport
        self.maxAttempts = maxAttempts
        self.sleep = sleep
    }

    public func complete(_ request: LLMRequest) async throws -> LLMResponse {
        let body = try Self.encodeBody(request)
        // Conservative token estimate (~3 bytes per token) for the pre-call budget check.
        let reservation = try await costMeter.authorize(model: request.model, estimatedPromptTokens: body.count / 3,
                                                        maxOutputTokens: request.maxTokens)
        // Released only after the call is recorded (or failed unbilled), so concurrent callers never see neither.
        do {
            let response = try await send(request, body: body)
            await costMeter.release(reservation)
            return response
        } catch {
            await costMeter.release(reservation)
            throw error
        }
    }

    private func send(_ request: LLMRequest, body: Data) async throws -> LLMResponse {
        guard let endpoint = Self.endpoint else { throw LLMError.invalidResponse("bad endpoint URL") }
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = body

        var attempt = 0
        while true {
            attempt += 1
            let data: Data
            let http: HTTPURLResponse
            let streamed = request.maxTokens > Self.streamingThreshold
            do {
                (data, http) = try await transport.send(urlRequest)
            } catch {
                if streamed, Self.mayHaveBeenSent(error) {
                    try await recordEstimate(request, seen: nil, promptTokens: body.count / 3)
                }
                throw LLMError.transport(error.localizedDescription)
            }
            if http.statusCode < 400, streamed {
                // Bill first, then surface a mid-stream error or a cut-off stream.
                let stream = Self.parseStream(data)
                guard let usage = stream.usage else {
                    try await recordEstimate(request, seen: nil, promptTokens: body.count / 3)
                    throw LLMError.invalidResponse("stream has no message_start usage")
                }
                if case .failure = stream.result {
                    try await recordEstimate(request, seen: usage, promptTokens: body.count / 3)
                    return try stream.result.get()
                }
                let usd = try await costMeter.record(
                    usage: usage, model: request.model, stage: request.stage, promptName: request.promptName,
                    promptVersion: request.promptVersion, runID: RunContext.runID)
                Self.log.info("\(request.stage.rawValue, privacy: .public) streamed call: in \(usage.inputTokens) out \(usage.outputTokens) cache r/w \(usage.cacheReadTokens)/\(usage.cacheWriteTokens) $\(usd)")
                return try stream.result.get()
            }
            if http.statusCode < 400 {
                // Bill first: a 200 whose content blocks fail to decode was still paid for.
                let usage = try Self.decodeUsage(data)
                let usd = try await costMeter.record(
                    usage: usage, model: request.model, stage: request.stage, promptName: request.promptName,
                    promptVersion: request.promptVersion, runID: RunContext.runID)
                Self.log.info("\(request.stage.rawValue, privacy: .public) call: in \(usage.inputTokens) out \(usage.outputTokens) cache r/w \(usage.cacheReadTokens)/\(usage.cacheWriteTokens) $\(usd)")
                return try Self.decodeResponse(data)
            }
            let error = Self.decodeError(status: http.statusCode, data)
            let retryable = http.statusCode == 429 || http.statusCode == 529 || http.statusCode >= 500
            guard retryable, attempt < maxAttempts else { throw error }
            let backoff = pow(2.0, Double(attempt - 1))
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 0
            Self.log.warning("HTTP \(http.statusCode), retrying in \(max(backoff, retryAfter))s (attempt \(attempt))")
            try await sleep(max(backoff, retryAfter))
        }
    }

    // MARK: Failed streams

    /// Errors raised before any byte of the request left the machine; anything else may have reached the API.
    static func mayHaveBeenSent(_ error: Error) -> Bool {
        guard let url = error as? URLError else { return true }
        let neverSent: Set<URLError.Code> = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .badURL,
                                             .unsupportedURL, .internationalRoamingOff, .dataNotAllowed]
        return !neverSent.contains(url.code)
    }

    /// Worst case of a streamed call that failed after it was sent: the prompt as reported by `message_start` (else the
    /// byte estimate as uncached input) and `max_tokens` of output, recorded with `estimated = true`.
    static func estimatedUsage(seen: LLMUsage?, promptTokens: Int, maxTokens: Int) -> LLMUsage {
        var usage = seen ?? LLMUsage(inputTokens: promptTokens, outputTokens: 0)
        usage.outputTokens = max(usage.outputTokens, maxTokens)
        return usage
    }

    private func recordEstimate(_ request: LLMRequest, seen: LLMUsage?, promptTokens: Int) async throws {
        let usage = Self.estimatedUsage(seen: seen, promptTokens: promptTokens, maxTokens: request.maxTokens)
        let usd = try await costMeter.record(
            usage: usage, model: request.model, stage: request.stage, promptName: request.promptName,
            promptVersion: request.promptVersion, runID: RunContext.runID, estimated: true)
        Self.log.warning("\(request.stage.rawValue, privacy: .public) stream failed after sending; recorded worst case in \(usage.inputTokens) out \(usage.outputTokens) $\(usd)")
    }

    // MARK: Wire format

    /// Request body with sorted keys, so identical requests produce identical bytes (stable cache prefix).
    static func encodeBody(_ r: LLMRequest, stream: Bool = false) throws -> Data {
        var body: [String: JSONValue] = [
            "model": .string(r.model),
            "max_tokens": .number(Double(r.maxTokens)),
            "messages": .array(r.messages.map { m in
                .object(["role": .string(m.role.rawValue), "content": .array(m.content.map(encodeContent))])
            }),
        ]
        if stream || r.maxTokens > streamingThreshold { body["stream"] = .bool(true) }
        if let effort = r.effort { body["output_config"] = .object(["effort": .string(effort)]) }
        if !r.system.isEmpty {
            body["system"] = .array(r.system.map { textBlock($0.text, cache: $0.cache) })
        }
        if !r.tools.isEmpty {
            body["tools"] = .array(r.tools.map { t in
                var tool: [String: JSONValue] = ["name": .string(t.name), "input_schema": t.inputSchema, "strict": .bool(t.strict)]
                if !t.description.isEmpty { tool["description"] = .string(t.description) }
                return .object(tool)
            })
            switch r.toolChoice {
            case .auto: body["tool_choice"] = .object(["type": .string("auto")])
            case let .tool(name): body["tool_choice"] = .object(["type": .string("tool"), "name": .string(name)])
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSONValue.object(body))
    }

    private static func textBlock(_ text: String, cache: Bool) -> JSONValue {
        var block: [String: JSONValue] = ["type": .string("text"), "text": .string(text)]
        if cache { block["cache_control"] = .object(["type": .string("ephemeral")]) }
        return .object(block)
    }

    private static func encodeContent(_ c: MessageContent) -> JSONValue {
        switch c {
        case let .text(text, cache):
            textBlock(text, cache: cache)
        case let .toolUse(id, name, input):
            .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": input])
        case let .toolResult(id, content, isError):
            .object(["type": .string("tool_result"), "tool_use_id": .string(id), "content": .string(content), "is_error": .bool(isError)])
        case let .opaque(block):
            block
        }
    }

    private struct WireResponse: Decodable {
        struct Block: Decodable { let type: String; let text: String?; let id: String?; let name: String?; let input: JSONValue? }
        struct Usage: Decodable {
            let input_tokens: Int
            let output_tokens: Int
            let cache_creation_input_tokens: Int?
            let cache_read_input_tokens: Int?
        }
        let content: [Block]
        let stop_reason: String?
        let usage: Usage
        let model: String

        func llmUsage() -> LLMUsage {
            LLMUsage(inputTokens: usage.input_tokens, outputTokens: usage.output_tokens,
                     cacheReadTokens: usage.cache_read_input_tokens ?? 0, cacheWriteTokens: usage.cache_creation_input_tokens ?? 0)
        }
    }

    private struct WireUsageOnly: Decodable { let usage: WireResponse.Usage }

    /// Only the `usage` object of a success body, independent of the content blocks.
    static func decodeUsage(_ data: Data) throws -> LLMUsage {
        do {
            let u = try JSONDecoder().decode(WireUsageOnly.self, from: data).usage
            return LLMUsage(inputTokens: u.input_tokens, outputTokens: u.output_tokens,
                            cacheReadTokens: u.cache_read_input_tokens ?? 0, cacheWriteTokens: u.cache_creation_input_tokens ?? 0)
        } catch {
            throw LLMError.invalidResponse("no usage in response: \(error.localizedDescription)")
        }
    }

    static func decodeResponse(_ data: Data) throws -> LLMResponse {
        let wire: WireResponse
        do {
            wire = try JSONDecoder().decode(WireResponse.self, from: data)
        } catch {
            throw LLMError.invalidResponse(error.localizedDescription)
        }
        let content: [MessageContent] = wire.content.compactMap { b in
            switch b.type {
            case "text": b.text.map { .text($0, cache: false) }
            case "tool_use":
                if let id = b.id, let name = b.name { .toolUse(id: id, name: name, input: b.input ?? .object([:])) } else { nil }
            default: nil  // thinking and other block types are not used by callers
            }
        }
        return LLMResponse(content: content, stopReason: wire.stop_reason ?? "", usage: wire.llmUsage(), model: wire.model)
    }

    // MARK: Server-sent events

    /// Parses a complete SSE body (`message_start` ... `message_stop`). `usage` is whatever the stream reported
    /// (message_start, overridden by message_delta), available even when `result` is a failure so the call is billed.
    static func parseStream(_ data: Data) -> (usage: LLMUsage?, result: Result<LLMResponse, LLMError>) {
        var state = StreamState()
        var dataLines: [String] = []
        for rawLine in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine[...]
            if line.isEmpty {
                if !dataLines.isEmpty { state.handle(dataLines.joined(separator: "\n")) }
                dataLines = []
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        if !dataLines.isEmpty { state.handle(dataLines.joined(separator: "\n")) }
        return (state.usage, state.result())
    }

    private struct StreamState {
        enum Block { case text(String), tool(id: String, name: String, json: String, input: JSONValue?), other }
        var usage: LLMUsage?
        var model = ""
        var stopReason = ""
        var blocks: [Int: Block] = [:]
        var stopped = false
        var failure: LLMError?

        static func int(_ v: JSONValue?) -> Int? { if case let .number(n)? = v { Int(n) } else { nil } }

        mutating func applyUsage(_ u: JSONValue?) {
            guard let u, case .object = u else { return }
            var current = usage ?? LLMUsage(inputTokens: 0, outputTokens: 0)
            if let n = Self.int(u["input_tokens"]) { current.inputTokens = n }
            if let n = Self.int(u["output_tokens"]) { current.outputTokens = n }
            if let n = Self.int(u["cache_read_input_tokens"]) { current.cacheReadTokens = n }
            if let n = Self.int(u["cache_creation_input_tokens"]) { current.cacheWriteTokens = n }
            usage = current
        }

        mutating func handle(_ payload: String) {
            guard failure == nil, !stopped,
                  let event = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else { return }
            let index = Self.int(event["index"]) ?? 0
            switch event["type"]?.stringValue {
            case "message_start":
                model = event["message"]?["model"]?.stringValue ?? model
                applyUsage(event["message"]?["usage"])
            case "content_block_start":
                let block = event["content_block"]
                switch block?["type"]?.stringValue {
                case "text": blocks[index] = .text(block?["text"]?.stringValue ?? "")
                case "tool_use":
                    blocks[index] = .tool(id: block?["id"]?.stringValue ?? "", name: block?["name"]?.stringValue ?? "", json: "", input: nil)
                default: blocks[index] = .other  // thinking, redacted_thinking: not used by callers
                }
            case "content_block_delta":
                let delta = event["delta"]
                switch (blocks[index], delta?["type"]?.stringValue) {
                case let (.text(text)?, "text_delta"): blocks[index] = .text(text + (delta?["text"]?.stringValue ?? ""))
                case let (.tool(id, name, json, input)?, "input_json_delta"):
                    blocks[index] = .tool(id: id, name: name, json: json + (delta?["partial_json"]?.stringValue ?? ""), input: input)
                default: break
                }
            case "content_block_stop":
                // The accumulated partial_json is parsed once, here. A cut-off (max_tokens) object becomes `.null`;
                // callers check stop_reason first, and `toolInput` reports anything else.
                if case let .tool(id, name, json, _)? = blocks[index] {
                    let input: JSONValue = json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? .object([:]) : ((try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .null)
                    blocks[index] = .tool(id: id, name: name, json: json, input: input)
                }
            case "message_delta":
                if let reason = event["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
                applyUsage(event["usage"])
            case "message_stop":
                stopped = true
            case "error":
                failure = .streamError(type: event["error"]?["type"]?.stringValue, message: event["error"]?["message"]?.stringValue ?? "stream error")
            default: break  // ping
            }
        }

        func result() -> Result<LLMResponse, LLMError> {
            if let failure { return .failure(failure) }
            guard stopped, let usage else { return .failure(.invalidResponse("stream ended before message_stop")) }
            let content: [MessageContent] = blocks.keys.sorted().compactMap { i in
                switch blocks[i] {
                case let .text(text)?: .text(text, cache: false)
                case let .tool(id, name, _, input)?: .toolUse(id: id, name: name, input: input ?? .null)
                default: nil
                }
            }
            return .success(LLMResponse(content: content, stopReason: stopReason, usage: usage, model: model))
        }
    }

    private struct WireError: Decodable {
        struct Inner: Decodable { let type: String?; let message: String? }
        let error: Inner?
    }

    static func decodeError(status: Int, _ data: Data) -> LLMError {
        let wire = try? JSONDecoder().decode(WireError.self, from: data)
        return .http(status: status, type: wire?.error?.type, message: wire?.error?.message ?? String(decoding: data.prefix(300), as: UTF8.self))
    }
}

// MARK: Public streaming

extension AnthropicClient: LLMStreamingClient {
    /// Streams one call: text deltas as they arrive, each `tool_use` once its input is complete, then `.completed`.
    /// Budget is checked before sending; usage is recorded exactly once, also when the stream fails or is cancelled
    /// after `message_start`. HTTP 429 / 529 / 5xx before the first event are retried like `complete`.
    public func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(_ request: LLMRequest, emit: (LLMStreamEvent) -> Void) async throws {
        let body = try Self.encodeBody(request, stream: true)
        let reservation = try await costMeter.authorize(model: request.model, estimatedPromptTokens: body.count / 3,
                                                        maxOutputTokens: request.maxTokens)
        do {
            try await sendStream(request, body: body, emit: emit)
            await costMeter.release(reservation)
        } catch {
            await costMeter.release(reservation)
            throw error
        }
    }

    private func sendStream(_ request: LLMRequest, body: Data, emit: (LLMStreamEvent) -> Void) async throws {
        guard let endpoint = Self.endpoint else { throw LLMError.invalidResponse("bad endpoint URL") }
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.httpBody = body

        var attempt = 0
        while true {
            attempt += 1
            let lines: AsyncThrowingStream<String, Error>
            let http: HTTPURLResponse
            do {
                (lines, http) = try await openLines(urlRequest)
            } catch {
                if Self.mayHaveBeenSent(error) { try await recordEstimate(request, seen: nil, promptTokens: body.count / 3) }
                throw LLMError.transport(error.localizedDescription)
            }
            if http.statusCode < 400 {
                try await consume(lines, request: request, promptTokens: body.count / 3, emit: emit)
                return
            }
            var errorBody = ""
            for try await line in lines { errorBody += line + "\n" }
            let error = Self.decodeError(status: http.statusCode, Data(errorBody.utf8))
            let retryable = http.statusCode == 429 || http.statusCode == 529 || http.statusCode >= 500
            guard retryable, attempt < maxAttempts else { throw error }
            let backoff = pow(2.0, Double(attempt - 1))
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? 0
            Self.log.warning("HTTP \(http.statusCode), retrying stream in \(max(backoff, retryAfter))s (attempt \(attempt))")
            try await sleep(max(backoff, retryAfter))
        }
    }

    private func openLines(_ request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        if let streaming = transport as? HTTPLineStreamingTransport { return try await streaming.lines(request) }
        let (data, http) = try await transport.send(request)
        let all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return (AsyncThrowingStream { c in
            for line in all { c.yield(line) }
            c.finish()
        }, http)
    }

    /// Feeds each `data:` payload to the shared SSE state and emits events; bills the reported usage, or the worst case
    /// when the stream fails.
    private func consume(_ lines: AsyncThrowingStream<String, Error>, request: LLMRequest, promptTokens: Int,
                         emit: (LLMStreamEvent) -> Void) async throws {
        var state = StreamState()
        var thinking: [Int: [String: JSONValue]] = [:]
        var outcome: Result<LLMResponse, Error>
        do {
            for try await rawLine in lines {
                let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
                guard line.hasPrefix("data:") else { continue }
                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard let event = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)) else { continue }
                state.handle(payload)
                if let failure = state.failure { throw failure }
                let index = StreamState.int(event["index"]) ?? 0
                switch event["type"]?.stringValue {
                case "content_block_start":
                    if let block = event["content_block"], case let .object(fields) = block,
                       ["thinking", "redacted_thinking"].contains(block["type"]?.stringValue ?? "") {
                        thinking[index] = fields
                    }
                case "content_block_delta":
                    let delta = event["delta"]
                    switch delta?["type"]?.stringValue {
                    case "text_delta":
                        if let text = delta?["text"]?.stringValue, !text.isEmpty { emit(.textDelta(text)) }
                    case "thinking_delta":
                        let previous = thinking[index]?["thinking"]?.stringValue ?? ""
                        thinking[index]?["thinking"] = .string(previous + (delta?["thinking"]?.stringValue ?? ""))
                    case "signature_delta":
                        let previous = thinking[index]?["signature"]?.stringValue ?? ""
                        thinking[index]?["signature"] = .string(previous + (delta?["signature"]?.stringValue ?? ""))
                    default: break
                    }
                case "content_block_stop":
                    if case let .tool(id, name, _, input)? = state.blocks[index] { emit(.toolUse(id: id, name: name, input: input ?? .null)) }
                default: break
                }
            }
            switch state.result() {
            case let .success(r):
                // Rebuild in block order with the thinking blocks the shared parser leaves out.
                let content: [MessageContent] = state.blocks.keys.sorted().compactMap { i in
                    switch state.blocks[i] {
                    case let .text(text)?: .text(text, cache: false)
                    case let .tool(id, name, _, input)?: .toolUse(id: id, name: name, input: input ?? .null)
                    default: thinking[i].map { .opaque(.object($0)) }
                    }
                }
                outcome = .success(LLMResponse(content: content, stopReason: r.stopReason, usage: r.usage, model: r.model))
            case let .failure(e): outcome = .failure(e)
            }
        } catch {
            outcome = .failure(error)
        }
        if case .failure = outcome {
            try await recordEstimate(request, seen: state.usage, promptTokens: promptTokens)
        } else if let usage = state.usage {
            let usd = try await costMeter.record(
                usage: usage, model: request.model, stage: request.stage, promptName: request.promptName,
                promptVersion: request.promptVersion, runID: RunContext.runID)
            Self.log.info("\(request.stage.rawValue, privacy: .public) stream: in \(usage.inputTokens) out \(usage.outputTokens) cache r/w \(usage.cacheReadTokens)/\(usage.cacheWriteTokens) $\(usd)")
        }
        let response = try outcome.get()
        emit(.completed(response))
    }
}
