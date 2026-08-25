import Foundation

/// A stored digest as Markdown for `digest-cli show`: clusters -> their papers, then the unclustered ones.
/// `[id]` citations become links to the paper's abs page; figures point at the local file.
public enum DigestMarkdown {
    public static func render(_ d: Digest, home: URL) -> String {
        var out = "# \(d.title) - \(d.date)\n\n"
        if d.partial { out += "> Partial run: not every stage completed (see `digest-cli status`).\n\n" }
        out += "\(link(d.summary, d))\n\n"
        if d.empty { return out.trimmingCharacters(in: .newlines) + "\n" }
        if !d.trendNotes.isEmpty { out += "**Trend.** \(link(d.trendNotes, d))\n\n" }

        let byID = Dictionary(d.papers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rank = Dictionary(d.papers.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { a, _ in a })
        for c in d.clusters {
            out += "## \(c.name)\n\n\(link(c.narrative, d))\n\n"
            for id in c.paperIDs { if let p = byID[id] { out += paper(p, rank: rank[id] ?? 0, d, home: home) } }
        }
        let loose = d.papers.filter { $0.clusterID.isEmpty }
        if !loose.isEmpty {
            if !d.clusters.isEmpty { out += "## Other papers\n\n" }
            for p in loose { out += paper(p, rank: rank[p.id] ?? 0, d, home: home) }
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }

    private static func paper(_ p: DigestPaper, rank: Int, _ d: Digest, home: URL) -> String {
        var out = "### \(rank). \(p.title)\n\n"
        var meta = ["`\(p.id)`", "score \(p.score)"]
        if !p.tags.isEmpty { meta.append(p.tags.joined(separator: ", ")) }
        for (name, url) in [("abs", p.links.abs), ("html", p.links.html), ("pdf", p.links.pdf)] {
            if let url { meta.append("[\(name)](\(url.absoluteString))") }
        }
        out += meta.joined(separator: " / ") + "\n\n"
        if p.modelOmitted { out += "*Not covered by the digest model; triage note:* " }
        out += "\(link(p.essence, d))\n\n"
        if let f = p.figure { out += "![\(f.caption)](\(home.appendingPathComponent(f.path).path))\n\n" }
        if !p.detail.isEmpty { out += "\(link(p.detail, d))\n\n" }
        if !p.whyItMatters.isEmpty { out += "**Why it matters.** \(link(p.whyItMatters, d))\n\n" }
        if !p.caveats.isEmpty { out += "**Caveats.** \(link(p.caveats, d))\n\n" }
        if !p.mermaid.isEmpty { out += "```mermaid\n\(p.mermaid)\n```\n\n" }
        return out
    }

    /// `[2610.12345]` -> `[2610.12345](abs link)` for papers in this digest.
    static func link(_ text: String, _ d: Digest) -> String {
        var out = text
        for p in d.papers {
            guard let abs = p.links.abs else { continue }
            out = out.replacingOccurrences(of: "[\(p.id)]", with: "[\(p.id)](\(abs.absoluteString))")
        }
        return out
    }
}
