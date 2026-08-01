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

    /// Runs all batches sequentially (the first call writes the cached system prefix, the rest read it).
    /// Budget exhaustion and auth errors (401/403) stop the stage with `partial = true`; another failed batch is
    /// skipped and recorded. A batch cut off by `max_tokens` is split in two and each half retried once; a half
    /// that is still cut off is counted as unscored.
    /// `feedbackExamples` are read once by the caller and frozen for the run, so every batch shares the cached system prefix.
    public static func run(papers: [RawPaper], prompt: Prompt, config: Config, llm: LLMClient, store: Store, runID: String,
                           feedbackExamples: [FeedbackExample] = []) async throws -> TriageOutcome {
        var outcome = TriageOutcome()
        guard !papers.isEmpty else { return outcome }
        if prompt.model != config.models.triage {
            log.notice("triage prompt v\(prompt.version) was written for \(prompt.model, privacy: .public), config uses \(config.models.triage, privacy: .public)")
        }
        let system = try systemText(prompt, config: config, feedbackExamples: feedbackExamples)
        var queue = batches(papers).map { (batch: $0, isHalf: false) }
        var next = 0
        while next < queue.count {
            let (batch, isHalf) = queue[next]
            next += 1
            let result: TriageResult
            do {
                let response = try await llm.complete(try request(batch: batch, prompt: prompt, system: system, model: config.models.triage))
                if response.stopReason == "max_tokens" {
                    if !isHalf, batch.count > 1 {
                        log.warning("triage batch starting \(batch.first?.id ?? "", privacy: .public) hit max_tokens; splitting")
                        let mid = batch.count / 2
                        queue.insert(contentsOf: [(Array(batch[..<mid]), true), (Array(batch[mid...]), true)], at: next)
                    } else {
                        log.warning("triage batch starting \(batch.first?.id ?? "", privacy: .public) hit max_tokens again; \(batch.count) papers unscored")
                        outcome.unscored += batch.count
                    }
                    continue
                }
                result = try response.toolInput(prompt.toolName ?? "", as: TriageResult.self)
            } catch LLMError.budgetExceeded(let spent, let cap) {
                log.warning("budget reached during triage; \(outcome.scores.count) papers scored")
                outcome.partial = true
                outcome.error = LLMError.budgetExceeded(spentUSD: spent, capUSD: cap)
                break
            } catch let error as LLMError where error.isAuthFailure {
                // Every further call would fail the same way.
                log.error("triage stopped: \(error.localizedDescription, privacy: .public)")
                outcome.partial = true
                outcome.error = error
                break
            } catch {
                log.error("triage batch starting \(batch.first?.id ?? "", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                outcome.partial = true
                outcome.error = error
                continue
            }
            let (items, missing) = validate(result, batch: batch)
            if !missing.isEmpty {
                log.warning("model left \(missing.count) papers unscored: \(missing.joined(separator: ","), privacy: .public)")
            }
            let scores = items.map { TriageScore(paperID: $0.id, score: $0.score, oneLine: $0.oneLine, tags: $0.tags, promptVersion: prompt.version) }
            try await store.saveTriageScores(runID: runID, scores)
            outcome.scores += scores
            outcome.unscored += missing.count
        }
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
