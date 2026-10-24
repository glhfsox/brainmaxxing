import AppKit
import SwiftUI

/// `--hidden` (the 10:00 launchd job): no window, menu bar item only, post the daily notification.
enum LaunchOptions {
    static let hidden = CommandLine.arguments.contains("--hidden")
}

@main
struct BrainmaxxingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        // A single `Window` rather than a `WindowGroup`: "Open", the notification and the menu bar must bring back the
        // one main window, never stack duplicates.
        Window("brainmaxxing", id: AppModel.mainWindowID) {
            MainWindow()
                .environment(model)
        }
        // No state restoration, so every launch uses this: about 80% of the screen it opens on, at most 1280x820.
        .defaultWindowPlacement { _, context in
            let visible = context.defaultDisplay.visibleRect.size
            return WindowPlacement(.center, size: CGSize(width: min(1280, visible.width * 0.8), height: min(820, visible.height * 0.8)))
        }
        .defaultLaunchBehavior(LaunchOptions.hidden ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") { delegate.updater.checkForUpdates() }
                    .disabled(!delegate.updater.isEnabled)
            }
            CommandGroup(after: .newItem) {
                Button("Make Digest Now") { model.requestManualRun(categories: nil) }
                    .disabled(model.runner.isRunning)
            }
        }

        MenuBarExtra {
            MenuBarContent(updater: delegate.updater)
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updater = Updater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(LaunchOptions.hidden ? .accessory : .regular)
        let model = AppModel.shared
        NotificationController.shared.install(model: model)
        Task {
            await model.start()
            if !LaunchOptions.hidden { model.evaluateOnboarding() }
            await NotificationController.shared.requestAuthorizationIfNeeded()
            if LaunchOptions.hidden { await NotificationController.shared.postDailyIfNeeded() }
            NotificationController.shared.scheduleDaily()
        }
    }

    /// A chat answer or a run in flight is stopped first, and the quit waits (<= 10 s) until its usage is recorded.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        guard model.chat.isSending || model.runner.isRunning else { return .terminateNow }
        Task {
            await model.stopForQuit(limit: .seconds(10))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// The app lives on in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
