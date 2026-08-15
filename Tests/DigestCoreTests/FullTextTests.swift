import Foundation
import ImageIO
import Testing
@testable import DigestCore

@Suite struct FullTextTests {
    static let id = "2610.28632"

    func paper() throws -> RawPaper {
        var p = try samplePaper(Self.id)
        p.pdfURL = URL(string: "https://arxiv.org/pdf/\(Self.id)v1")
        return p
    }

    func fetcher(_ transport: MockTransport) -> ArxivFullTextFetcher {
        ArxivFullTextFetcher(transport: transport, rateLimiter: RateLimiter(minInterval: 3, sleep: { _ in }))
    }

    @Test func latexmlConversion() throws {
        let doc = try LaTeXMLDocument(html: String(decoding: try TestSupport.fixture("fulltext/2610.28632v1.html"), as: UTF8.self))
        let text = doc.text
        if ProcessInfo.processInfo.environment["DUMP_FULLTEXT"] == "1" { print(text) }
        #expect(text.hasPrefix("# Joints, Camera, Action!"))
        #expect(text.contains("\n\n## 1 Introduction\n\n"))
        #expect(text.contains("[Figure 2: Architecture overview. Given a text prompt"))
        #expect(text.contains("video latents $Z_{v}$ and motion tokens $Z_{m}$"))
        #expect(text.contains("[Table 2: Joint video–human-motion generation."))
        #expect(text.contains("[Appendix omitted]"))
        #expect(!text.contains("Simons Foundation"))      // site footer
        #expect(!text.contains("References\n"))            // bibliography
        #expect(!text.contains("<"))
        #expect(!text.contains("  "))
        #expect(doc.figures.count == 6)
        #expect(doc.figures.first == .init(src: "2610.28632v1/teaser_v9.png", caption: doc.figures[0].caption))
        #expect(doc.figures[1].caption.hasPrefix("Architecture overview."))
        #expect(!doc.figures.contains { $0.caption.hasPrefix("Figure") })
    }

    @Test func htmlFetchKeepsFirstTwoFiguresThatDownload() async throws {
        let png = try TestSupport.fixture("fulltext/2610.28632v1.fig1.png")
        let transport = MockTransport([
            .init(status: 200, body: try TestSupport.fixture("fulltext/2610.28632v1.html")),
            .init(status: 404, body: Data()),                 // figure 1 fails
            .init(status: 200, body: Data("<html>not an image</html>".utf8)),  // figure 2 undecodable
            .init(status: 200, body: png),                    // figure 3 -> index 1
            .init(status: 200, body: png),                    // figure 4 -> index 2
        ])
        let result = try await fetcher(transport).fetch(try paper())
        #expect(result.source == .html)
        #expect(result.figures.count == 2)
        #expect(result.figures[0].caption.hasPrefix("Comparison") || !result.figures[0].caption.isEmpty)
        let urls = transport.requests.compactMap { $0.url?.absoluteString }
        #expect(urls == [
            "https://arxiv.org/html/2610.28632v1",
            "https://arxiv.org/html/2610.28632v1/teaser_v9.png",
            "https://arxiv.org/html/2610.28632v1/rig_Architecture.png",
            "https://arxiv.org/html/2610.28632v1/figures/t2m_comp_v5.png",
            "https://arxiv.org/html/2610.28632v1/extra_results.png",
        ])
        let source = try #require(CGImageSourceCreateWithData(result.figures[0].image as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
    }

    @Test func fallsBackToUnversionedHTMLThenPDF() async throws {
        let transport = MockTransport([
            .init(status: 404, body: Data()), .init(status: 404, body: Data()),
            .init(status: 200, body: try TestSupport.fixture("fulltext/2610.28632v1.pdf")),
        ])
        let result = try await fetcher(transport).fetch(try paper())
        #expect(result.source == .pdf)
        #expect(result.figures.isEmpty)
        #expect(result.text.contains("Joints, Camera, Action!"))
        #expect(transport.requests.compactMap { $0.url?.absoluteString } == [
            "https://arxiv.org/html/2610.28632v1", "https://arxiv.org/html/2610.28632", "https://arxiv.org/pdf/2610.28632v1",
        ])
    }

    @Test func otherHTTPFailureIsAnError() async throws {
        let transport = MockTransport([.init(status: 500, body: Data())])
        await #expect(throws: FullTextError.http(status: 500, url: "https://arxiv.org/html/2610.28632v1")) {
            try await fetcher(transport).fetch(try paper())
        }
        #expect(transport.requests.count == 1)
    }

    @Test func figureIsDownscaledToMaxSide() throws {
        let png = try TestSupport.fixture("fulltext/2610.28632v1.fig1.png")
        let small = try #require(ArxivFullTextFetcher.reencodePNG(png, maxSide: 200))
        let source = try #require(CGImageSourceCreateWithData(small as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0) == 200)
        #expect(ArxivFullTextFetcher.reencodePNG(Data("nope".utf8), maxSide: 200) == nil)
    }

    @Test func truncationAndDehyphenation() {
        let text = "para one\n\npara two is long\n\npara three"
        #expect(FullText.truncate(text, maxChars: 100) == text)
        #expect(FullText.truncate(text, maxChars: 30) == "para one\n\npara two is long\n[... truncated]")
        #expect(FullText.truncate("no breaks here", maxChars: 5) == "no br\n[... truncated]")
        #expect(PDFText.dehyphenate("an exam-\nple of GPT-\n4") == "an example of GPT-\n4")
    }

    @Test func entitiesAndTolerantParsing() throws {
        #expect(HTMLParser.decodeEntities("a &amp; b &lt;c&gt; &#x3B1; &#946; &bogus; &") == "a & b <c> α β &bogus; &")
        let doc = try LaTeXMLDocument(html: """
            <html><body><article class="ltx_document"><h2 class="ltx_title">Intro</h2>
            <p class="ltx_p">Unclosed <b>bold <i>and</b> text<br>more</p><script>var x = "<p>";</script>
            <ul><li>one</li><li>two</li></ul><h3>Plain heading</h3></article></body></html>
            """)
        #expect(doc.text == "## Intro\n\nUnclosed bold and text more\n\n- one\n\n- two\n\nPlain heading")
    }
}
