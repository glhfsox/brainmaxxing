import DigestCore
import Foundation
import Observation

/// Which conversation the chat pane shows: one per digest date plus the general one.
enum ChatScope: Hashable {
    case digest(String)
    case general

    var digestDate: String? {
        if case let .digest(date) = self { return date }
        return nil
    }
}

/// A tool call in the transcript: one collapsed line, the result summary behind a disclosure.
struct ToolCallRow: Identifiable, Equatable {
    let id: Int
    var label: String
    /// nil while the call is running.
    var summary: String?
    var isError: Bool
}

/// The message in flight: shown under the stored history until `ChatSession` has persisted it.
struct PendingTurn: Equatable {
    var text: String
    var quotes: [Quote]
    var answer = ""
    var tools: [ToolCallRow] = []
}

/// Chat pane state on top of `DigestCore.ChatSession`. History comes from the store; a send streams
/// `ChatEvent`s into `pending[scope]`, then the history is reloaded. Errors stay inline per conversation.
@Observable @MainActor
final class ChatModel {
    /// Only models the cost meter can price; anything else would be refused by `AnthropicClient`.
    static let modelChoices = ModelPricing.table.keys.sorted()

    var store: Store?
    var config = Config()
    /// Where the key comes from (`AppModel.apiKey()`); the chat never reads the Keychain itself.
    var apiKeyProvider: (@MainActor () async throws -> String)?

    /// The open digest's date, if a digest is open; offered as the digest conversation.
    private(set) var digestDate: String?
    private(set) var scope: ChatScope = .general
    private(set) var messages: [ChatMessage] = []
    private(set) var pending: [ChatScope: PendingTurn] = [:]
    private(set) var errors: [ChatScope: String] = [:]

    var draft = ""
    /// Quotes waiting to be sent with the next message.
    var quotes: [Quote] = []
    /// Chosen in the pane for this app session; Settings holds the persistent default (`config.models.chat`).
    var modelOverride: String?

    var model: String {
        if let modelOverride { return modelOverride }
        return Self.modelChoices.contains(config.models.chat) ? config.models.chat : Config.Models().chat
    }

