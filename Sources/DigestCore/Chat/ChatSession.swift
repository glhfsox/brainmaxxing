import Foundation
import os

/// One chat conversation (per digest date, or the general one) with the tool loop.
/// Messages are persisted through the `Store`; every LLM call goes through the given `LLMClient`
/// (`AnthropicClient` in the app, so it is metered). Sends are processed one at a time, in call order.
public actor ChatSession {
    public static let maxToolRounds = 8
    /// Compaction starts when the replayed history is estimated above this many tokens.
    public static let compactionThresholdTokens = 60_000
    public static let keptTurns = 10
    /// The `.error` text of a send stopped by `cancel()`.
    public static let cancelledMessage = "cancelled"
    /// Cap on the compact prompt's user turn, in UTF-8 bytes. `CostMeter` estimates a prompt as request bytes / 3 and
    /// refuses Haiku above its 100k-token flat-rate tier (300 KB of body); this leaves room for the system prompt,
    /// the tool schema and JSON escaping.
    static let compactInputMaxBytes = 200_000
    static let llmStage: Stage = .chat

    private let store: Store
    private let llm: LLMClient
    private let tools: ToolProvider
    private let prompts: PromptLoader
    private let config: Config
    private let digestDate: String?
    private let now: @Sendable () -> Date
    private var conversationID: String?
    private var digestBlock: String??
    private var queue: Task<Void, Never>?
    /// Every queued or running send, by id; `running` is the one inside `run`.
    private var sends: [UUID: Task<Void, Never>] = [:]
    private var running: UUID?
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "chat")

    /// `digestDate` selects the conversation (`nil` -> the general one) and the digest given to the model.
    public init(store: Store, llm: LLMClient, tools: ToolProvider, prompts: PromptLoader, config: Config,
                digestDate: String? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.llm = llm
        self.tools = tools
        self.prompts = prompts
        self.config = config
        self.digestDate = digestDate
        self.now = now
    }

    /// Stored messages of this conversation, oldest first (summaries included).
    public func history() async throws -> [ChatMessage] {
        try await store.messages(conversationID: try await conversation())
    }

    public func send(_ text: String, quotes: [Quote]) -> AsyncStream<ChatEvent> {
        let (stream, continuation) = AsyncStream<ChatEvent>.makeStream()
        let previous = queue
        let id = UUID()
        let task = Task {
            await previous?.value
            self.started(id)
            await self.run(text, quotes: quotes, emit: { continuation.yield($0) })
            self.finished(id)
            continuation.finish()
        }
        sends[id] = task
        queue = task
        return stream
    }

    /// Stops the send that is running: its stream ends with `.error(cancelledMessage)`; the user message and any
    /// text already streamed stay stored, and the client bills the stopped request at its estimate. Queued sends
    /// still run. No-op when idle.
    public func cancel() {
        guard let running else { return }
        sends[running]?.cancel()
    }

    private func started(_ id: UUID) { running = id }

    private func finished(_ id: UUID) {
        sends[id] = nil
        if running == id { running = nil }
    }

    // MARK: Loop

    private func run(_ text: String, quotes: [Quote], emit: (ChatEvent) -> Void) async {
        var answer = ""
        var calls: [ChatToolCall] = []
        var conversationID = ""
        do {
            conversationID = try await conversation()
            await tools.beginMessage()
            let prompt = try prompts.load("chat")
            var system = [LLMTextBlock(text: try prompt.render(["language": config.language]),
                                       cache: prompt.cacheBreakpoints.contains("system"))]
            if let digest = try await digestText() {
                system.append(LLMTextBlock(text: digest, cache: prompt.cacheBreakpoints.contains("digest")))
            }
            let stored = try await store.messages(conversationID: conversationID)
            let (summary, verbatim) = try await compactIfNeeded(stored, conversationID: conversationID)
            try await persist(ChatMessage(conversationID: conversationID, role: .user, content: text, quotes: quotes, createdAt: now()))
            var messages = Self.replay(summary: summary, verbatim: verbatim)
            messages.append(LLMMessage(role: .user, content: [.text(Self.userTurn(text, quotes: quotes), cache: true)]))
            messages = Self.mergingRoles(messages)

            let toolDefs: [ToolDefinition]
            do {
                toolDefs = try await tools.listTools().map {
                    ToolDefinition(name: $0.name, description: $0.description, inputSchema: $0.inputSchema, strict: false)
                }
            } catch {
                // The chat still works without tools; the prompt tells the model to say what it could not check.
                Self.log.error("tools unavailable: \(error.localizedDescription, privacy: .public)")
                toolDefs = []
            }

            var rounds = 0
            var model = config.models.chat
            while true {
                try Task.checkCancellation()  // cancelled during a tool call: no further request
                let request = LLMRequest(
                    model: config.models.chat, system: system, messages: messages, tools: toolDefs, toolChoice: .auto,
                    maxTokens: prompt.maxTokens ?? Prompt.defaultMaxTokens, stage: Self.llmStage,
                    promptName: prompt.name, promptVersion: prompt.version, effort: prompt.effort)
                let response = try await complete(request, separateFrom: answer) { delta in
                    answer += delta
                    emit(.delta(delta))
                }
                model = response.model.isEmpty ? model : response.model
                let uses = response.content.compactMap { block -> (id: String, name: String, input: JSONValue)? in
                    if case let .toolUse(id, name, input) = block { return (id, name, input) }
                    return nil
                }
                guard response.stopReason == "tool_use", !uses.isEmpty, rounds <= Self.maxToolRounds else { break }
                messages.append(LLMMessage(role: .assistant, content: response.content))
                var results: [MessageContent] = []
                for use in uses {
                    let result: ToolResult
                    if rounds == Self.maxToolRounds {
                        result = ToolResult(text: "Tool limit of \(Self.maxToolRounds) rounds reached for this message; "
                                            + "answer now with what you have.", isError: true)
                    } else {
                        emit(.toolCall(name: use.name, input: use.input))
                        do {
                            result = try await tools.call(use.name, input: use.input)
                        } catch {
                            result = ToolResult(text: "tool call failed: \(error.localizedDescription)", isError: true)
                        }
                        let summary = Self.summarize(result.text)
                        emit(.toolResult(name: use.name, summary: summary, isError: result.isError))
                        calls.append(ChatToolCall(name: use.name, input: use.input, resultSummary: summary, isError: result.isError))
                    }
                    results.append(.toolResult(toolUseId: use.id, content: result.text, isError: result.isError))
                }
                messages.append(LLMMessage(role: .user, content: results))
                rounds += 1
            }
            let saved = try await persist(ChatMessage(
                conversationID: conversationID, role: .assistant, content: answer, toolCalls: calls, model: model, createdAt: now()))
            emit(.done(saved))
        } catch {
            // A cancelled stream ends quietly (nil) or with whatever the transport throws; the task flag is the truth.
            let cancelled = Task.isCancelled
            Self.log.error("chat \(cancelled ? "cancelled" : "failed"): \(error.localizedDescription, privacy: .public)")
            if !conversationID.isEmpty, !(answer.isEmpty && calls.isEmpty) {
                // Keep what the user already saw.
                _ = try? await persist(ChatMessage(
                    conversationID: conversationID, role: .assistant, content: answer, toolCalls: calls,
                    model: config.models.chat, createdAt: now()))
            }
            emit(.error(cancelled ? Self.cancelledMessage : error.localizedDescription))
        }
    }

    /// Appends outside the send's task: GRDB refuses writes from a cancelled task, and a cancelled send must still
    /// keep the user message and the streamed text.
    @discardableResult
    private func persist(_ message: ChatMessage) async throws -> ChatMessage {
        let store = store
        return try await Task { try await store.appendMessage(message) }.value
    }

    /// Streams when the client can; otherwise one `complete` with its text as a single delta.
    /// Text of a later round is separated from earlier text by a blank line.
    private func complete(_ request: LLMRequest, separateFrom previous: String,
                          onDelta: (String) -> Void) async throws -> LLMResponse {
        var first = true
        func deliver(_ piece: String) {
            if first, !previous.isEmpty, !previous.hasSuffix("\n") { onDelta("\n\n") }
            first = false
            onDelta(piece)
        }
        guard let streaming = llm as? LLMStreamingClient else {
            let response = try await llm.complete(request)
            for case let .text(text, _) in response.content where !text.isEmpty { deliver(text) }
            return response
        }
        for try await event in streaming.stream(request) {
            switch event {
            case let .textDelta(text): deliver(text)
            case .toolUse: break
            case let .completed(response): return response
            }
        }
        throw LLMError.invalidResponse("stream ended without a completed message")
    }

    // MARK: Context

    private func conversation() async throws -> String {
        if let conversationID { return conversationID }
        let id = try await store.conversation(forDigestDate: digestDate)
        conversationID = id
        return id
    }

    /// Drops the cached digest block; the next message reloads every edition of the date from the store.
    /// Call it when the date's digests change (e.g. a new edition was written).
    public func reloadDigest() {
        digestBlock = nil
    }

    /// `<digest date="...">` + a JSON array of every edition of the date, oldest first, each with its `edition`;
    /// loaded once (until `reloadDigest()`); nil for the general conversation or a date without a digest.
    private func digestText() async throws -> String? {
        if let digestBlock { return digestBlock }
        var block: String?
        if let digestDate, let latest = try await store.digest(date: digestDate) {
            // Editions of a date are 1...N and never deleted, so the latest number lists them all.
            var editions: [EditionedDigest] = []
            for n in 1..<max(latest.edition, 1) {
                if let d = try await store.digest(date: digestDate, edition: n) { editions.append(EditionedDigest(digest: d)) }
            }
            editions.append(EditionedDigest(digest: latest))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            block = "<digest date=\"\(digestDate)\">\n\(String(decoding: try encoder.encode(editions), as: UTF8.self))\n</digest>"
        }
        digestBlock = .some(block)
        return block
    }

    /// The digest's JSON plus its `edition`, which is not part of `Digest`'s own encoding.
    private struct EditionedDigest: Encodable {
        let digest: Digest
        enum CodingKeys: String, CodingKey { case edition }
        func encode(to encoder: Encoder) throws {
            try digest.encode(to: encoder)
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(digest.edition, forKey: .edition)
        }
    }

    // MARK: History and compaction

    /// The latest summary and the messages replayed verbatim after it. A summary covers every earlier message
    /// except the last `keptTurns` turns before it, which stay verbatim.
    static func effectiveHistory(_ messages: [ChatMessage]) -> (summary: ChatMessage?, verbatim: [ChatMessage]) {
        guard let s = messages.lastIndex(where: { $0.role == .summary }) else { return (nil, messages) }
        let before = messages[..<s].filter { $0.role != .summary }
        return (messages[s], lastTurns(Array(before), keptTurns) + messages[(s + 1)...])
    }

    /// The suffix of `messages` that starts at the `n`-th last user message (all of it if there are fewer turns).
    static func lastTurns(_ messages: [ChatMessage], _ n: Int) -> [ChatMessage] {
        let starts = messages.indices.filter { messages[$0].role == .user }
        guard starts.count > n else { return messages }
        return Array(messages[starts[starts.count - n]...])
    }

    /// UTF-8 bytes / 3 over everything the history replays - the same estimate `CostMeter` applies to a request
    /// (Cyrillic is 2 bytes per character, so a character count would undercount Russian by half).
    static func estimatedTokens(summary: ChatMessage?, verbatim: [ChatMessage]) -> Int {
        let bytes = (summary?.content.utf8.count ?? 0) + verbatim.reduce(0) {
            $0 + $1.content.utf8.count + $1.quotes.reduce(0) { $0 + $1.text.utf8.count + $1.title.utf8.count + 40 }
        }
        return bytes / 3
    }

    /// The oldest turns of `older` whose compact input fits `compactInputMaxBytes` (at least one turn; a turn too big
    /// on its own is truncated by `compactInput`). `turns` is the number of whole turns taken.
    static func compactChunk(_ older: [ChatMessage], digestDate: String?, previous: String?) -> (messages: [ChatMessage], turns: Int) {
        let starts = older.indices.filter { older[$0].role == .user } + [older.endIndex]
        var size = compactInput(digestDate: digestDate, previous: previous, turns: []).utf8.count
        var taken = 0
        for t in 0..<(starts.count - 1) {
            let turnBytes = older[starts[t]..<starts[t + 1]].reduce(0) { $0 + renderTurn($1).utf8.count }
            if taken > 0, size + turnBytes > compactInputMaxBytes { break }
            size += turnBytes
            taken += 1
        }
        return (Array(older[..<starts[taken]]), taken)
    }

    /// Compacts the oldest verbatim turns into a new summary, one Haiku call per message: everything but the last
    /// `keptTurns` turns when that fits `compactInputMaxBytes`, otherwise the oldest part that does (the rest is
    /// compacted by later messages). A failure is logged and the history is replayed uncompacted.
    private func compactIfNeeded(_ stored: [ChatMessage], conversationID: String) async throws -> (ChatMessage?, [ChatMessage]) {
        let (summary, verbatim) = Self.effectiveHistory(stored)
        guard Self.estimatedTokens(summary: summary, verbatim: verbatim) > Self.compactionThresholdTokens else { return (summary, verbatim) }
        let starts = verbatim.indices.filter { verbatim[$0].role == .user }
        guard starts.count > Self.keptTurns else { return (summary, verbatim) }
        let older = Array(verbatim[..<starts[starts.count - Self.keptTurns]])
        let chunk = Self.compactChunk(older, digestDate: digestDate, previous: summary?.content)
        // A summary covers everything before it except the last `keptTurns` turns (see `effectiveHistory`), so a summary
        // of only the first `chunk.turns` turns sits right before turn `chunk.turns + keptTurns`.
        let partial = chunk.messages.count < older.count
        let summaryDate = partial ? verbatim[starts[chunk.turns + Self.keptTurns] - 1].createdAt : now()
        do {
            let prompt = try prompts.load("compact")
            guard let toolName = prompt.toolName, let schema = prompt.schema else { throw PromptError.notFound("compact tool") }
            let input = Self.compactInput(digestDate: digestDate, previous: summary?.content, turns: chunk.messages)
            let response = try await llm.complete(LLMRequest(
                model: prompt.model, system: [LLMTextBlock(text: try prompt.render(["language": config.language]))],
                messages: [LLMMessage(role: .user, content: [.text(input, cache: false)])],
                tools: [ToolDefinition(name: toolName, description: schema["description"]?.stringValue ?? "", inputSchema: schema, strict: true)],
                toolChoice: .tool(toolName), maxTokens: prompt.maxTokens ?? Prompt.defaultMaxTokens, stage: Self.llmStage,
                promptName: prompt.name, promptVersion: prompt.version, effort: prompt.effort))
            let output = try response.toolInput(toolName, as: CompactToolOutput.self)
            let saved = try await store.appendMessage(ChatMessage(
                conversationID: conversationID, role: .summary, content: output.summary, model: response.model, createdAt: summaryDate))
            if partial {
                Self.log.notice("compacted the oldest \(chunk.turns) of \(starts.count - Self.keptTurns) older turns; the rest on a later message")
            }
            return (saved, Array(verbatim[starts[chunk.turns]...]))
        } catch {
            // Not fatal: the next message tries again; the full history still fits Sonnet's context for a while.
            Self.log.error("compaction of \(chunk.messages.count) messages failed: \(String(describing: error), privacy: .public)")
            return (summary, verbatim)
        }
    }

    /// The compact prompt's input format (PROMPTS.md, compact v1). A message too long for `compactInputMaxBytes`
    /// on its own is cut.
    static func compactInput(digestDate: String?, previous: String?, turns: [ChatMessage]) -> String {
        var out = "<conversation digest_date=\"\(digestDate ?? "")\">\n"
        if let previous { out += "<previous_summary>\(previous)</previous_summary>\n" }
        let room = compactInputMaxBytes - out.utf8.count - 1_000
        for m in turns { out += renderTurn(m, maxBytes: room) }
        return out + "</conversation>\n\nSummarize the conversation above by calling the compact tool."
    }

    /// One `<turn>` element of the compact input (empty for summaries); the body is cut to about `maxBytes`.
    static func renderTurn(_ m: ChatMessage, maxBytes: Int = .max) -> String {
        var body: String
        switch m.role {
        case .summary: return ""
        case .user: body = userTurn(m.content, quotes: m.quotes)
        default:
            body = m.content
            for c in m.toolCalls {
                let input = (try? String(decoding: JSONEncoder().encode(c.input), as: UTF8.self)) ?? "{}"
                body += "\n<tool_call name=\"\(attr(c.name))\" error=\"\(c.isError)\"><input>\(input)</input><result>\(c.resultSummary)</result></tool_call>"
            }
        }
        if body.utf8.count > maxBytes {
            // A String subscript rounds a UTF-8 index down to a character boundary.
            body = String(body[..<body.utf8.index(body.startIndex, offsetBy: max(maxBytes - 100, 0))]) + "... [cut]"
        }
        return "<turn role=\"\(m.role == .user ? "user" : "assistant")\">\(body)</turn>\n"
    }

    /// History as API messages: the summary as a `<conversation_summary>` user turn, then the verbatim turns.
    static func replay(summary: ChatMessage?, verbatim: [ChatMessage]) -> [LLMMessage] {
        var out: [LLMMessage] = []
        if let summary {
            out.append(LLMMessage(role: .user, content: [.text("<conversation_summary>\n\(summary.content)\n</conversation_summary>", cache: false)]))
        }
        for m in verbatim {
            switch m.role {
            case .user: out.append(LLMMessage(role: .user, content: [.text(userTurn(m.content, quotes: m.quotes), cache: false)]))
            case .assistant where !m.content.isEmpty: out.append(LLMMessage(role: .assistant, content: [.text(m.content, cache: false)]))
            default: break
            }
        }
        return out
    }

    /// Joins consecutive same-role messages and drops leading assistant turns (the API wants user first, alternating).
    static func mergingRoles(_ messages: [LLMMessage]) -> [LLMMessage] {
        var out: [LLMMessage] = []
        for m in messages {
            if out.isEmpty, m.role == .assistant { continue }
            if let last = out.last, last.role == m.role {
                out[out.count - 1].content += m.content
            } else {
                out.append(m)
            }
        }
        return out
    }

    /// Quotes first, as `<quote paper="ID" title="...">text</quote>`, then the user's text.
    static func userTurn(_ text: String, quotes: [Quote]) -> String {
        let tags = quotes.map { q in
            let body = q.text.replacingOccurrences(of: "</quote>", with: "&lt;/quote>")
            return "<quote paper=\"\(attr(q.paperID))\" title=\"\(attr(q.title))\">\(body)</quote>"
        }
        return (tags + (text.isEmpty ? [] : [text])).joined(separator: "\n")
    }

    static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    /// One line, <= 200 characters, for the UI and the stored tool call.
    static func summarize(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count <= 200 ? line : String(line.prefix(199)) + "…"
    }
}
