import Foundation
import os

public enum DigestError: LocalizedError, Equatable {
    case promptWithoutTool(String)
    /// The model answered without calling the digest tool, twice.
    case noToolCall
    /// `stop_reason == "max_tokens"`: lower `top_n` or raise `max_tokens` in a new prompt version.
    case outputTruncated

    public var errorDescription: String? {
        switch self {
        case let .promptWithoutTool(name): "prompt \(name) declares no tool_name/schema; the digest needs both"
        case .noToolCall: "the model did not call the digest tool (after one retry)"
        case .outputTruncated: "the digest output hit max_tokens and was cut off; lower top_n or raise max_tokens in a new prompt version"
        }
    }
}

/// One selected paper as the bundle presents it.
public struct BundlePaper: Sendable, Equatable {
    public var ranked: RankedPaper
    /// Already truncated to `fulltext_max_chars`; nil -> `fulltext="none"`.
    public var fullText: String?
    public var source: FullTextSource?
    public var figures: [Figure]

    public init(ranked: RankedPaper, fullText: String?, source: FullTextSource?, figures: [Figure]) {
        self.ranked = ranked
        self.fullText = fullText
        self.source = source
        self.figures = figures
    }
}

/// Digest stage: bundle -> one Opus call via the `digest` tool -> validated, normalized `Digest`.
public enum DigestWriter {
    public static let maxAuthors = 6
    // The user-turn strings are fixed (like triage's JSON user turn); the system prompt is the prompt file.
    public static let instruction = "Write today's digest from the bundle above by calling the digest tool."
    public static let retryInstruction = "Call the digest tool now; no prose."
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "digest")

    // MARK: Bundle

    /// Deterministic bytes: same inputs -> same string, so the cached prefix is reused on a re-run. `hfPapers` in the order
    /// kept (upvotes desc), `(none)` when empty.
    public static func bundle(date: String, partial: Bool, recentClusters: [String], papers: [BundlePaper], hfPapers: [HFDailyPaper] = []) -> String {
        var out = "<run date=\"\(attr(date))\" selected=\"\(papers.count)\" partial=\"\(partial)\">\n"
        out += "<recent_clusters>\n\(recentClusters.isEmpty ? "(none yet)" : recentClusters.joined(separator: "\n"))\n</recent_clusters>\n"
        out += "<papers>\n"
        for (i, p) in papers.enumerated() {
            let paper = p.ranked.paper
            let text = p.fullText.flatMap { p.source == nil ? nil : $0 }
            let authors = paper.authors.count > maxAuthors
                ? paper.authors.prefix(maxAuthors).joined(separator: ", ") + " et al." : paper.authors.joined(separator: ", ")
            out += "<paper id=\"\(attr(paper.id))\" rank=\"\(p.ranked.rank ?? i + 1)\" score=\"\(p.ranked.score)\""
                + " tags=\"\(attr(p.ranked.tags.joined(separator: ", ")))\""
                + " primary_category=\"\(attr(paper.primaryCategory ?? paper.categories.first ?? ""))\""
                + (paper.venue.map { " venue=\"\(attr($0))\"" } ?? "")
                + " fulltext=\"\(text == nil ? "none" : p.source?.rawValue ?? "none")\" chars=\"\(text?.count ?? 0)\">\n"
            out += "<title>\(paper.title)</title>\n"
            out += "<authors>\(authors)</authors>\n"
            out += "<published>\(utcDay(paper.published))</published>\n"
            out += "<triage>\(p.ranked.oneLine)</triage>\n"
            out += "<abstract>\(paper.abstract)</abstract>\n"
            out += "<figures>\n"
            if text != nil {
                for f in p.figures { out += "<figure index=\"\(f.index)\">\(f.caption)</figure>\n" }
            }
            out += "</figures>\n"
            if let text { out += "<fulltext>\n\(text)\n</fulltext>\n" }
            out += "</paper>\n"
        }
        out += "</papers>\n<hf_papers>\n"
        if hfPapers.isEmpty { out += "(none)\n" }
        for p in hfPapers {
            out += "<hf_paper id=\"\(attr(p.arxivID))\" upvotes=\"\(p.upvotes)\">\n<title>\(p.title)</title>\n<summary>\(p.summary)</summary>\n</hf_paper>\n"
        }
        out += "</hf_papers>\n</run>"
        return out
    }

    private static func attr(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return LocalDate.string(date, calendar: calendar)
    }

    // MARK: Call

    public static func systemText(_ prompt: Prompt, config: Config) throws -> String {
        try prompt.render([
            "interest_profile": config.interestProfile,
            "language": config.language,
            "explanation_level": config.explanationLevel,
        ])
    }

    public static func request(prompt: Prompt, system: String, bundle: String, model: String) throws -> LLMRequest {
        guard let toolName = prompt.toolName, let schema = prompt.schema else { throw DigestError.promptWithoutTool(prompt.name) }
        return LLMRequest(
            model: model,
            system: [LLMTextBlock(text: system, cache: prompt.cacheBreakpoints.contains("system"))],
            messages: [LLMMessage(role: .user, content: [
                .text(bundle, cache: prompt.cacheBreakpoints.contains("bundle")),
                .text(instruction, cache: false),
            ])],
            // strict: the schema is strict-safe; forced tool_choice is a 400 on Opus 5.5, so `.auto` + the prompt's instruction.
            tools: [ToolDefinition(name: toolName, description: schema["description"]?.stringValue ?? "", inputSchema: schema, strict: true)],
            toolChoice: .auto, maxTokens: prompt.maxTokens ?? Prompt.defaultMaxTokens, stage: .digest,
            promptName: prompt.name, promptVersion: prompt.version, effort: prompt.effort)
    }

    /// One call; without a `digest` tool call, one retry with the assistant turn and `retryInstruction` appended.
    public static func call(_ initial: LLMRequest, toolName: String, llm: LLMClient) async throws -> DigestToolOutput {
        var request = initial
        for attempt in 0..<2 {
            let response = try await llm.complete(request)
            if response.stopReason == "max_tokens" { throw DigestError.outputTruncated }
            let called = response.content.contains { if case let .toolUse(_, name, _) = $0 { name == toolName } else { false } }
            if called { return try response.toolInput(toolName, as: DigestToolOutput.self) }
            guard attempt == 0 else { break }
            log.warning("digest response without a tool call (stop_reason \(response.stopReason, privacy: .public)); retrying once")
            let texts = response.content.filter { if case .text = $0 { true } else { false } }
            // No text (e.g. only thinking): consecutive user turns are merged by the API.
            if !texts.isEmpty { request.messages.append(LLMMessage(role: .assistant, content: texts)) }
            request.messages.append(LLMMessage(role: .user, content: [.text(retryInstruction, cache: false)]))
        }
        throw DigestError.noToolCall
    }

    // MARK: Validation

    /// Unknown ids dropped; clusters keep only selected, not-yet-claimed ids (first cluster wins) and are
    /// dissolved below 2 ids, then renumbered c1...; each paper's `cluster_id` comes from the clusters; one entry per
    /// selected paper in rank order, the missing ones filled from triage and flagged `modelOmitted`.
    public static func normalize(_ out: DigestToolOutput, papers: [BundlePaper]) -> (clusters: [DigestCluster], papers: [DigestPaper]) {
        let selected = Set(papers.map(\.ranked.paper.id))
        var claimed: [String: String] = [:]
        var clusters: [DigestCluster] = []
        for c in out.clusters {
            var ids: [String] = []
            for raw in c.paperIDs {
                let id = raw.trimmingCharacters(in: .whitespaces)
                if selected.contains(id), claimed[id] == nil, !ids.contains(id) { ids.append(id) }
            }
            guard ids.count >= 2 else {
                log.notice("cluster \(c.id, privacy: .public) dissolved: \(ids.count) valid ids")
                continue
            }
            let id = "c\(clusters.count + 1)"
            for paperID in ids { claimed[paperID] = id }
            clusters.append(DigestCluster(id: id, name: c.name.trimmingCharacters(in: .whitespacesAndNewlines), paperIDs: ids,
                                          narrative: c.narrative.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        var byID: [String: DigestToolOutput.Paper] = [:]
        for p in out.papers {
            let id = p.id.trimmingCharacters(in: .whitespaces)
            if selected.contains(id), byID[id] == nil { byID[id] = p }
        }
        let result = papers.map { b -> DigestPaper in
            let paper = b.ranked.paper
            let versioned = "\(paper.id)v\(paper.version)"
            // OpenAlex journal papers: DOI / OpenAlex page and the OA PDF if any; no arXiv HTML.
            let links = ArxivClient.isArxivID(paper.id)
                ? PaperLinks(abs: paper.absURL ?? URL(string: "https://arxiv.org/abs/\(versioned)"),
                             html: URL(string: "https://arxiv.org/html/\(versioned)"),
                             pdf: paper.pdfURL ?? URL(string: "https://arxiv.org/pdf/\(versioned)"))
                : PaperLinks(abs: paper.absURL, html: nil, pdf: paper.pdfURL)
            let figures = b.fullText == nil ? [] : b.figures
            guard let m = byID[paper.id] else {
                return DigestPaper(id: paper.id, clusterID: claimed[paper.id] ?? "", essence: b.ranked.oneLine, detail: "", whyItMatters: "",
                                   caveats: "", figureIndex: 0, mermaid: "", title: paper.title, authors: paper.authors,
                                   score: b.ranked.score, tags: b.ranked.tags, links: links, figure: nil, modelOmitted: true, venue: paper.venue)
            }
            let figure = figures.first { $0.index == m.figureIndex }
            return DigestPaper(
                id: paper.id, clusterID: claimed[paper.id] ?? "", essence: m.essence.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: m.detail.trimmingCharacters(in: .whitespacesAndNewlines),
                whyItMatters: m.whyItMatters.trimmingCharacters(in: .whitespacesAndNewlines),
                caveats: m.caveats.trimmingCharacters(in: .whitespacesAndNewlines), figureIndex: figure == nil ? 0 : m.figureIndex,
                mermaid: bareMermaid(m.mermaid), title: paper.title, authors: paper.authors, score: b.ranked.score, tags: b.ranked.tags,
                links: links, figure: figure, modelOmitted: false, venue: paper.venue)
        }
        return (clusters, result)
    }

    /// Entries whose id was not listed in `<hf_papers>` are dropped (first entry per id wins, model order); a
    /// listed paper the model skipped is appended with its summary's first sentence. `title` / `upvotes` come from the
    /// listing, never from the model.
    public static func normalizeHF(_ entries: [HFEntry], listed: [HFDailyPaper]) -> [HFEntry] {
        let byID = Dictionary(listed.map { ($0.arxivID, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var out: [HFEntry] = []
        for e in entries {
            let id = e.id.trimmingCharacters(in: .whitespaces)
            guard let p = byID[id], seen.insert(id).inserted else { continue }
            let line = e.oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(HFEntry(id: id, oneLine: line.isEmpty ? firstSentence(p.summary) : line, title: p.title, upvotes: p.upvotes))
        }
        for p in listed where !seen.contains(p.arxivID) {
            log.notice("hf_section: model skipped \(p.arxivID, privacy: .public); filled from its summary")
            out.append(HFEntry(id: p.arxivID, oneLine: firstSentence(p.summary), title: p.title, upvotes: p.upvotes))
        }
        return out
    }

    /// Up to and including the first `.`, `!` or `?` followed by whitespace (or the end); the whole text if there is none.
    static func firstSentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = t.firstMatch(of: /[.!?](\s|$)/) else { return t }
        return String(t[..<match.range.lowerBound]) + String(t[match.range].prefix(1))
    }

    /// Strips a code fence the model may have added; the renderer wraps the bare body.
    static func bareMermaid(_ s: String) -> String {
        var lines = s.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
        if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "Nothing new": no paper in the pool reached `min_score`.
    public static func emptyTitleAndSummary(counts: RunCounts, config: Config) -> (title: String, summary: String) {
        if config.language == "ru" {
            return ("Ничего нового",
                    "Ни одна непоказанная статья не набрала \(config.minScore)+: получено \(counts.fetched), новых \(counts.new), оценено \(counts.triaged).")
        }
        return ("Nothing new",
                "No unshown paper scored \(config.minScore) or higher: fetched \(counts.fetched), new \(counts.new), scored \(counts.triaged).")
    }
}
