import Foundation

public enum PromptError: LocalizedError, Equatable {
    case bundleMissing
    case notFound(String)
    case pinnedVersionNotFound(String, Int)
    case invalidFrontMatter(String, String)
    case schemaUnreadable(String, String)
    case missingVariable(prompt: String, name: String)
    case unreplacedPlaceholder(prompt: String, slot: String)

    public var errorDescription: String? {
        switch self {
        case .bundleMissing: "bundled Prompts directory is missing from DigestCore's resources"
        case let .notFound(name): "no prompt file \(name).v<N>.md"
        case let .pinnedVersionNotFound(name, v): "prompt \(name) is pinned to v\(v), but \(name).v\(v).md does not exist"
        case let .invalidFrontMatter(file, reason): "invalid front matter in \(file): \(reason)"
        case let .schemaUnreadable(file, reason): "cannot read schema \(file): \(reason)"
        case let .missingVariable(prompt, name): "prompt \(prompt): no value for placeholder {{\(name)}}"
        case let .unreplacedPlaceholder(prompt, slot): "prompt \(prompt): slot \(slot) is not a declared placeholder"
        }
    }
}

public struct Prompt: Sendable, Equatable {
    public let name: String
    public let version: Int
    public let model: String
    public let toolName: String?
    public let schema: JSONValue?
    public let cacheBreakpoints: [String]
    public let placeholders: [String]
    public let body: String
    /// `max_tokens` front-matter key; callers default to 4096 when absent.
    public var maxTokens: Int? = nil
    /// `effort` front-matter key (`low` | `medium` | `high`); nil -> API default.
    public var effort: String? = nil

    public static let defaultMaxTokens = 4096

    /// Replaces every `{{name}}` slot in one pass (values are not rescanned). A slot that is not a
    /// declared placeholder, an unclosed `{{`, or a declared placeholder without a value is an error.
    public func render(_ vars: [String: String]) throws -> String {
        for p in placeholders where vars[p] == nil {
            throw PromptError.missingVariable(prompt: name, name: p)
        }
        var out = ""
        var rest = body[...]
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                throw PromptError.unreplacedPlaceholder(prompt: name, slot: String(rest[open.lowerBound...].prefix(40)))
            }
            let slot = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard placeholders.contains(slot), let value = vars[slot] else {
                throw PromptError.unreplacedPlaceholder(prompt: name, slot: "{{\(slot)}}")
            }
            out += value
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }
}

/// Loads `<name>.v<N>.md` prompt files. Highest version wins unless pinned.
public struct PromptLoader: Sendable {
    public let directory: URL
    public let pins: [String: Int]

    public init(directory: URL, pins: [String: Int] = [:]) {
        self.directory = directory
        self.pins = pins
    }

    /// Bundled prompts. Lookup order: (1) `<executable dir>/../Resources/<bundle>` (embedded CLI at
    /// `....app/Contents/MacOS/digest-cli` and the app itself), (2) `Bundle.main.resourceURL/<bundle>`,
    /// (3) `Bundle.module` (dev `.build`). The explicit checks come first because `Bundle.module` traps when
    /// none of its compiled-in paths exist.
    public static func bundled(pins: [String: Int] = [:],
                               executable: URL? = Bundle.main.executableURL,
                               mainResources: URL? = Bundle.main.resourceURL) throws -> PromptLoader {
        if let url = ResourceBundle.locate("Prompts", executable: executable, mainResources: mainResources) {
            return PromptLoader(directory: url, pins: pins)
        }
        guard let url = Bundle.module.url(forResource: "Prompts", withExtension: nil) else { throw PromptError.bundleMissing }
        return PromptLoader(directory: url, pins: pins)
    }

