import Foundation
import Sparkle

/// Sparkle with its standard UI. Updates are off (and "Check for Updates..." is disabled) until the bundle's
/// `SUFeedURL` is filled in for a release build.
@MainActor
final class Updater {
    private let controller: SPUStandardUpdaterController?

    init() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        controller = feed.trimmingCharacters(in: .whitespaces).isEmpty
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isEnabled: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }
}