    var currentPending: PendingTurn? { pending[scope] }
    /// Stored history; while a turn is in flight its already-stored user message is left to the pending copy.
    var transcript: [ChatMessage] {
        guard let turn = pending[scope], let last = messages.last, last.role == .user,
              last.content == turn.text, last.quotes == turn.quotes else { return messages }
        return Array(messages.dropLast())
    }
    var currentError: String? { errors[scope] }
    /// An answer is being produced in some conversation (its usage is not recorded yet).
    var isSending: Bool { inFlight > 0 }
    var canSend: Bool {
        store != nil && pending[scope] == nil
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !quotes.isEmpty)
    }

    private let tools: MCPToolProvider
    private var followed = false
    private var sessions: [ChatScope: ChatSession] = [:]
    /// What the cached sessions and `llm` were built with; a new key, model or config drops them.
    private var sessionBasis: SessionBasis?
    /// Shared by every conversation, so the budget check sees all chat calls in flight.
    private var llm: AnthropicClient?
    private var costMeter: (meter: CostMeter, budget: Double)?
    private var inFlight = 0

    private struct SessionBasis: Equatable {
        var apiKey: String
        var config: Config
    }

    init() {
        let executable = MCPToolProvider.defaultExecutable()
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/DigestMCP")
        tools = MCPToolProvider(executable: executable)
    }

    // MARK: Scope

    /// Called when the open digest changes: the chat follows it (or falls back to General without a digest).
    func follow(digestDate date: String?) async {
        guard date != digestDate || !followed else { return }
        followed = true
        digestDate = date
        await show(date.map(ChatScope.digest) ?? .general)
    }

    func show(_ newScope: ChatScope) async {
        if newScope != scope {
            scope = newScope
            messages = []
        }
        await reloadHistory()
    }

    func reloadHistory() async {
        guard let store else { return }
        let scope = self.scope
        do {
            let id = try await store.conversation(forDigestDate: scope.digestDate)
            let loaded = try await store.messages(conversationID: id)
            guard self.scope == scope else { return }
            messages = loaded.filter { $0.role != .summary }
        } catch {
            errors[scope] = error.localizedDescription
        }
    }

    // MARK: Quotes

    func addQuote(_ quote: Quote) { quotes.append(quote) }

    func removeQuote(at index: Int) {
        guard quotes.indices.contains(index) else { return }
        quotes.remove(at: index)
    }

    func dismissError() { errors[scope] = nil }

    /// The digest list changed (new edition, finished run): sessions keep the digest they loaded first, so make each
    /// reload it before its next message.
    func digestsChanged() async {
        for session in sessions.values { await session.reloadDigest() }
    }

    /// Quit: stop the answers in flight.
    /// Cancels every in-flight answer; each send then ends with `.error(ChatSession.cancelledMessage)` after its
    /// estimated usage is recorded, so the quit path can wait on `isSending`.
    func cancelInFlight() {
        let running = Array(sessions.values)
        Task { for session in running { await session.cancel() } }
    }

    // MARK: Sending

    func send() {
        guard canSend, let store else { return }
        let scope = self.scope
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = self.quotes
        draft = ""
        self.quotes = []
        errors[scope] = nil
        pending[scope] = PendingTurn(text: text, quotes: quotes)
        inFlight += 1
        Task {
            defer { inFlight -= 1 }
            let session: ChatSession
            do {
                session = try await self.session(for: scope, store: store)
            } catch {
                // Nothing was sent: `finish` puts the draft and quotes back for another try.
                errors[scope] = APIKeyMessage.describe(error)
                await finish(scope)
                return
            }
            for await event in await session.send(text, quotes: quotes) {
                await apply(event, to: scope)
            }
        }
    }

    private func apply(_ event: ChatEvent, to scope: ChatScope) async {
        switch event {
        case let .delta(text):
            pending[scope]?.answer += text
        case let .toolCall(name, input):
            let id = pending[scope]?.tools.count ?? 0
            pending[scope]?.tools.append(ToolCallRow(id: id, label: ToolLabel.text(name: name, input: input), summary: nil, isError: false))
        case let .toolResult(_, summary, isError):
            if let i = pending[scope]?.tools.lastIndex(where: { $0.summary == nil }) {
                pending[scope]?.tools[i].summary = summary
                pending[scope]?.tools[i].isError = isError
            }
        case .done:
            await finish(scope)
        case let .error(message):
            errors[scope] = message
            await finish(scope)
        }
    }

    /// The turn is persisted (or failed): show the stored history instead of the pending copy.
    private func finish(_ scope: ChatScope) async {
        let turn = pending[scope]
        if self.scope == scope { await reloadHistory() }
        pending[scope] = nil
        // A failure before the user message was stored would lose the text; put it back if the composer is empty.
        if let turn, self.scope == scope, draft.isEmpty, quotes.isEmpty,
           !messages.contains(where: { $0.role == .user && $0.content == turn.text && $0.quotes == turn.quotes }) {
            draft = turn.text
            quotes = turn.quotes
        }
    }

    private func session(for scope: ChatScope, store: Store) async throws -> ChatSession {
        guard let apiKeyProvider else { throw LLMError.missingAPIKey }
        let apiKey = try await apiKeyProvider()
        var config = self.config
        config.models.chat = model
        let basis = SessionBasis(apiKey: apiKey, config: config)
        let llm: AnthropicClient
        if basis == sessionBasis, let shared = self.llm {
            llm = shared
        } else {
            sessions = [:]
            sessionBasis = basis
            llm = AnthropicClient(apiKey: apiKey, costMeter: meter(store: store, budget: config.dailyBudgetUsd))
            self.llm = llm
        }
        if let session = sessions[scope] { return session }
        let session = ChatSession(store: store, llm: llm, tools: tools, prompts: try PromptLoader.bundled(pins: config.promptPins),
                                  config: config, digestDate: scope.digestDate)
        sessions[scope] = session
        return session
    }

    /// One meter for all chat calls; replaced only when the budget changes.
    private func meter(store: Store, budget: Double) -> CostMeter {
        if let costMeter, costMeter.budget == budget { return costMeter.meter }
        let meter = CostMeter(store: store, dailyBudgetUSD: budget)
        costMeter = (meter, budget)
        return meter
    }

}

/// One line per tool call for the transcript ("searched arXiv: ...").
enum ToolLabel {
    static func text(name: String, input: JSONValue) -> String {
        let s = { (key: String) in input[key]?.stringValue ?? "?" }
        switch name {
        case "search_arxiv": return "searched arXiv: \(s("query"))"
        case "search_openalex": return "searched OpenAlex: \(s("query"))"
        case "search_digests": return "searched digests: \(s("query"))"
        case "get_paper": return "looked up \(s("id"))"
        case "get_fulltext": return "read full text of \(s("id"))"
        case "get_citations": return "\(input["direction"]?.stringValue == "cited_by" ? "citing papers" : "references") of \(s("id"))"
        case "get_digest": return "opened digest \(s("date"))"
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let args = (try? encoder.encode(input)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return "\(name) \(args)"
        }
    }
}

/// Assistant Markdown split into prose and fenced code: SwiftUI `Text` drops block structure from
/// `AttributedString(markdown:)`, so prose is parsed inline-only (newlines kept) and code is shown monospaced.
enum ChatMarkdown {
    enum Block: Equatable {
        case prose(String)
        case code(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var prose: [Substring] = [], code: [Substring] = []
        var inCode = false
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(.prose(joined)) }
            prose = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    out.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushProse()
                }
                inCode.toggle()
            } else if inCode {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inCode { out.append(.code(code.joined(separator: "\n"))) }     // still streaming the block
        flushProse()
        return out
    }

    static func attributed(_ prose: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var text = (try? AttributedString(markdown: prose, options: options)) ?? AttributedString(prose)
        // Model output is untrusted: only web links stay clickable (no file:, x-apple..., app URL schemes).
        let unsafe = text.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "") ? nil : run.range
        }
        for range in unsafe { text[range].link = nil }
        return text
    }
}

extension ToolCallRow {
    init(_ call: ChatToolCall, id: Int) {
        self.init(id: id, label: ToolLabel.text(name: call.name, input: call.input), summary: call.resultSummary, isError: call.isError)
    }
}
