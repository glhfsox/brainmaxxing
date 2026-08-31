import SwiftUI

/// One arXiv category from the bundled taxonomy (`arxiv-taxonomy.json`).
struct ArxivCategory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String

    static let all: [ArxivCategory] = {
        guard let url = Bundle.main.url(forResource: "arxiv-taxonomy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([ArxivCategory].self, from: data)
        else { return [] }
        return list
    }()

    /// Case-insensitive match on id or name; empty query matches everything.
    static func filter(_ list: [ArxivCategory], query: String) -> [ArxivCategory] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter { $0.id.localizedCaseInsensitiveContains(q) || $0.name.localizedCaseInsensitiveContains(q) }
    }
}

/// Multi-select over the taxonomy with search. Selected categories stay in their original order; new ones append.
struct CategoryPicker: View {
    @Binding var selection: [String]
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selection.isEmpty ? "No categories selected" : selection.joined(separator: "  "))
                .font(.caption.monospaced())
                .foregroundStyle(selection.isEmpty ? .red : .secondary)
                .lineLimit(3)
            TextField("Search categories", text: $query)
                .textFieldStyle(.roundedBorder)
            List(ArxivCategory.filter(ArxivCategory.all, query: query)) { category in
                Toggle(isOn: binding(for: category.id)) {
                    HStack {
                        Text(category.id).font(.body.monospaced()).frame(width: 140, alignment: .leading)
                        Text(category.name).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.bordered)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding {
            selection.contains(id)
        } set: { on in
            if on, !selection.contains(id) { selection.append(id) }
            if !on { selection.removeAll { $0 == id } }
        }
    }
}
