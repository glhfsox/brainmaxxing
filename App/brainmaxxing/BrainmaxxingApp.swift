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
        .defaultSize(width: 1280, height: 820)
        .defaultLaunchBehavior(LaunchOptions.hidden ? .suppressed : .presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Make Digest Now") { model.requestManualRun(categories: nil) }
                    .disabled(model.runner.isRunning)
            }
        }

        MenuBarExtra {
            MenuBarContent()
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
