import Foundation
import MCP
import System
import os

/// Spawns `DigestMCP` and talks MCP over its stdin/stdout through the SDK client.
/// The process starts on first use. If it dies, the next call restarts it - at most once per chat message.
public actor MCPToolProvider: ToolProvider {
    private let executable: URL
    nonisolated let environment: [String: String]
    private var process: Process?
    private var client: Client?
    private var pipes: (toServer: Pipe, fromServer: Pipe)?
    private var cachedTools: [ToolSpec]?
    private var restartsLeft = 1
    private var started = false
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "mcp-client")

    /// `DIGEST_MCP_PATH` wins; otherwise `DigestMCP` next to the running executable (the app bundle's `MacOS/`).
    public static func defaultExecutable(environment: [String: String] = ProcessInfo.processInfo.environment,
                                         mainExecutable: URL? = Bundle.main.executableURL) -> URL? {
        if let path = environment["DIGEST_MCP_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return mainExecutable?.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("DigestMCP")
    }

    /// The only variables the server gets from `environment`: it needs its data directory and a sane process
    /// environment, never the app's secrets (`ANTHROPIC_API_KEY` and the like).
    public static let passedEnvironment: Set<String> = ["HOME", "BRAINMAXXING_HOME", "PATH", "TMPDIR", "LANG"]

    /// `environment` is filtered to `passedEnvironment` before the server is spawned.
    public init(executable: URL, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.environment = environment.filter { Self.passedEnvironment.contains($0.key) }
    }

    public func beginMessage() { restartsLeft = 1 }

    /// The running server's pid (tests kill it to exercise the restart path).
    var serverPID: Int32? { process?.isRunning == true ? process?.processIdentifier : nil }

    public func listTools() async throws -> [ToolSpec] {
        if let cachedTools { return cachedTools }
        let tools = try await withRestart { client in try await client.listTools().tools }.map {
            ToolSpec(name: $0.name, description: $0.description ?? "", inputSchema: JSONValue($0.inputSchema))
        }
        cachedTools = tools
        return tools
    }

    public func call(_ name: String, input: JSONValue) async throws -> ToolResult {
        let arguments: [String: Value]? = if case let .object(o) = input { o.mapValues(Value.init) } else { nil }
        let (content, isError) = try await withRestart { client in
            let r: (content: [Tool.Content], isError: Bool?) = try await client.callTool(name: name, arguments: arguments)
            return r
        }
        let text = content.compactMap { item -> String? in
            if case let .text(text, _, _) = item { return text }
            return nil
        }.joined(separator: "\n")
        return ToolResult(text: text, isError: isError ?? false)
    }

    /// Stops the server process. The next call starts a new one.
    public func shutdown() async {
        await client?.disconnect()
        if let process, process.isRunning { process.terminate() }
        reset()
    }

    // MARK: Process

    private func withRestart<T: Sendable>(_ body: (Client) async throws -> T) async throws -> T {
        let first = try await connected()
        do {
            return try await body(first)
        } catch {
            // A live server answered with a protocol error: not a crash, don't restart.
            guard process?.isRunning != true, restartsLeft > 0 else { throw error }
            restartsLeft -= 1
            Self.log.warning("DigestMCP died (\(error.localizedDescription, privacy: .public)); restarting")
            reset()
            return try await body(try await connected())
        }
    }

    private func connected() async throws -> Client {
        if let client, process?.isRunning == true { return client }
        if started {
            // The process exited between calls: that counts as a crash.
            guard restartsLeft > 0 else { throw ChatError.toolServerUnavailable("DigestMCP exited") }
            restartsLeft -= 1
            Self.log.warning("DigestMCP exited; restarting")
        }
        reset()
        started = true
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ChatError.toolServerUnavailable("no executable at \(executable.path)")
        }
        let toServer = Pipe(), fromServer = Pipe()
        let process = Process()
        process.executableURL = executable
        process.environment = environment
        process.standardInput = toServer
        process.standardOutput = fromServer
        process.standardError = FileHandle.standardError
        let client = Client(name: "brainmaxxing", version: "0.1.0")
        // A crash mid-request would leave the SDK waiting forever; disconnecting fails the pending requests.
        process.terminationHandler = { _ in Task { await client.disconnect() } }
        do {
            try process.run()
        } catch {
            throw ChatError.toolServerUnavailable(error.localizedDescription)
        }
        let transport = StdioTransport(
            input: FileDescriptor(rawValue: fromServer.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toServer.fileHandleForWriting.fileDescriptor))
        self.process = process
        self.pipes = (toServer, fromServer)
        self.client = client
        do {
            try await client.connect(transport: transport)
        } catch {
            process.terminate()
            reset()
            throw ChatError.toolServerUnavailable("handshake failed: \(error.localizedDescription)")
        }
        return client
    }

    private func reset() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        client = nil
        pipes = nil
    }
}
