import Foundation
import os

/// Swift mirror of `schemas/triage.json`.
public struct TriageItem: Codable, Sendable, Equatable {
    public var id: String
    public var oneLine: String
    public var tags: [String]
    public var score: Int

    public init(id: String, oneLine: String, tags: [String], score: Int) {
        self.id = id
        self.oneLine = oneLine
        self.tags = tags
        self.score = score
    }

    enum CodingKeys: String, CodingKey { case id, oneLine = "one_line", tags, score }
}

public struct TriageResult: Codable, Sendable, Equatable {
    public var results: [TriageItem]
    public init(results: [TriageItem]) { self.results = results }
}

public enum TriageError: LocalizedError, Equatable {
    case promptWithoutTool(String)

    public var errorDescription: String? {
        switch self {
        case let .promptWithoutTool(name): "prompt \(name) declares no tool_name/schema; triage needs both"
        }
    }
}

/// What the triage stage produced; everything in `scores` is already stored.
public struct TriageOutcome: Sendable {
    public var scores: [TriageScore] = []
    public var unscored = 0
    public var partial = false
    public var error: (any Error)?
}

/// Triage stage: batch -> Haiku call per batch -> validate -> store.
public enum Triage {
    public static let batchSize = 25
    public static let maxAuthors = 6
    public static let maxOutputTokens = Prompt.defaultMaxTokens
    public static let maxOneLine = 200
    public static let maxTags = 5
    public static let noFeedbackExamples = "(none yet)"
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "triage")

    /// Papers sorted by id ascending, in chunks of <= 25.
    public static func batches(_ papers: [RawPaper]) -> [[RawPaper]] {
        let sorted = papers.sorted { $0.id < $1.id }
        return stride(from: 0, to: sorted.count, by: batchSize).map { Array(sorted[$0..<min($0 + batchSize, sorted.count)]) }
    }

    /// The user turn: a JSON array with keys in fixed order `id, title, abstract, categories, authors`.
    public static func userTurnJSON(_ batch: [RawPaper]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func s(_ value: String) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
        func list(_ values: [String]) throws -> String { "[" + (try values.map(s)).joined(separator: ",") + "]" }

        let items = try batch.sorted { $0.id < $1.id }.map { p in
            var categories = p.categories
            if let primary = p.primaryCategory {
                categories = [primary] + categories.filter { $0 != primary }
            }
            let authors = p.authors.count > maxAuthors ? Array(p.authors.prefix(maxAuthors)) + ["et al."] : p.authors
            return "{\"id\":\(try s(p.id)),\"title\":\(try s(p.title)),\"abstract\":\(try s(p.abstract)),"
                + "\"categories\":\(try list(categories)),\"authors\":\(try list(authors))}"
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// `feedbackExamples` in the order given (the store's newest first); `(none yet)` when empty.
    public static func systemText(_ prompt: Prompt, config: Config, feedbackExamples: [FeedbackExample] = []) throws -> String {
        try prompt.render([
            "interest_profile": config.interestProfile,
            "feedback_examples": feedbackExamples.isEmpty ? noFeedbackExamples : feedbackExamples.map(\.line).joined(separator: "\n"),
            "language": config.language,
        ])
    }

    public static func request(batch: [RawPaper], prompt: Prompt, system: String, model: String) throws -> LLMRequest {
        guard let toolName = prompt.toolName, let schema = prompt.schema else { throw TriageError.promptWithoutTool(prompt.name) }
        return LLMRequest(
            model: model,
            system: [LLMTextBlock(text: system, cache: prompt.cacheBreakpoints.contains("system"))],
            messages: [LLMMessage(role: .user, content: [.text(try userTurnJSON(batch), cache: false)])],
            // strict: false - strict schemas reject minimum/maximum/maxLength; limits are enforced in `validate`.
            tools: [ToolDefinition(name: toolName, description: schema["description"]?.stringValue ?? "", inputSchema: schema, strict: false)],
            toolChoice: .tool(toolName), maxTokens: prompt.maxTokens ?? maxOutputTokens, stage: .triage,
            promptName: prompt.name, promptVersion: prompt.version, effort: prompt.effort)
    }

    /// Keeps one normalized item per input id (first wins); ids not in the batch are ignored.
    /// Returns the items in batch order plus the input ids the model left out.
    public static func validate(_ result: TriageResult, batch: [RawPaper]) -> (items: [TriageItem], missing: [String]) {
        var byID: [String: TriageItem] = [:]
        for item in result.results where byID[item.id] == nil { byID[item.id] = normalize(item) }
        var items: [TriageItem] = []
        var missing: [String] = []
        for p in batch {
            if let item = byID[p.id] { items.append(item) } else { missing.append(p.id) }
        }
        return (items, missing)
    }

    static func normalize(_ item: TriageItem) -> TriageItem {
        let oneLine = String(item.oneLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxOneLine))
        let tags = item.tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        return TriageItem(id: item.id, oneLine: oneLine, tags: Array(tags.prefix(maxTags)), score: min(10, max(0, item.score)))
    }

    /// The primary category (fallback: first category) most papers of the batch are in; ties go to the first seen.
    static func majorityCategory(_ batch: [RawPaper]) -> String? {
        mostFrequent(batch.compactMap { $0.primaryCategory ?? $0.categories.first }, limit: 1).first
    }

    /// The 3 most frequent tags of a scored batch joined with ", "; nil when it has none.
    static func topTags(_ items: [TriageItem]) -> String? {
        let tags = mostFrequent(items.flatMap(\.tags), limit: 3)
        return tags.isEmpty ? nil : tags.joined(separator: ", ")
    }

    /// Distinct values by count descending, ties in order of first appearance.
    private static func mostFrequent(_ values: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for v in values {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        return Array(order.enumerated().sorted { a, b in
            let (ca, cb) = (counts[a.element] ?? 0, counts[b.element] ?? 0)
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map(\.element).prefix(limit))
    }

    /// Top `topN` with `score >= minScore`; ties by `updated` desc, then id.
    public static func select(_ scored: [(paper: RawPaper, score: Int)], topN: Int, minScore: Int) -> [String] {
        scored.filter { $0.score >= minScore }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.paper.updated != b.paper.updated { return a.paper.updated > b.paper.updated }
                return a.paper.id < b.paper.id
            }
            .prefix(max(0, topN)).map(\.paper.id)
    }

    /// What one batch call came back with; computed in a child task, applied by the parent.
    enum BatchCall: Sendable {
        case scored(items: [TriageItem], missing: [String])
        case truncated
        case failed(any Error)
    }

    /// The child-task part of a batch: the call and validation, nothing that touches the store or the outcome.
    static func call(_ llm: LLMClient, _ request: LLMRequest, toolName: String, batch: [RawPaper]) async -> BatchCall {
        do {
            let response = try await llm.complete(request)
            if response.stopReason == "max_tokens" { return .truncated }
            let (items, missing) = validate(try response.toolInput(toolName, as: TriageResult.self), batch: batch)
            return .scored(items: items, missing: missing)
        } catch {
            return .failed(error)
        }
    }

    /// Runs the batches with at most `config.triageConcurrency` (clamped to 1...8) calls in flight. Batches go one at a
    /// time until a call returns a response, so that call writes the cached system prefix and the rest read it instead
    /// of each paying the cache write.
    /// Budget exhaustion and auth errors (401/403) stop scheduling with `partial = true`; batches already in flight
    /// finish and are stored. Another failed batch is skipped and recorded. A batch cut off by `max_tokens` is split in
    /// two and each half retried once; a half that is still cut off is counted as unscored. When the task is cancelled
    /// no new batch starts and late results are dropped; the outcome holds what was stored.
    /// Store writes and `outcome` changes happen in this task as results arrive; `scores` are sorted by paper id.
    /// `feedbackExamples` are read once by the caller and frozen for the run, so every batch shares the cached system prefix.
    /// `progress` gets one `.triage` report as each batch is launched; `done` is the number of scores stored so far, so it
    /// repeats when several batches launch together.
    public static func run(papers: [RawPaper], prompt: Prompt, config: Config, llm: LLMClient, store: Store, runID: String,
                           feedbackExamples: [FeedbackExample] = [],
                           progress: (@Sendable (RunProgress) async -> Void)? = nil) async throws -> TriageOutcome {
        var outcome = TriageOutcome()
        guard !papers.isEmpty else { return outcome }
        if prompt.model != config.models.triage {
            log.notice("triage prompt v\(prompt.version) was written for \(prompt.model, privacy: .public), config uses \(config.models.triage, privacy: .public)")
        }
        let system = try systemText(prompt, config: config, feedbackExamples: feedbackExamples)
        let concurrency = min(8, max(1, config.triageConcurrency))
        let toolName = prompt.toolName ?? ""
        var queue = batches(papers).map { (batch: $0, isHalf: false) }
        var next = 0
        var lastTheme: String?
        var warm = false     // a call has returned a response, so the system prefix is cached
        var stopped = false  // a fatal error or cancellation: no new batches

        func apply(_ batch: [RawPaper], isHalf: Bool, _ result: BatchCall) async throws {
            if Task.isCancelled {
                // A cancelled task cannot write to the store; what is stored so far is the outcome.
                stopped = true
                outcome.partial = true
                return
            }
            switch result {
            case .truncated:
                warm = true
                if !isHalf, batch.count > 1 {
                    log.warning("triage batch starting \(batch.first?.id ?? "", privacy: .public) hit max_tokens; splitting")
                    let mid = batch.count / 2
                    queue.insert(contentsOf: [(Array(batch[..<mid]), true), (Array(batch[mid...]), true)], at: next)
                } else {
                    log.warning("triage batch starting \(batch.first?.id ?? "", privacy: .public) hit max_tokens again; \(batch.count) papers unscored")
                    outcome.unscored += batch.count
                }
            case let .failed(error):
                if error is CancellationError {
                    stopped = true
                    outcome.partial = true
                } else if case let LLMError.budgetExceeded(spent, cap) = error {
                    log.warning("budget reached during triage; \(outcome.scores.count) papers scored")
                    stopped = true
                    outcome.partial = true
                    outcome.error = LLMError.budgetExceeded(spentUSD: spent, capUSD: cap)
                } else if let error = error as? LLMError, error.isAuthFailure {
                    // Every further call would fail the same way.
                    log.error("triage stopped: \(error.localizedDescription, privacy: .public)")
                    stopped = true
                    outcome.partial = true
                    outcome.error = error
                } else {
                    log.error("triage batch starting \(batch.first?.id ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                    outcome.partial = true
                    // Keep the error that stopped the stage, if any, over a later per-batch failure.
                    if !stopped { outcome.error = error }
                }
            case let .scored(items, missing):
                warm = true
                lastTheme = topTags(items)
                if !missing.isEmpty {
                    log.warning("model left \(missing.count) papers unscored: \(missing.joined(separator: ","), privacy: .public)")
                }
                let scores = items.map { TriageScore(paperID: $0.id, score: $0.score, oneLine: $0.oneLine, tags: $0.tags, promptVersion: prompt.version) }
                try await store.saveTriageScores(runID: runID, scores)
                outcome.scores += scores
                outcome.unscored += missing.count
            }
        }

        try await withThrowingTaskGroup(of: (batch: [RawPaper], isHalf: Bool, result: BatchCall).self) { group in
            var inFlight = 0
            while true {
                while !stopped, !Task.isCancelled, next < queue.count, inFlight < (warm ? concurrency : 1) {
                    let (batch, isHalf) = queue[next]
                    next += 1
                    await progress?(RunProgress(stage: .triage, done: outcome.scores.count, total: papers.count, topic: majorityCategory(batch),
                                                theme: lastTheme))
                    let request = try request(batch: batch, prompt: prompt, system: system, model: config.models.triage)
                    group.addTask { (batch, isHalf, await call(llm, request, toolName: toolName, batch: batch)) }
                    inFlight += 1
                }
                guard let done = try await group.next() else { break }
                inFlight -= 1
                try await apply(done.batch, isHalf: done.isHalf, done.result)
            }
        }
        if Task.isCancelled { outcome.partial = true }
        outcome.scores.sort { $0.paperID < $1.paperID }
        return outcome
    }
}

extension LLMError {
    /// HTTP 401 / 403: the key is wrong or lacks access; retrying other batches cannot help.
    var isAuthFailure: Bool {
        if case let .http(status, _, _) = self { return status == 401 || status == 403 }
        return false
    }
}
