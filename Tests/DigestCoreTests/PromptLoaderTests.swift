import Foundation
import Testing
@testable import DigestCore

/// Writes a tiny prompt file into `dir` (tests never depend on the bundled prompts).
func writePrompt(_ dir: URL, name: String = "triage", version: Int, body: String = "Profile: {{interest_profile}}",
                 placeholders: String = "[interest_profile]", schema: Bool = false) throws {
    var front = """
        ---
        name: \(name)
        version: \(version)
        model: claude-haiku-5-5
        tool_name: triage_result
        cache_breakpoints: [system]
        placeholders: \(placeholders)

        """
    if schema {
        front += "schema: schemas/\(name).json\n"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("schemas"), withIntermediateDirectories: true)
        try Data(#"{"type":"object","description":"Test tool.","properties":{"x":{"type":"integer"}}}"#.utf8)
            .write(to: dir.appendingPathComponent("schemas/\(name).json"))
    }
    try Data((front + "---\n" + body).utf8).write(to: dir.appendingPathComponent("\(name).v\(version).md"))
}

@Suite struct PromptLoaderTests {
    @Test func highestVersionWins() throws {
        let dir = try TestSupport.tempDirectory()
        try writePrompt(dir, version: 1, body: "one {{interest_profile}}")
        try writePrompt(dir, version: 3, body: "three {{interest_profile}}")
        try writePrompt(dir, version: 2, body: "two {{interest_profile}}")
        let loader = PromptLoader(directory: dir)
        #expect(try loader.versions(of: "triage") == [1, 2, 3])
        #expect(try loader.load("triage").version == 3)
        #expect(throws: PromptError.notFound("digest")) { try loader.load("digest") }
    }

