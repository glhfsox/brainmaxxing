import DigestCore
import Foundation
import Testing

/// Digest eval: writes the digest for each golden day that has full texts, through the production
/// `DigestWriter` (bundle, request, call, normalize), asserts the structural rules, then asks a Sonnet grader for
/// rubric scores that are reported, never asserted. Opt-in: `PROMPT_EVALS=1 PROMPT_EVALS_DIGEST=1`.
@Suite(.serialized) struct DigestEval {
    /// Full text per paper sent to the grader; the writer always gets the whole truncated text from the golden day.
    static let graderFullTextChars = 12_000

    @Test(.enabled(if: PromptEvals.digestEnabled, "set PROMPT_EVALS=1 PROMPT_EVALS_DIGEST=1 to run the digest eval (Opus)"))
    func digestAgainstGolden() async throws {
        let env = try EvalEnv.shared.get()
        let prompt = try PromptEvals.prompts().load("digest")
        let grader = try PromptLoader(directory: PromptEvals.graderPrompts).load("digest_grader")
        let days = try GoldenDay.all().filter { day in day.selected.contains { day.fullText($0) != nil } }
        try #require(!days.isEmpty, "no golden day has fulltext/ for its selected papers")
        let spentBefore = try await env.spentUSD()

        for day in days {
            let config = day.appConfig(digestModel: prompt.model)
            let bundlePapers = try Self.bundlePapers(day)
            let bundle = DigestWriter.bundle(date: day.date, partial: false, recentClusters: [], papers: bundlePapers)
            let request = try DigestWriter.request(prompt: prompt, system: try DigestWriter.systemText(prompt, config: config),
                                                   bundle: bundle, model: prompt.model)
            let raw = try await DigestWriter.call(request, toolName: prompt.toolName ?? "", llm: env.llm)
            let (clusters, papers) = DigestWriter.normalize(raw, papers: bundlePapers)

            let checks = Self.structuralChecks(raw: raw, clusters: clusters, papers: papers, selected: day.selected)
            var lines = ["[eval] digest v\(prompt.version) | \(day.date) | \(day.selected.count) selected | \(clusters.count) clusters"]
            for c in checks {
                lines.append("[eval]   \(c.passed ? "pass" : "FAIL") \(c.name)\(c.detail.isEmpty ? "" : ": \(c.detail)")")
                #expect(c.passed, "\(day.date): \(c.name) \(c.detail)")
            }
            lines.append("[eval]   structural pass \(checks.filter(\.passed).count)/\(checks.count)")
            if config.language == "ru" {
                lines.append("[eval]   essence with Cyrillic \(EvalMetrics.f(EvalMetrics.cyrillicShare(papers.map(\.essence))))")
            }

            let grade = try await Self.grade(raw: raw, bundlePapers: bundlePapers, day: day, grader: grader, llm: env.llm)
            if let g = grade {
                lines.append("[eval]   grader faithfulness \(g.faithfulness)  clusters \(g.clusterQuality)  filler \(g.filler)  language \(g.language)")
                for c in g.unsupportedClaims { lines.append("[eval]     \(c.kind) [\(c.paperID)] \(c.field): \(c.claim)") }
                for v in g.languageViolations { lines.append("[eval]     language: \(v)") }
                lines.append("[eval]   grader note: \(g.note)")
            } else {
                lines.append("[eval]   grader: no tool call")
            }
            // One paper and one narrative to judge by eye.
            if let p = papers.first { lines.append("[eval]   excerpt \(p.id) essence: \(p.essence)\n[eval]   why: \(p.whyItMatters)") }
            if let c = clusters.first { lines.append("[eval]   excerpt cluster \(c.name): \(c.narrative)") }
            print(lines.joined(separator: "\n"))
        }
        let spent = try await env.spentUSD() - spentBefore
        print("[eval] digest v\(prompt.version) cost $\(EvalMetrics.f(spent, 4)) | eval process total $\(EvalMetrics.f(try await env.spentUSD(), 4)) of cap $\(EvalMetrics.f(PromptEvals.budgetUSD, 2))")
    }

    // MARK: Bundle

