import Foundation

/// Minimal tolerant HTML tree: enough for arXiv's LaTeXML output (well-formed HTML5 with MathML).
/// libxml2's HTML parser (XMLDocument tidy) drops `<figure>` and `<math>`, hence this.
struct HTMLElement {
    enum Child { case text(String), element(HTMLElement) }

    var name: String
    var attributes: [String: String]
    var children: [Child] = []

    func hasClass(_ token: String) -> Bool {
        attributes["class"]?.split(separator: " ").contains { $0 == token } ?? false
    }

    /// Depth-first search, not descending into matches.
    func first(where match: (HTMLElement) -> Bool) -> HTMLElement? {
        for case let .element(e) in children {
            if match(e) { return e }
            if let found = e.first(where: match) { return found }
        }
        return nil
    }

    func all(where match: (HTMLElement) -> Bool) -> [HTMLElement] {
        var out: [HTMLElement] = []
        for case let .element(e) in children {
            if match(e) { out.append(e) } else { out += e.all(where: match) }
        }
        return out
    }
}

enum HTMLParser {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
                                            "param", "source", "track", "wbr"]
    static let rawTextElements: Set<String> = ["script", "style"]

    static func parse(_ html: String) -> HTMLElement {
        let b = Array(html.utf8)
        let n = b.count
        var stack = [HTMLElement(name: "#root", attributes: [:])]
        var i = 0
        var textStart = 0

        func flushText(_ end: Int) {
            if end > textStart {
                stack[stack.count - 1].children.append(.text(decodeEntities(String(decoding: b[textStart..<end], as: UTF8.self))))
            }
        }
        func popOne() {
            let e = stack.removeLast()
            stack[stack.count - 1].children.append(.element(e))
        }
        func find(_ pattern: String, from start: Int) -> Int? {
            let p = Array(pattern.utf8)
            var j = start
            while j + p.count <= n {
                if b[j] == p[0], Array(b[j..<j + p.count]).map(lower) == p { return j }
                j += 1
            }
            return nil
        }
        func skipTo(_ byte: UInt8, from start: Int) -> Int {
            var j = start
            while j < n, b[j] != byte { j += 1 }
            return min(j + 1, n)
        }
        func isNameByte(_ c: UInt8) -> Bool {
            (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 45 || c == 58 || c == 95 || c == 46
        }
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 || c == 12 }

        while i < n {
            guard b[i] == 60, i + 1 < n else { i += 1; continue }  // '<'
            let next = b[i + 1]
            if next == 33 {  // '!'
                flushText(i)
                if i + 3 < n, b[i + 2] == 45, b[i + 3] == 45 {
                    i = (find("-->", from: i + 4).map { $0 + 3 }) ?? n
                } else {
                    i = skipTo(62, from: i)
                }
                textStart = i
                continue
            }
            if next == 63 {  // '?'
                flushText(i)
                i = skipTo(62, from: i)
                textStart = i
                continue
            }
            if next == 47 {  // '/': end tag
                flushText(i)
                var j = i + 2
                while j < n, isNameByte(b[j]) { j += 1 }
                let name = String(decoding: b[(i + 2)..<j], as: UTF8.self).lowercased()
                i = skipTo(62, from: j)
                textStart = i
                if let depth = stack.lastIndex(where: { $0.name == name }), depth > 0 {
                    while stack.count > depth { popOne() }
                }
                continue
            }
            guard (next >= 97 && next <= 122) || (next >= 65 && next <= 90) else { i += 1; continue }
            flushText(i)
            var j = i + 1
            while j < n, isNameByte(b[j]) { j += 1 }
            let name = String(decoding: b[(i + 1)..<j], as: UTF8.self).lowercased()
            var attributes: [String: String] = [:]
            var selfClosing = false
            while j < n {
                while j < n, isSpace(b[j]) { j += 1 }
                guard j < n else { break }
                if b[j] == 62 { j += 1; break }
                if b[j] == 47 { selfClosing = true; j += 1; continue }
                let nameStart = j
                while j < n, !isSpace(b[j]), b[j] != 61, b[j] != 62, b[j] != 47 { j += 1 }
                let attr = String(decoding: b[nameStart..<j], as: UTF8.self).lowercased()
                if j == nameStart { j += 1; continue }
                selfClosing = false
                while j < n, isSpace(b[j]) { j += 1 }
                var value = ""
                if j < n, b[j] == 61 {
                    j += 1
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j < n, b[j] == 34 || b[j] == 39 {
                        let quote = b[j]
                        let start = j + 1
                        j = start
                        while j < n, b[j] != quote { j += 1 }
                        value = String(decoding: b[start..<min(j, n)], as: UTF8.self)
                        j += 1
                    } else {
                        let start = j
                        while j < n, !isSpace(b[j]), b[j] != 62 { j += 1 }
                        value = String(decoding: b[start..<j], as: UTF8.self)
                    }
                }
                attributes[attr] = decodeEntities(value)
            }
            i = j
            textStart = i
            let element = HTMLElement(name: name, attributes: attributes)
            if rawTextElements.contains(name) {
                i = (find("</\(name)", from: i).map { skipTo(62, from: $0) }) ?? n
                textStart = i
                stack[stack.count - 1].children.append(.element(element))
            } else if selfClosing || voidElements.contains(name) {
                stack[stack.count - 1].children.append(.element(element))
            } else {
                stack.append(element)
            }
        }
        flushText(n)
        while stack.count > 1 { popOne() }
        return stack[0]
    }

    private static func lower(_ c: UInt8) -> UInt8 { (c >= 65 && c <= 90) ? c + 32 : c }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—",
        "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "times": "×", "minus": "−",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = s[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let entity = after[..<semi]
                var decoded: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = namedEntities[String(entity)]
                }
                if let decoded {
                    out += decoded
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        return out + rest
    }
}

