import Foundation

enum TestSupport {
    /// `Tests/Fixtures`, located relative to this source file (fixtures live outside the test target).
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(path))
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brainmaxxing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func date(_ iso: String) throws -> Date {
        try Date(iso, strategy: .iso8601)
    }
}
