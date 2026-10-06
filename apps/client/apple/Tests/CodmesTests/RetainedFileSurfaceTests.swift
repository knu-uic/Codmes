#if os(macOS)
import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import Codmes

@MainActor
final class RetainedFileSurfaceTests: XCTestCase {
    private struct Surfaces: View {
        @ObservedObject var store: WorkspaceStore
        let active: String
        var body: some View {
            ZStack {
                ForEach(["notes", "code"].filter { store.retainedFileSurfaces.contains($0) || active == $0 }, id: \.self) {
                    RetainedFileSurfaceView(surface: $0, isActive: active == $0)
                }
            }.environmentObject(store)
        }
    }

    private func pdfView(in view: NSView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.lazy.compactMap { self.pdfView(in: $0) }.first
    }

    private func settle(_ host: NSView) async throws {
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
    }

    func testNativePDFSurvivesMenuSwitchAndHiddenViewportResizeThenRestoresAfterEviction() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codmes-retained-pdf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let local = try LocalWorkspace(scope: UUID().uuidString, baseDirectory: directory)
        let document = PDFDocument()
        for index in 0..<3 { document.insert(PDFPage(), at: index) }
        try local.write(path: "Notes/book.pdf", data: XCTUnwrap(document.dataRepresentation()))
        let store = WorkspaceStore(localWorkspace: local, restoreSavedConnection: false)
        await store.loadFile(try XCTUnwrap(store.notes.first { $0.path == "Notes/book.pdf" }))
        let host = NSHostingView(rootView: Surfaces(store: store, active: "notes"))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        try await settle(host)
        let original = try XCTUnwrap(pdfView(in: host))
        let originalDocument = try XCTUnwrap(original.document)
        original.scaleFactor = 1.5
        original.go(to: try XCTUnwrap(originalDocument.page(at: 2)))
        try await settle(host)
        let originalBounds = original.bounds
        let bookmark = try XCTUnwrap(PDFReadingState.capture(original))
        // In continuous layout the viewport anchor can lie on the preceding
        // page while currentPage identifies the predominantly visible page.
        let visiblePageIndex = originalDocument.index(for: try XCTUnwrap(original.currentPage))
        XCTAssertEqual(visiblePageIndex, 2)

        XCTAssertTrue(store.prepareForFileSurface("code"))
        host.rootView = Surfaces(store: store, active: "code")
        host.frame.size.height = 350
        try await settle(host)
        XCTAssertTrue(pdfView(in: host) === original)
        XCTAssertTrue(original.document === originalDocument)
        XCTAssertEqual(original.bounds, originalBounds, "Keyboard in Code must not resize the hidden PDF")
        XCTAssertEqual(original.scaleFactor, bookmark.scale, accuracy: 0.001)
        XCTAssertEqual(originalDocument.index(for: try XCTUnwrap(original.currentPage)), visiblePageIndex)

        host.frame.size.height = 600
        XCTAssertTrue(store.prepareForFileSurface("notes"))
        host.rootView = Surfaces(store: store, active: "notes")
        try await settle(host)
        XCTAssertTrue(pdfView(in: host) === original)
        XCTAssertEqual(original.scaleFactor, bookmark.scale, accuracy: 0.001)

        XCTAssertTrue(store.prepareForFileSurface("code"))
        host.rootView = Surfaces(store: store, active: "code")
        try await settle(host)
        let beforeEviction = try XCTUnwrap(PDFReadingState.capture(original))
        let visiblePageBeforeEviction = originalDocument.index(for: try XCTUnwrap(original.currentPage))
        store.releaseInactiveFileSurfaces()
        try await settle(host)
        XCTAssertNil(pdfView(in: host))
        XCTAssertEqual(store.pdfReadingState(for: "Notes/book.pdf"), beforeEviction)

        XCTAssertTrue(store.prepareForFileSurface("notes"))
        await store.restoreFileSurfaceIfNeeded("notes")
        host.rootView = Surfaces(store: store, active: "notes")
        try await settle(host)
        let restored = try XCTUnwrap(pdfView(in: host))
        XCTAssertFalse(restored === original)
        XCTAssertEqual(restored.scaleFactor, beforeEviction.scale, accuracy: 0.001)
        XCTAssertEqual(restored.document?.index(for: try XCTUnwrap(restored.currentPage)), visiblePageBeforeEviction)
        let restoredPosition = try XCTUnwrap(PDFReadingState.capture(restored))
        XCTAssertEqual(restoredPosition.pageIndex, beforeEviction.pageIndex)
        XCTAssertEqual(restoredPosition.x, beforeEviction.x, accuracy: 2)
        XCTAssertEqual(restoredPosition.y, beforeEviction.y, accuracy: 2)
    }
}
#endif