    /// Selected papers in rank order with the golden day's full text and figure captions.
    static func bundlePapers(_ day: GoldenDay) throws -> [BundlePaper] {
        let byID = Dictionary(day.papers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let triage = Dictionary(day.triage.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return try day.selected.enumerated().map { i, id in
            let paper = try #require(byID[id], "selected \(id) is not in papers.json of \(day.date)")
            let t = triage[id]
            let text = day.fullText(id)
            // The golden layout does not record html vs pdf; the attribute only labels the source in the bundle.
            let figures = day.figures.filter { $0.paperID == id }
                .map { Figure(paperID: id, index: $0.index, path: "", caption: $0.caption, source: .html) }
            return BundlePaper(ranked: RankedPaper(paper: paper, score: t?.score ?? 0, oneLine: t?.oneLine ?? "", tags: t?.tags ?? [],
                                                   selected: true, rank: i + 1),
                               fullText: text, source: text == nil ? nil : .html, figures: figures)
        }
    }

    // MARK: Structure

    struct Check {
        var name: String
        var passed: Bool
        var detail: String
    }

    static func structuralChecks(raw: DigestToolOutput, clusters: [DigestCluster], papers: [DigestPaper], selected: [String]) -> [Check] {
        let selectedSet = Set(selected)
        let rawIDs = raw.papers.map { $0.id.trimmingCharacters(in: .whitespaces) }
        let missing = selected.filter { !rawIDs.contains($0) }
        let extra = rawIDs.filter { !selectedSet.contains($0) }
        let duplicated = Set(rawIDs.filter { id in rawIDs.filter { $0 == id }.count > 1 })
        let smallClusters = raw.clusters.filter { c in Set(c.paperIDs.filter(selectedSet.contains)).count < 2 }.map(\.id)
        let thinNarratives = clusters.filter { citedIDs($0.narrative).intersection(selectedSet).count < 2 }.map(\.id)
        let emptyEssence = papers.filter { $0.essence.isEmpty }.map(\.id)
        let emptyWhy = papers.filter { $0.whyItMatters.isEmpty }.map(\.id)
        let noLinks = papers.filter { $0.links.abs == nil }.map(\.id)
        let mermaidErrors = papers.filter { !$0.mermaid.isEmpty }.compactMap { p in mermaidError(p.mermaid).map { "\(p.id): \($0)" } }
        return [
            Check(name: "one entry per selected paper", passed: missing.isEmpty && extra.isEmpty && duplicated.isEmpty,
                  detail: [missing.isEmpty ? "" : "missing \(missing)", extra.isEmpty ? "" : "extra \(extra)",
                           duplicated.isEmpty ? "" : "duplicated \(duplicated.sorted())"].filter { !$0.isEmpty }.joined(separator: "; ")),
            Check(name: "every cluster has >= 2 selected ids", passed: smallClusters.isEmpty, detail: smallClusters.isEmpty ? "" : "\(smallClusters)"),
            Check(name: "every narrative cites >= 2 ids", passed: thinNarratives.isEmpty, detail: thinNarratives.isEmpty ? "" : "\(thinNarratives)"),
            Check(name: "no empty essence", passed: emptyEssence.isEmpty, detail: emptyEssence.isEmpty ? "" : "\(emptyEssence)"),
            Check(name: "no empty why_it_matters", passed: emptyWhy.isEmpty, detail: emptyWhy.isEmpty ? "" : "\(emptyWhy)"),
            Check(name: "every paper has links", passed: noLinks.isEmpty, detail: noLinks.isEmpty ? "" : "\(noLinks)"),
            Check(name: "mermaid blocks parse (\(mmdcPath == nil ? "syntax check" : "mmdc"))", passed: mermaidErrors.isEmpty,
                  detail: mermaidErrors.joined(separator: "; ")),
        ]
    }

    /// Arxiv ids inside `[...]` citations, including `[a, b]` lists.
    static func citedIDs(_ text: String) -> Set<String> {
        var ids = Set<String>()
        for bracket in text.matches(of: /\[([^\]]+)\]/) {
            for m in bracket.1.matches(of: /\d{4}\.\d{4,5}/) { ids.insert(String(m.0)) }
        }
        return ids
    }

    static let mmdcPath: String? = {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map { "\($0)/mmdc" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// nil when the block parses. Uses `mmdc` when installed, else a header / bracket balance / arrow check.
    static func mermaidError(_ body: String) -> String? {
        if let mmdc = mmdcPath {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mmd-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let input = dir.appendingPathComponent("in.mmd")
                try Data(body.utf8).write(to: input)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: mmdc)
                process.arguments = ["-q", "-i", input.path, "-o", dir.appendingPathComponent("out.svg").path]
                let err = Pipe()
                process.standardError = err
                process.standardOutput = Pipe()
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    return String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(200).description
                }
                return nil
            } catch {
                return "mmdc failed to run: \(error.localizedDescription)"
            }
        }
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("%%") }
        guard let header = lines.first else { return "empty" }
        let kinds = ["flowchart", "graph", "sequenceDiagram", "stateDiagram", "classDiagram"]
        guard kinds.contains(where: { header.hasPrefix($0) }) else { return "unknown header '\(header.prefix(40))'" }
        var stack: [Character] = []
        let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
        var inQuote = false
        for ch in body {
            if ch == "\"" { inQuote.toggle(); continue }
            if inQuote { continue }
            if "([{".contains(ch) { stack.append(ch) }
            if let open = pairs[ch] {
                guard stack.last == open else { return "unbalanced '\(ch)'" }
                stack.removeLast()
            }
        }
        if inQuote { return "unclosed quote" }
        if !stack.isEmpty { return "unclosed '\(stack.last.map(String.init) ?? "")'" }
        let arrows = ["-->", "---", "-.->", "==>", "->>", "-->>", "-)", "--x", "--o"]
        guard lines.dropFirst().contains(where: { l in arrows.contains { l.contains($0) } }) else { return "no edges" }
        return nil
    }

    // MARK: Grader

    struct Grade: Decodable {
        struct Claim: Decodable {
            var paperID: String
            var field: String
            var claim: String
            var kind: String
            enum CodingKeys: String, CodingKey { case paperID = "paper_id", field, claim, kind }
        }
        var faithfulness: Int
        var unsupportedClaims: [Claim]
        var clusterQuality: Int
        var filler: Int
        var language: Int
        var languageViolations: [String]
        var note: String
        enum CodingKeys: String, CodingKey {
            case faithfulness, unsupportedClaims = "unsupported_claims", clusterQuality = "cluster_quality", filler, language
            case languageViolations = "language_violations", note
        }
    }

    /// One Sonnet call. The source is the same bundle the writer saw, with each full text cut to `graderFullTextChars`.
    static func grade(raw: DigestToolOutput, bundlePapers: [BundlePaper], day: GoldenDay, grader: Prompt, llm: LLMClient) async throws -> Grade? {
        guard let toolName = grader.toolName, let schema = grader.schema else { return nil }
        let cut = bundlePapers.map { b in
            var b = b
            b.fullText = b.fullText.map { $0.count > graderFullTextChars ? String($0.prefix(graderFullTextChars)) + "\n[truncated_for_grading=\"true\"]" : $0 }
            return b
        }
        let source = DigestWriter.bundle(date: day.date, partial: false, recentClusters: [], papers: cut)
        let digestJSON = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        let request = LLMRequest(
            model: grader.model,
            system: [LLMTextBlock(text: try grader.render(["language": day.config.language]), cache: grader.cacheBreakpoints.contains("system"))],
            messages: [LLMMessage(role: .user, content: [.text("<source>\n\(source)\n</source>\n<digest>\n\(digestJSON)\n</digest>", cache: false)])],
            tools: [ToolDefinition(name: toolName, description: schema["description"]?.stringValue ?? "", inputSchema: schema, strict: false)],
            // `.auto`: forced tool_choice is rejected when the model thinks; the prompt asks for exactly one call.
            toolChoice: .auto, maxTokens: grader.maxTokens ?? Prompt.defaultMaxTokens, stage: .digest,
            promptName: grader.name, promptVersion: grader.version, effort: grader.effort)
        let response = try await llm.complete(request)
        return try? response.toolInput(toolName, as: Grade.self)
    }
}
