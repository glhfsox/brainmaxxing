import Foundation

/// Writes raw API responses for replay: `<root>/<run_id>/<name>` inside a run, `<root>/<name>` otherwise.
public struct RawArchive: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func save(_ data: Data, name: String) throws {
        var dir = root
        if let runID = RunContext.runID { dir = dir.appendingPathComponent(runID, isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}
