import DigestCore
import Observation
import SwiftUI

/// "All papers": FTS over every stored paper (`Store.searchPapers`).
@Observable @MainActor
final class PaperSearchModel {
    var query = ""
    private(set) var results: [RawPaper] = []
    private(set) var message: String?
    var selectedID: String?

    var selected: RawPaper? { results.first { $0.id == selectedID } }

    func search(store: Store?) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !q.isEmpty else {
            results = []
            message = nil
            return
        }
        do {
            results = try await store.searchPapers(Self.ftsQuery(q))
            message = results.isEmpty ? "No papers match \"\(q)\"." : nil
        } catch {
            results = []
            message = error.localizedDescription
        }
    }

    /// User text -> FTS5 query: each word quoted (so `-`, `:` and quotes are literal), prefix match, AND-ed.
    static func ftsQuery(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
            .joined(separator: " ")
    }
}

struct PaperSearchView: View {
    let store: Store?
    @State private var search = PaperSearchModel()

    var body: some View {
        // Not HSplitView: it turns its children's sizes into a window minimum wider than the screen (the window then
        // grows off-screen and cannot be resized). A plain HStack only adds the two minimums.
        HStack(spacing: 0) {
            List(search.results, id: \.id, selection: $search.selectedID) { paper in
                VStack(alignment: .leading, spacing: 2) {
                    Text(paper.title).lineLimit(2)
                    Text("\(paper.id) / \(paper.primaryCategory ?? paper.categories.first ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(paper.id)
            }
            .frame(minWidth: 160, idealWidth: 320, maxWidth: 360)
            .overlay {
                if let message = search.message {
                    ContentUnavailableView(message, systemImage: "magnifyingglass")
                } else if search.query.isEmpty {
                    ContentUnavailableView("Search all papers", systemImage: "magnifyingglass",
                                           description: Text("Titles, abstracts and full texts of every paper seen."))
                }
            }
            Divider()
            Group {
                if let paper = search.selected {
                    PaperDetail(paper: paper)
                } else {
                    Color.clear
                }
            }
            .frame(minWidth: 180, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search.query, prompt: "Search papers")
        .task(id: search.query) {
            try? await Task.sleep(for: .milliseconds(250))      // debounce typing
            guard !Task.isCancelled else { return }
            await search.search(store: store)
        }
    }
}

struct PaperDetail: View {
    @Environment(AppModel.self) private var model
    let paper: RawPaper

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(paper.title).font(.title3.bold()).textSelection(.enabled)
                Text(paper.authors.prefix(12).joined(separator: ", ") + (paper.authors.count > 12 ? " et al." : ""))
                    .font(.callout).foregroundStyle(.secondary)
                Text("\(paper.source == .arxiv ? "\(paper.id)v\(paper.version)" : paper.venue ?? paper.id) / \(paper.categories.joined(separator: ", ")) / \(paper.published.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if let abs = paper.absURL { Button(paper.source == .openalex ? (paper.doi != nil ? "DOI" : "OpenAlex") : "abs") { model.open(urlString: abs.absoluteString) } }
                    if let pdf = paper.pdfURL { Button("PDF") { model.open(urlString: pdf.absoluteString) } }
                }
                Text(paper.abstract).textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
