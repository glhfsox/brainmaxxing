import AppKit
import DigestCore
import Foundation
import Observation

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case digest(date: String, edition: Int)        // local YYYY-MM-DD; edition 1, then 2, 3, ... for same-day re-runs
    case allPapers
}

/// Feedback and read state of the papers on screen, pushed to the page as `state`.
struct PaperMarks: Equatable {
    var feedback: [String: Verdict] = [:]
    var read: Set<String> = []
}

/// App-wide state. Data access goes only through DigestCore (`Store`, `Config`, `KeychainStore`, scheduler types).
@Observable @MainActor
final class AppModel {
    static let shared = AppModel()
    static let mainWindowID = "main"

    let paths = AppPaths.resolve()
    private(set) var store: Store? {
        didSet { chat.store = store }
    }
    private(set) var config = Config() {
        didSet { chat.config = config }
    }
    /// One line for a load/save failure; shown in the window and the menu.
    var errorMessage: String?

    private(set) var digests: [DigestListItem] = []
    var selection: SidebarItem? = .digest(date: LocalDate.string(Date()), edition: 1) {
        didSet { if selection != oldValue { Task { await loadSelection() } } }
    }
    private(set) var currentDigest: Digest?
    private(set) var marks = PaperMarks()
    private(set) var totalPapers = 0

    let chat = ChatModel()
    var showChat = true

    private(set) var schedulerStatus: SchedulerStatus?
    let runner = RunController()
    private var statusTask: Task<Void, Never>?

    /// Set by the menu bar label (alive from launch) and the main window, so non-view code can open the window.
    var openMainWindowAction: (() -> Void)?

    var today: String { LocalDate.string(Date()) }
    var hasTodayDigest: Bool { digests.contains { $0.date == today } }

    /// The sidebar item of the date's latest listed edition (edition 1 when the date has none yet).
    func latestItem(date: String) -> SidebarItem {
        .digest(date: date, edition: digests.filter { $0.date == date }.map(\.edition).max() ?? 1)
    }

    private init() {}

    // MARK: Startup and loading

    func start() async {
        do {
            config = try Config.load(home: paths.home)
        } catch {
            errorMessage = error.localizedDescription
        }
        do {
            store = try Store(url: paths.database)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        await reloadList()
        if case let .digest(date, _)? = selection { selection = latestItem(date: date) }   // open on the newest edition
        await loadSelection()
        await refreshStatus()
        // The nightly run happens in another process; pick up its results and keep the menu status current.
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard let self, !self.runner.isRunning else { continue }
                await self.reloadList()
                await self.refreshStatus()
            }
        }
    }

    func reloadAll() async {
        await reloadList()
        await loadSelection()
        await refreshStatus()
    }

    func reloadList() async {
        guard let store else { return }
        do {
            let loaded = try await store.digestList()
            if loaded != digests { await chat.digestsChanged() }
            digests = loaded
            totalPapers = try await store.paperCountTotal()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadSelection() async {
        guard let store, case let .digest(date, edition) = selection else {
            currentDigest = nil
            await chat.follow(digestDate: nil)
            return
        }
        do {
            let digest = try await store.digest(date: date, edition: edition)
            guard selection == .digest(date: date, edition: edition) else { return }     // the user moved on while we were reading
            currentDigest = digest
            await chat.follow(digestDate: digest?.date)
            await reloadMarks()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadMarks() async {
        guard let store, let digest = currentDigest else {
            marks = PaperMarks()
            return
        }
        let ids = digest.papers.map(\.id)
        do {
            marks = PaperMarks(feedback: try await store.feedback(paperIDs: ids), read: try await store.readPaperIDs(among: ids))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshStatus() async {
        guard let store else { return }
        do {
            schedulerStatus = try await SchedulerStatusBuilder.build(
                store: store, config: config, probe: SystemLaunchctl(),
                home: FileManager.default.homeDirectoryForCurrentUser, now: Date())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadConfig() {
        do {
            config = try Config.load(home: paths.home)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Messages from the digest page

    /// `verdict` 0 clears the paper's feedback.
    func setFeedback(paperID: String, verdict: Int) async {
        guard let store else { return }
        do {
            try await store.setFeedback(paperID: paperID, verdict: Verdict(rawValue: verdict), digestDate: currentDigest?.date)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadMarks()          // the page always ends up showing what is stored
    }

    func setRead(paperID: String, read: Bool) async {
        guard let store else { return }
        do {
            try await store.setRead(paperID: paperID, read: read)
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadMarks()
        await reloadList()           // unread badges
    }

    func open(urlString: String) {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    /// A page `quote` message -> `DigestCore.Quote` with the title from the open digest. Without a paper (a cluster
    /// narrative that cites none) `paperID` is empty and the title is the cluster's name.
    func addQuote(paperID: String?, clusterID: String?, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let paper = paperID.flatMap { id in currentDigest?.papers.first { $0.id == id } }
        let cluster = clusterID.flatMap { id in currentDigest?.clusters.first { $0.id == id } }
        let title = paper?.title ?? cluster?.name ?? currentDigest?.title ?? "Digest"
        chat.addQuote(Quote(paperID: paper?.id ?? paperID ?? "", title: title, clusterID: clusterID, text: String(trimmed.prefix(4000))))
        showChat = true
    }

    // MARK: Window and runs

    func showMainWindow(date: String? = nil) {
        NSApp.setActivationPolicy(.regular)
        if let date { selection = latestItem(date: date) }
        openMainWindowAction?()
        NSApp.activate()
    }

    /// Manual run. Re-running a day that already has a digest adds a new edition with only not-yet-shown papers and spends the digest call again,
    /// so that case asks first.
    func requestManualRun(categories: [String]?) {
        guard !runner.isRunning else { return }
        if hasTodayDigest {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Make another edition of today's digest?"
            alert.informativeText = "Today already has a digest. Running again adds a new edition with papers not shown yet (the current one stays) and spends another digest call (about $2-3)."
            alert.addButton(withTitle: "Run Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        startRun(categories: categories)
    }

    /// Quit with a chat answer or a run in flight: stop them and wait until their usage is recorded, at most `limit`.
    func stopForQuit(limit: Duration) async {
        chat.cancelInFlight()
        runner.cancel()
        let deadline = ContinuousClock.now + limit
        while chat.isSending || runner.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func startRun(categories: [String]?) {
        do {
            try runner.start(categories: categories, store: store) { [weak self] in
                guard let self else { return }
                await self.reloadAll()
                // A run adds an edition of today: from nothing or an older edition of today, move to the newest.
                switch self.selection {
                case nil: self.selection = self.latestItem(date: self.today)
                case let .digest(date, _)? where date == self.today: self.selection = self.latestItem(date: self.today)
                default: break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
