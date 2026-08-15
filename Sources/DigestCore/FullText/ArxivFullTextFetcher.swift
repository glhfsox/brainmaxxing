import Foundation
import ImageIO
import PDFKit
import os

/// arXiv HTML first (`/html/<id>v<n>`, then `/html/<id>`), PDF via PDFKit on 404.
/// Every request goes through the shared arXiv `RateLimiter`, so fetches are effectively sequential.
public struct ArxivFullTextFetcher: FullTextFetcher {
    public static let maxFigures = 2
    public static let maxFigureSide = 1600

    private let transport: HTTPTransport
    private let rateLimiter: RateLimiter
    private static let log = Logger(subsystem: "com.brainmaxxing", category: "fulltext")

    public init(transport: HTTPTransport = URLSessionTransport(), rateLimiter: RateLimiter) {
        self.transport = transport
        self.rateLimiter = rateLimiter
    }

    public func fetch(_ paper: RawPaper) async throws -> FullTextResult {
        let candidates = ["https://arxiv.org/html/\(paper.id)v\(paper.version)", "https://arxiv.org/html/\(paper.id)"]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            guard let (data, finalURL) = try await get(url) else { continue }  // 404 -> next
            let document = try LaTeXMLDocument(html: String(decoding: data, as: UTF8.self))
            let figures = await downloadFigures(document.figures, base: finalURL)
            return FullTextResult(text: document.text, figures: figures, source: .html)
        }
        guard let pdfURL = paper.pdfURL ?? URL(string: "https://arxiv.org/pdf/\(paper.id)v\(paper.version)"),
              let (pdf, _) = try await get(pdfURL)
        else { throw FullTextError.notAvailable(paper.id) }
        // TODO(pipeline): PDF figures (CGPDFScanner image XObjects + nearest "Figure N" caption); text only for now.
        return FullTextResult(text: try PDFText.extract(pdf), figures: [], source: .pdf)
    }

    /// Body and final URL; nil on 404; throws on any other non-200.
    private func get(_ url: URL) async throws -> (Data, URL)? {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(ArxivClient.userAgent, forHTTPHeaderField: "User-Agent")
        try await rateLimiter.wait()
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw FullTextError.transport(error.localizedDescription)
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw FullTextError.http(status: response.statusCode, url: url.absoluteString) }
        return (data, response.url ?? url)
    }

    /// First `maxFigures` candidates that download and decode; failures are skipped, never thrown.
    private func downloadFigures(_ candidates: [LaTeXMLDocument.FigureCandidate], base: URL) async -> [(image: Data, caption: String)] {
        var kept: [(image: Data, caption: String)] = []
        for candidate in candidates {
            guard kept.count < Self.maxFigures else { break }
            // `src` is relative to the document URL: "2610.28632v1/x.png" against ".../html/2610.28632v1".
            guard let url = URL(string: candidate.src, relativeTo: base)?.absoluteURL else { continue }
            do {
                guard let (data, _) = try await get(url), let png = Self.reencodePNG(data, maxSide: Self.maxFigureSide) else {
                    Self.log.notice("figure \(url.absoluteString, privacy: .public) missing or undecodable; skipped")
                    continue
                }
                kept.append((png, candidate.caption))
            } catch {
                Self.log.notice("figure \(url.absoluteString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return kept
    }

    /// Decodes any ImageIO format and writes PNG, longest side <= `maxSide`. Nil if the data is not an image.
    static func reencodePNG(_ data: Data, maxSide: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let image: CGImage?
        if max(width, height) > maxSide {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}

/// PDF text via PDFKit: pages joined with blank lines, end-of-line hyphenation repaired.
public enum PDFText {
    public static func extract(_ data: Data) throws -> String {
        guard let document = PDFDocument(data: data) else { throw FullTextError.parse("not a readable PDF") }
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
        let text = dehyphenate(pages.joined(separator: "\n\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FullTextError.parse("PDF has no extractable text") }
        return text
    }

    /// `exam-\nple` -> `example` (lowercase on both sides, so `GPT-\n4` stays as is).
    static func dehyphenate(_ text: String) -> String {
        text.replacing(/(\p{Ll})-\r?\n(\p{Ll})/) { "\($0.1)\($0.2)" }
    }
}
