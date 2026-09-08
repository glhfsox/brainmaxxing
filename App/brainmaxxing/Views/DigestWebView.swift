import AppKit
import DigestCore
import SwiftUI
import WebKit

/// The digest page. The bundled `DigestWeb/` is copied into `<home>/web/` so that one
/// `allowingReadAccessTo: home` covers the page, its vendored libraries and the figures under `<home>/figures/`.
struct DigestWebView: NSViewRepresentable {
    let digest: Digest
    let marks: PaperMarks
    let home: URL
    let onMessage: @MainActor (DigestPageMessage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        coordinator.onMessage = onMessage
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(coordinator), name: "digest")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        coordinator.attach(webView, home: home)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onMessage = onMessage
        context.coordinator.show(digest: digest, marks: marks, home: home)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "digest")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var onMessage: (@MainActor (DigestPageMessage) -> Void)?
        private weak var webView: WKWebView?
        private var pageURL: URL?
        private var pageLoaded = false
        private var renderedKey: String?
        /// What should be on screen; re-sent after a page (re)load.
        private var latest: (digest: Digest, marks: PaperMarks, home: URL)?
        private var keyMonitor: Any?

        func attach(_ webView: WKWebView, home: URL) {
            self.webView = webView
            // Cmd-Shift-L quotes the current selection.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift],
                      event.charactersIgnoringModifiers?.lowercased() == "l",
                      let self, let webView = self.webView, webView.window?.isKeyWindow == true
                else { return event }
                webView.evaluateJavaScript("window.quoteSelection && window.quoteSelection()")
                return nil
            }
            Task { await load(home: home) }
        }

        func detach() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        private func load(home: URL) async {
            guard let webView else { return }
            do {
                // Every non-file: load is blocked: the page is offline.
                if let rules = try await WKContentRuleListStore.default()?.compileContentRuleList(
                    forIdentifier: "brainmaxxing.offline", encodedContentRuleList: Self.offlineRules) {
                    webView.configuration.userContentController.add(rules)
                }
                let page = try await WebBundle.page(home: home)
                pageURL = page
                webView.loadFileURL(page, allowingReadAccessTo: home)
            } catch {
                onMessage?(.failure("Digest page could not load: \(error.localizedDescription)"))
            }
        }

        static let offlineRules = """
            [{"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
             {"trigger": {"url-filter": "^file:"}, "action": {"type": "ignore-previous-rules"}}]
            """

        func show(digest: Digest, marks: PaperMarks, home: URL) {
            latest = (digest, marks, home)
            flush()
        }

        private func flush() {
            guard pageLoaded, let webView, let (digest, marks, home) = latest else { return }
            let key = "\(digest.date)|\(digest.runID)|\(digest.generatedAt.timeIntervalSince1970)"
            let state = WebState(marks: marks, home: home)
            do {
                let stateJSON = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
                if key == renderedKey {
                    webView.callAsyncJavaScript("window.setState(JSON.parse(s))", arguments: ["s": stateJSON], in: nil, in: .page)
                    return
                }
                renderedKey = key
                let digestJSON = String(decoding: try Digest.encoder.encode(digest), as: UTF8.self)
                webView.callAsyncJavaScript("await window.render(JSON.parse(d), JSON.parse(s)); return true",
                                            arguments: ["d": digestJSON, "s": stateJSON], in: nil, in: .page) { [weak self] result in
                    if case let .failure(error) = result {
                        self?.onMessage?(.failure("Digest page error: \(error.localizedDescription)"))
                    }
                }
            } catch {
                onMessage?(.failure(error.localizedDescription))
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url.isFileURL, url.path == pageURL?.path { return .allow }
            // Links are handled by the page; anything that still navigates goes to the browser, never into the view.
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { onMessage?(.open(url.absoluteString)) }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pageLoaded = true
            renderedKey = nil
            flush()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            pageLoaded = false
            renderedKey = nil
            webView.reload()
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let parsed = DigestPageMessage(body) else { return }
            onMessage?(parsed)
        }
    }
}

/// `state` argument of `window.render` / `window.setState`.
struct WebState: Encodable {
    var feedback: [String: Int]
    var read: [String]
    var figureBase: String

    init(marks: PaperMarks, home: URL) {
        feedback = marks.feedback.mapValues(\.rawValue)
        read = marks.read.sorted()
        figureBase = home.absoluteURL.absoluteString.hasSuffix("/") ? home.absoluteURL.absoluteString : home.absoluteURL.absoluteString + "/"
    }
}

/// JS -> Swift messages, validated at the boundary.
enum DigestPageMessage: Equatable {
    case feedback(paperID: String, verdict: Int)
    case read(paperID: String, read: Bool)
    case open(String)
    case quote(paperID: String?, clusterID: String?, text: String)
    /// Not from the page: a load/render failure reported by the bridge.
    case failure(String)

    init?(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "feedback":
            guard let id = body["paperId"] as? String, let v = body["verdict"] as? Int, [-1, 0, 1].contains(v) else { return nil }
            self = .feedback(paperID: id, verdict: v)
        case "read":
            guard let id = body["paperId"] as? String, let read = body["read"] as? Bool else { return nil }
            self = .read(paperID: id, read: read)
        case "open":
            guard let url = body["url"] as? String else { return nil }
            self = .open(url)
        case "quote":
            guard let text = body["text"] as? String else { return nil }
            self = .quote(paperID: body["paperId"] as? String, clusterID: body["clusterId"] as? String, text: text)
        default:
            return nil
        }
    }
}

/// `WKUserContentController` retains its handlers; this breaks the cycle with the coordinator.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Copies the bundled `DigestWeb/` into `<home>/web/` (replacing what is there, so an app update never serves a
/// stale page) and returns the URL of its `index.html`.
enum WebBundle {
    enum Failure: LocalizedError {
        case missing
        var errorDescription: String? { "DigestWeb is missing from the app bundle" }
    }

    /// The copy is made once per launch, off the main actor; later web views reuse it. A failed copy is retried.
    @MainActor private static var installed: Task<URL, Error>?

    @MainActor static func page(home: URL) async throws -> URL {
        let task = installed ?? Task.detached { try install(home: home) }
        installed = task
        do {
            return try await task.value
        } catch {
            if installed == task { installed = nil }
            throw error
        }
    }

    static func install(home: URL) throws -> URL {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("DigestWeb", isDirectory: true),
              FileManager.default.fileExists(atPath: source.appendingPathComponent("index.html").path)
        else { throw Failure.missing }
        let fm = FileManager.default
        let dest = home.appendingPathComponent("web", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
        return dest.appendingPathComponent("index.html")
    }
}
