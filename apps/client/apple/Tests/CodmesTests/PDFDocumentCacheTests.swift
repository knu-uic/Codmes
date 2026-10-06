import PDFKit
import XCTest
@testable import Codmes

#if os(macOS)
@MainActor
final class PDFDocumentCacheTests: XCTestCase {
    private func writePDF(to url: URL, pageCount: Int) throws {
        let document = PDFDocument()
        for index in 0..<pageCount { document.insert(PDFPage(), at: index) }
        XCTAssertTrue(document.write(to: url))
    }

    func testStatusUpdatesKeepDocumentAndReadingPosition() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codmes-pdf-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("book.pdf")
        try writePDF(to: url, pageCount: 3)
        let cache = PDFDocumentCache()
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.document = try XCTUnwrap(cache.document(for: url))
        let page = try XCTUnwrap(view.document?.page(at: 2))
        view.go(to: page)
        view.scaleFactor = 1.5

        for _ in 0..<10 {
            let document = cache.document(for: url)
            if view.document !== document { view.document = document }
        }

        XCTAssertTrue(view.document === cache.document(for: url))
        XCTAssertTrue(view.currentPage === page)
        XCTAssertEqual(view.scaleFactor, 1.5, accuracy: 0.001)
    }

    func testChangedFileURLLoadsNewDocument() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codmes-pdf-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("first.pdf")
        let secondURL = directory.appendingPathComponent("second.pdf")
        try writePDF(to: firstURL, pageCount: 1)
        try writePDF(to: secondURL, pageCount: 2)
        let cache = PDFDocumentCache()
        let first = try XCTUnwrap(cache.document(for: firstURL))
        let second = try XCTUnwrap(cache.document(for: secondURL))
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.pageCount, 2)
        XCTAssertTrue(second === cache.document(for: secondURL))
    }
}
#endif