    public func versions(of name: String) throws -> [Int] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let prefix = "\(name).v"
        return files.compactMap { file -> Int? in
            guard file.hasPrefix(prefix), file.hasSuffix(".md") else { return nil }
            return Int(file.dropFirst(prefix.count).dropLast(3))
        }.sorted()
    }

    public func load(_ name: String) throws -> Prompt {
        let available = try versions(of: name)
        let version: Int
        if let pinned = pins[name] {
            guard available.contains(pinned) else { throw PromptError.pinnedVersionNotFound(name, pinned) }
            version = pinned
        } else {
            guard let highest = available.last else { throw PromptError.notFound(name) }
            version = highest
        }
        let file = "\(name).v\(version).md"
        let text: String
        do {
            text = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
        } catch {
            throw PromptError.notFound(name)
        }
        let (meta, body) = try Self.splitFrontMatter(text, file: file)

        guard meta["name"] == name else { throw PromptError.invalidFrontMatter(file, "name must be \(name)") }
        guard meta["version"].flatMap(Int.init) == version else {
            throw PromptError.invalidFrontMatter(file, "version must be \(version)")
        }
        guard let model = meta["model"], !model.isEmpty else { throw PromptError.invalidFrontMatter(file, "model is required") }

        var schema: JSONValue?
        if let schemaPath = meta["schema"], !schemaPath.isEmpty {
            do {
                let data = try Data(contentsOf: directory.appendingPathComponent(schemaPath))
                schema = try JSONDecoder().decode(JSONValue.self, from: data)
            } catch {
                throw PromptError.schemaUnreadable(schemaPath, error.localizedDescription)
            }
        }
        var maxTokens: Int?
        if let raw = meta["max_tokens"], !raw.isEmpty {
            guard let n = Int(raw), n > 0 else { throw PromptError.invalidFrontMatter(file, "max_tokens must be a positive integer") }
            maxTokens = n
        }
        var effort: String?
        if let raw = meta["effort"], !raw.isEmpty {
            guard ["low", "medium", "high"].contains(raw) else { throw PromptError.invalidFrontMatter(file, "effort must be low, medium or high") }
            effort = raw
        }
        return Prompt(
            name: name, version: version, model: model, toolName: meta["tool_name"], schema: schema,
            cacheBreakpoints: Self.list(meta["cache_breakpoints"]), placeholders: Self.list(meta["placeholders"]), body: body,
            maxTokens: maxTokens, effort: effort)
    }

    /// Flat YAML subset: `key: value` lines between `---` fences.
    static func splitFrontMatter(_ text: String, file: String) throws -> ([String: String], String) {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            throw PromptError.invalidFrontMatter(file, "file must start with ---")
        }
        lines.removeFirst()
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw PromptError.invalidFrontMatter(file, "closing --- not found")
        }
        var meta: [String: String] = [:]
        for line in lines[..<end] where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw PromptError.invalidFrontMatter(file, "bad line: \(line)") }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            meta[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (meta, lines[(end + 1)...].joined(separator: "\n"))
    }

    static func list(_ value: String?) -> [String] {
        guard var v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return [] }
        if v.hasPrefix("["), v.hasSuffix("]") { v = String(v.dropFirst().dropLast()) }
        return v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Finds a resource inside `brainmaxxing_DigestCore.bundle` outside the SwiftPM build directory.
enum ResourceBundle {
    static let name = "brainmaxxing_DigestCore.bundle"

    /// Candidate bundles in order: next to the resolved executable (`../Resources`), then `Bundle.main`'s resources.
    /// Inside a bundle both the macOS layout (`Contents/Resources/<resource>`) and the flat one are accepted.
    static func locate(_ resource: String, executable: URL?, mainResources: URL?) -> URL? {
        var bundles: [URL] = []
        if let exe = executable?.resolvingSymlinksInPath() {
            bundles.append(exe.deletingLastPathComponent().appendingPathComponent("../Resources/\(name)").standardizedFileURL)
        }
        if let res = mainResources { bundles.append(res.appendingPathComponent(name)) }
        var isDir: ObjCBool = false
        for bundle in bundles {
            for candidate in [bundle.appendingPathComponent("Contents/Resources/\(resource)"), bundle.appendingPathComponent(resource)]
            where FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir) && isDir.boolValue {
                return candidate
            }
        }
        return nil
    }
}
