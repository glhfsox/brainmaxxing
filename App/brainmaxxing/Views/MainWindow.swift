import DigestCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showRunSheet = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            DetailView()
        }
        .inspector(isPresented: $model.showChat) {
            ChatView()
                .inspectorColumnWidth(min: 240, ideal: 260, max: 520)
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                if model.runner.isRunning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(model.runner.statusLine)
                            .font(.caption).lineLimit(1).truncationMode(.tail).frame(maxWidth: 360)
                            .help(model.runner.statusLine)
                    }
                }
            }
            ToolbarItem {
                Button("Make Digest...", systemImage: "sparkles") { showRunSheet = true }
                    .disabled(model.runner.isRunning)
            }
            ToolbarItem {
                Button("Chat", systemImage: "bubble.left.and.text.bubble.right") { model.showChat.toggle() }
            }
        }
        .sheet(isPresented: $showRunSheet) {
            RunSheet(categories: model.config.categories) { categories in
                showRunSheet = false
                model.requestManualRun(categories: categories)
            } onCancel: {
                showRunSheet = false
            }
        }
        .sheet(isPresented: $model.showOnboarding) {
            OnboardingView()
        }
        .alert("brainmaxxing", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task { await model.reloadAll() }
        .onAppear { model.openMainWindowAction = { openWindow(id: AppModel.mainWindowID) } }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("Digests") {
                if !model.hasTodayDigest {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Today")
                            Text(model.runner.isRunning ? model.runner.shortStatus : "No digest yet").font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } icon: { Image(systemName: "calendar") }
                    .tag(SidebarItem.digest(date: model.today, edition: 1))
                }
                ForEach(model.digests) { item in
                    DigestRow(item: item, today: model.today)
                        .tag(SidebarItem.digest(date: item.date, edition: item.edition))
                }
            }
            Section("Library") {
                Label("All papers", systemImage: "books.vertical")
                    .badge(model.totalPapers)
                    .tag(SidebarItem.allPapers)
            }
        }
        .listStyle(.sidebar)
    }
}

struct DigestRow: View {
    let item: DigestListItem
    let today: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(DateLabel.sidebar(item.date, today: today)).font(.headline)
                if item.edition > 1 {
                    Text("edition \(item.edition)").font(.caption2).foregroundStyle(.secondary)
                }
                Text(item.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if item.partial {
                    Text("partial").font(.caption2).foregroundStyle(.orange)
                }
            }
        } icon: {
            Image(systemName: item.empty ? "tray" : "doc.richtext")
        }
        .badge(item.unreadCount)
    }
}

/// Sidebar date labels ("Today", "Yesterday", "Mon 20 Oct").
enum DateLabel {
    static func sidebar(_ date: String, today: String, calendar: Calendar = .current) -> String {
        if date == today { return "Today" }
        guard let day = LocalDate.date(date, calendar: calendar) else { return date }
        if let t = LocalDate.date(today, calendar: calendar), calendar.dateComponents([.day], from: day, to: t).day == 1 {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.selection {
        case .allPapers:
            PaperSearchView(store: model.store)
        case let .digest(date, _):
            // While the next date loads, the previous digest stays up: no web view teardown and reload per click.
            if let digest = model.currentDigest {
                DigestWebView(digest: digest, marks: model.marks, home: model.paths.home) { message in
                    handle(message)
                }
            } else {
                NoDigestView(date: date)
            }
        case nil:
            ContentUnavailableView("Select a digest", systemImage: "doc.richtext")
        }
    }

    private func handle(_ message: DigestPageMessage) {
        switch message {
        case let .feedback(paperID, verdict): Task { await model.setFeedback(paperID: paperID, verdict: verdict) }
        case let .read(paperID, read): Task { await model.setRead(paperID: paperID, read: read) }
        case let .open(url): model.open(urlString: url)
        case let .quote(paperID, clusterID, text): model.addQuote(paperID: paperID, clusterID: clusterID, text: text)
        case let .failure(text): model.errorMessage = text
        }
    }
}

struct NoDigestView: View {
    @Environment(AppModel.self) private var model
    let date: String

    var body: some View {
        if model.runner.isRunning {
            RunProgressCard(runner: model.runner)
        } else {
            ContentUnavailableView {
                Label(date == model.today ? "No digest today yet" : "No digest for \(date)", systemImage: "doc.richtext")
            } description: {
                if let status = model.runner.lastExitStatus, status != 0, let line = model.runner.lastLine {
                    Text(line)
                } else {
                    Text("The nightly run makes one between \(model.config.schedule.windowStart):00 and \(model.config.schedule.windowEnd):00 when the Mac is idle.")
                }
            } actions: {
                if date == model.today {
                    Button("Make digest now") { model.requestManualRun(categories: nil) }
                }
            }
        }
    }
}

/// Manual run with a topic picker pre-filled from config.
struct RunSheet: View {
    @State var categories: [String]
    let onRun: ([String]) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Make digest now").font(.title3.bold())
            Text("Runs the full pipeline with these categories. Costs up to the daily budget.")
                .font(.callout).foregroundStyle(.secondary)
            CategoryPicker(selection: $categories)
                .frame(minHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Run") { onRun(categories) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(categories.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
