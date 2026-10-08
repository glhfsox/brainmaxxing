import DigestCore
import SwiftUI

/// Always alive while the app runs, so it registers the `openWindow` action for non-view code (notifications).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.runner.isRunning ? "arrow.triangle.2.circlepath" : "brain")
            .onAppear {
                model.openMainWindowAction = { openWindow(id: AppModel.mainWindowID) }
            }
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.runner.isRunning {
            Text("Making digest... \(model.runner.progress ?? "")")
            if let line = model.runner.lastLine { Text(line) }
            Button("Stop run") { model.runner.cancel() }
        } else if let status = model.runner.lastExitStatus, status != 0 {
            Text("Last manual run failed (exit \(status))")
        }
        ForEach(MenuStatus.lines(model.schedulerStatus, hasTodayDigest: model.hasTodayDigest), id: \.self) { Text($0) }
        Divider()
        Button("Make digest now") { model.requestManualRun(categories: nil) }
            .disabled(model.runner.isRunning)
        Button("Open") { model.showMainWindow(date: model.hasTodayDigest ? model.today : nil) }
            .keyboardShortcut("o")
        SettingsLink { Text("Settings...") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit brainmaxxing") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Status lines for the menu: last run, next window, cost today.
enum MenuStatus {
    static func lines(_ s: SchedulerStatus?, hasTodayDigest: Bool) -> [String] {
        guard let s else { return ["Status unavailable"] }
        var lines: [String] = []
        lines.append(hasTodayDigest ? "Today's digest is ready" : "No digest today yet")
        if let run = s.lastRun {
            lines.append("Last run: \(run.startedAt.formatted(date: .abbreviated, time: .shortened)) - \(run.status.rawValue)\(run.partial ? ", partial" : "")")
        } else {
            lines.append("Last run: none")
        }
        if let next = s.nextFire {
            lines.append("Next window: \(next.formatted(date: .abbreviated, time: .shortened))")
        } else {
            lines.append("Nightly agent not installed")
        }
        lines.append(String(format: "Cost today: $%.2f of $%.2f", s.costTodayUSD, s.dailyBudgetUSD))
        return lines
    }
}
