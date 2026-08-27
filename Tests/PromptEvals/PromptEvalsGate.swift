import DigestCore
import Foundation
import Testing

/// Gate for the prompt-eval target (triage MAE / Jaccard, digest structure + Sonnet grader). Every test in this
/// target must carry `.enabled(if: PromptEvals.enabled)` so that plain `swift test` never calls the live API.
enum PromptEvals {
    static let enabled = ProcessInfo.processInfo.environment["PROMPT_EVALS"] == "1"
    /// Cap for the evals' own `CostMeter` (separate temp `BRAINMAXXING_HOME`, never the user's spend).
    static let budgetUSD = ProcessInfo.processInfo.environment["PROMPT_EVALS_BUDGET_USD"].flatMap(Double.init) ?? 5
    static let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/golden", isDirectory: true)
}

@Suite struct PromptEvalsGate {
    @Test(.enabled(if: PromptEvals.enabled, "set PROMPT_EVALS=1 to run live prompt evals"))
    func harnessPreconditions() throws {
        #expect(PromptEvals.budgetUSD > 0)
        let prompts = try PromptLoader.bundled()
        _ = try prompts.load("triage")
        _ = try prompts.load("digest")
        _ = try PromptEvals.apiKey()
    }
}