/// LaTeXML HTML -> plain text with light Markdown, plus figure candidates.
struct LaTeXMLDocument {
    struct FigureCandidate: Equatable { var src: String; var caption: String }

    let text: String
    let figures: [FigureCandidate]

    init(html: String) throws {
        let root = HTMLParser.parse(html)
        guard let document = root.first(where: { $0.hasClass("ltx_document") }) ?? root.first(where: { $0.hasClass("ltx_page_content") })
        else { throw FullTextError.parse("no LaTeXML document in the page") }
        var renderer = Renderer()
        renderer.render(document)
        renderer.flush()
        text = renderer.blocks.joined(separator: "\n\n")
        guard !text.isEmpty else { throw FullTextError.parse("LaTeXML document has no text") }

        figures = document.all { $0.name == "figure" && $0.hasClass("ltx_figure") }.compactMap { figure in
            let images = figure.all { $0.name == "img" }.compactMap { $0.attributes["src"] }
            guard let src = images.first(where: { !$0.lowercased().hasSuffix(".svg") && !$0.contains("arxiv-logo") }) else { return nil }
            return FigureCandidate(src: src, caption: Renderer.caption(of: figure).text)
        }
    }

    struct Renderer {
        var blocks: [String] = []
        var inline = ""
        var appendixNoted = false
        var skipTags = false

        static let dropped: Set<String> = ["nav", "header", "footer", "script", "style", "button", "form"]
        static let blockElements: Set<String> = ["p", "div", "section", "article", "li", "blockquote", "dd", "dt", "ul", "ol",
                                                 "dl", "h1", "h2", "h3", "h4", "h5", "h6", "figcaption", "main", "body"]

        mutating func flush() {
            let collapsed = inline.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !collapsed.isEmpty { blocks.append(collapsed) }
            inline = ""
        }

        mutating func renderChildren(_ e: HTMLElement) {
            for child in e.children {
                switch child {
                case let .text(t): inline += t
                case let .element(c): render(c)
                }
            }
        }

        mutating func render(_ e: HTMLElement) {
            if Self.dropped.contains(e.name) || e.hasClass("ltx_page_footer") || e.hasClass("ltx_bibliography") { return }
            if skipTags, e.hasClass("ltx_tag") { return }
            if e.hasClass("ltx_appendix") {
                flush()
                if !appendixNoted { blocks.append("[Appendix omitted]") }
                appendixNoted = true
                return
            }
            if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(e.name), e.hasClass("ltx_title") {
                flush()
                let level = Int(e.name.dropFirst()) ?? 1
                let title = Self.inlineText(e)
                if !title.isEmpty { blocks.append(String(repeating: "#", count: level) + " " + title) }
                return
            }
            switch e.name {
            case "math":
                let tex = e.attributes["alttext"] ?? Self.inlineText(e)
                inline += "$\(tex)$"
            case "figure":
                flush()
                let (tag, caption) = Self.caption(of: e)
                let kind = e.hasClass("ltx_table") ? "Table" : "Figure"
                let label = tag.isEmpty ? kind : tag
                blocks.append(caption.isEmpty ? "[\(label)]" : "[\(label): \(caption)]")
            case "table":
                guard e.hasClass("ltx_equation") || e.hasClass("ltx_equationgroup") else { return }
                flush()
                renderChildren(e)
                flush()
            case "br":
                inline += " "
            case "img", "svg", "button":
                return
            default:
                if Self.blockElements.contains(e.name) {
                    flush()
                    if e.name == "li" { inline += "- " }
                    renderChildren(e)
                    flush()
                } else {
                    renderChildren(e)
                }
            }
        }

        static func inlineText(_ e: HTMLElement, skipTags: Bool = false) -> String {
            var r = Renderer()
            r.skipTags = skipTags
            r.renderChildren(e)
            r.flush()
            return r.blocks.joined(separator: " ")
        }

        /// (`"Figure 2"`, caption without the tag) of a `<figure>`.
        static func caption(of figure: HTMLElement) -> (tag: String, text: String) {
            let direct = figure.children.lazy.compactMap { child -> HTMLElement? in
                if case let .element(e) = child, e.name == "figcaption" { return e }
                return nil
            }.first
            guard let figcaption = direct ?? figure.first(where: { $0.name == "figcaption" }) else { return ("", "") }
            var tag = figcaption.first(where: { $0.hasClass("ltx_tag") }).map { inlineText($0) } ?? ""
            while tag.hasSuffix(":") || tag.hasSuffix(".") { tag.removeLast() }
            return (tag.trimmingCharacters(in: .whitespaces), inlineText(figcaption, skipTags: true))
        }
    }
}