    @Test func pinSelectsVersion() throws {
        let dir = try TestSupport.tempDirectory()
        try writePrompt(dir, version: 1)
        try writePrompt(dir, version: 2)
        #expect(try PromptLoader(directory: dir, pins: ["triage": 1]).load("triage").version == 1)
        #expect(throws: PromptError.pinnedVersionNotFound("triage", 7)) {
            try PromptLoader(directory: dir, pins: ["triage": 7]).load("triage")
        }
    }

    @Test func frontMatterParsed() throws {
        let dir = try TestSupport.tempDirectory()
        try writePrompt(dir, version: 1, body: "Body {{interest_profile}} in {{language}}\nline 2",
                        placeholders: "[interest_profile, language]", schema: true)
        let p = try PromptLoader(directory: dir).load("triage")
        #expect(p.name == "triage")
        #expect(p.model == "claude-haiku-5-5")
        #expect(p.toolName == "triage_result")
        #expect(p.cacheBreakpoints == ["system"])
        #expect(p.placeholders == ["interest_profile", "language"])
        #expect(p.body == "Body {{interest_profile}} in {{language}}\nline 2")
        #expect(p.schema?["description"] == .string("Test tool."))
        #expect(p.schema?["properties"]?["x"]?["type"] == .string("integer"))
    }

    @Test func renderReplacesVerbatimOnce() throws {
        let dir = try TestSupport.tempDirectory()
        try writePrompt(dir, version: 1, body: "A {{interest_profile}} B {{language}}", placeholders: "[interest_profile, language]")
        let p = try PromptLoader(directory: dir).load("triage")
        // A value that itself contains braces is inserted verbatim, not rescanned.
        #expect(try p.render(["interest_profile": "likes {{x}}", "language": "ru"]) == "A likes {{x}} B ru")
    }

    @Test func missingPlaceholderValueThrows() throws {
        let dir = try TestSupport.tempDirectory()
        try writePrompt(dir, version: 1, body: "A {{interest_profile}} {{language}}", placeholders: "[interest_profile, language]")
        let p = try PromptLoader(directory: dir).load("triage")
        #expect(throws: PromptError.missingVariable(prompt: "triage", name: "language")) {
            try p.render(["interest_profile": "x"])
        }
    }

    @Test func undeclaredOrUnclosedSlotThrows() throws {
        let dir = try TestSupport.tempDirectory()
        try writePrompt(dir, version: 1, body: "A {{interest_profile}} {{oops}}")
        #expect(throws: PromptError.unreplacedPlaceholder(prompt: "triage", slot: "{{oops}}")) {
            try PromptLoader(directory: dir).load("triage").render(["interest_profile": "x"])
        }
        try writePrompt(dir, version: 2, body: "A {{interest_profile}} and {{ dangling")
        #expect(throws: PromptError.self) {
            try PromptLoader(directory: dir).load("triage").render(["interest_profile": "x"])
        }
    }

    @Test func versionMismatchInFrontMatterThrows() throws {
        let dir = try TestSupport.tempDirectory()
        try writePrompt(dir, version: 1)
        try FileManager.default.moveItem(at: dir.appendingPathComponent("triage.v1.md"), to: dir.appendingPathComponent("triage.v4.md"))
        #expect(throws: PromptError.self) { try PromptLoader(directory: dir).load("triage") }
    }

    @Test func bundledDirectoryResolves() throws {
        // Only checks that the resource directory is packaged, not its contents.
        let loader = try PromptLoader.bundled()
        #expect(FileManager.default.fileExists(atPath: loader.directory.path))
    }

    @Test func maxTokensAndEffortFrontMatter() throws {
        let dir = try TestSupport.tempDirectory()
        try Data("---\nname: digest\nversion: 1\nmodel: claude-opus-5-5\nmax_tokens: 64000\neffort: high\n---\nbody".utf8)
            .write(to: dir.appendingPathComponent("digest.v1.md"))
        let p = try PromptLoader(directory: dir).load("digest")
        #expect(p.maxTokens == 64000 && p.effort == "high")
        try Data("---\nname: digest\nversion: 2\nmodel: m\neffort: max\n---\nbody".utf8).write(to: dir.appendingPathComponent("digest.v2.md"))
        #expect(throws: PromptError.self) { try PromptLoader(directory: dir).load("digest") }
        try writePrompt(dir, version: 1)
        let triage = try PromptLoader(directory: dir).load("triage")
        #expect(triage.maxTokens == nil && triage.effort == nil)
    }

    @Test func bundledDigestPromptLoads() throws {
        let p = try PromptLoader.bundled().load("digest")
        #expect(p.maxTokens == 64000)
        #expect(p.toolName == "digest")
        #expect(p.cacheBreakpoints == ["system", "bundle"])
        _ = try p.render(["interest_profile": "x", "language": "ru", "explanation_level": "engineer"])
    }
}

@Suite struct PromptBundleLookupTests {
    /// Embedded CLI layout: `X.app/Contents/MacOS/digest-cli` finds `Contents/Resources/brainmaxxing_DigestCore.bundle`,
    /// also through a symlink to the binary, and before `Bundle.main`'s resources.
    @Test(arguments: ["Contents/Resources/Prompts", "Prompts"])
    func resolvesBundleNextToExecutable(inner: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("X.app/Contents")
        let prompts = contents.appendingPathComponent("Resources/brainmaxxing_DigestCore.bundle/\(inner)")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try writePrompt(prompts, version: 3)
        let exe = contents.appendingPathComponent("MacOS/digest-cli")
        try Data().write(to: exe)
        let link = root.appendingPathComponent("digest-cli")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)
        let decoy = root.appendingPathComponent("decoy")

        for executable in [exe, link] {
            let loader = try PromptLoader.bundled(executable: executable, mainResources: decoy)
            #expect(loader.directory.resolvingSymlinksInPath() == prompts.resolvingSymlinksInPath())
            #expect(try loader.load("triage").version == 3)
        }
        // Falls back to Bundle.main's resources when nothing sits next to the executable.
        let fallback = try PromptLoader.bundled(executable: decoy.appendingPathComponent("MacOS/x"),
                                                mainResources: contents.appendingPathComponent("Resources"))
        #expect(fallback.directory.resolvingSymlinksInPath() == prompts.resolvingSymlinksInPath())
    }
}
