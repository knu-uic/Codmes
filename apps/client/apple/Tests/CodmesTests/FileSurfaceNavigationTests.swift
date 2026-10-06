import Foundation
import XCTest
@testable import Codmes

private final class FileSurfaceURLProtocol: URLProtocol, @unchecked Sendable {
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: FileSurfaceURLProtocol?
        private var expectation: XCTestExpectation?

        func prepare(_ expectation: XCTestExpectation) {
            lock.withLock { self.expectation = expectation }
        }

        func begin(_ request: FileSurfaceURLProtocol) {
            let started = lock.withLock {
                pending = request
                return expectation
            }
            started?.fulfill()
        }

        func finish() {
            let request = lock.withLock {
                let request = pending
                pending = nil
                expectation = nil
                return request
            }
            request?.complete()
        }
    }

    static let control = Control()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "codmes-file-surface-test.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.control.begin(self) }
    override func stopLoading() {}

    private func complete() {
        guard let url = request.url,
              let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]),
              let data = try? JSONEncoder().encode(FileResponse(path: path, name: "delayed.swift", kind: "code", size: 6, modifiedAt: "", content: "remote")) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class FileSurfaceNavigationTests: XCTestCase {
    private func fixture() throws -> (URL, LocalWorkspace, WorkspaceStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codmes-file-surface-\(UUID().uuidString)")
        let local = try LocalWorkspace(scope: UUID().uuidString, baseDirectory: directory)
        return (directory, local, WorkspaceStore(localWorkspace: local, restoreSavedConnection: false))
    }

    func testSwitchingNotesPDFToCodeClearsPreviewFocusAndChatContextWithoutDeletingData() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let pdf = Data("pdf fixture".utf8), annotations = Data("annotation fixture".utf8)
        try local.write(path: "Notes/book.pdf", data: pdf)
        try local.write(path: "Notes/book.pdf", data: annotations, resource: "annotations")
        let item = try XCTUnwrap(store.notes.first { $0.path == "Notes/book.pdf" })
        await store.loadFile(item)
        XCTAssertNotNil(store.selectedRawFile)
        store.selectedPDFFocus = PDFDocumentFocus(path: item.path, page: 3, bbox: nil)
        let journal = try Data(contentsOf: local.directory.appendingPathComponent("state.json"))

        XCTAssertTrue(store.prepareForFileSurface("code"))
        XCTAssertNil(store.selectedRawFile)
        XCTAssertNil(store.selectedFile)
        XCTAssertNil(store.loadingRawFile)
        XCTAssertNil(store.selectedPDFFocus)
        XCTAssertEqual(store.chatContextLabel, "Current file: none selected")
        XCTAssertEqual(try local.read(path: item.path), pdf)
        XCTAssertEqual(try local.read(path: item.path, resource: "annotations"), annotations)
        XCTAssertEqual(try Data(contentsOf: local.directory.appendingPathComponent("state.json")), journal)

        XCTAssertTrue(store.prepareForFileSurface("notes"))
        XCTAssertEqual(store.selectedRawFile?.path, item.path)
        XCTAssertEqual(store.selectedPDFFocus?.page, 3)
        XCTAssertEqual(store.retainedFileSurfaces, ["notes", "code"])
    }

    func testSwitchingCodeToNotesFlushesDebouncedEditingBeforeClearingSelection() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.write(path: "Code/test.swift", data: Data("original".utf8))
        let item = try XCTUnwrap(store.code.first { $0.path == "Code/test.swift" })
        await store.loadFile(item)
        store.startEditingSelectedFile()
        store.editorText = "edited immediately before switching"
        XCTAssertTrue(store.prepareForFileSurface("notes"))
        XCTAssertNil(store.selectedFile)
        XCTAssertFalse(store.isEditingFile)
        XCTAssertEqual(store.editorText, "")
        XCTAssertEqual(try local.read(path: item.path), Data("edited immediately before switching".utf8))
        XCTAssertTrue(store.prepareForFileSurface("code"))
        XCTAssertEqual(store.selectedFile?.path, item.path)
        XCTAssertTrue(store.isEditingFile)
        XCTAssertEqual(store.editorText, "edited immediately before switching")
        XCTAssertTrue(store.editorHistory.canUndo)
        store.undoEditorChange()
        XCTAssertEqual(store.editorText, "original")
    }

    func testReselectingSameSurfaceOrChatDoesNotCloseDocument() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.write(path: "Notes/book.pdf", data: Data("pdf fixture".utf8))
        await store.loadFile(try XCTUnwrap(store.notes.first { $0.path == "Notes/book.pdf" }))
        let url = try XCTUnwrap(store.selectedRawFile?.url)
        for surface in ["notes", "chat", "planner"] {
            XCTAssertTrue(store.prepareForFileSurface(surface))
            XCTAssertEqual(store.selectedRawFile?.url, url)
        }
    }

    func testSwitchingSurfacesClearsPDFLoadingErrorAndFocus() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        store.loadingRawFile = WorkspaceItem(name: "book.pdf", path: "Notes/book.pdf", kind: "pdf", isDirectory: false, size: 0, modifiedAt: "")
        store.rawFileLoadError = "retry needed"
        store.selectedPDFFocus = PDFDocumentFocus(path: "Notes/book.pdf", page: 2, bbox: nil)
        store.isLoading = true
        XCTAssertTrue(store.prepareForFileSurface("code"))
        XCTAssertNil(store.loadingRawFile)
        XCTAssertNil(store.rawFileLoadError)
        XCTAssertNil(store.selectedPDFFocus)
        XCTAssertFalse(store.isLoading)
    }

    func testSavingFailurePreventsNavigationAndPreservesEditor() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        store.selectedFile = FileResponse(path: "Code/../invalid.swift", name: "invalid.swift", kind: "code", size: 0, modifiedAt: "", content: "original")
        store.startEditingSelectedFile()
        store.editorText = "must not be discarded"
        XCTAssertFalse(store.prepareForFileSurface("notes"))
        XCTAssertNotNil(store.selectedFile)
        XCTAssertTrue(store.isEditingFile)
        XCTAssertEqual(store.editorText, "must not be discarded")
        XCTAssertFalse(store.editorAutosaveError.isEmpty)
    }

    func testTextEditorHistoriesAreIndependentAcrossSurfaces() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["Notes/note.md", "Code/test.swift"] { try local.write(path: path, data: Data(path.utf8)) }
        await store.loadFile(try XCTUnwrap(store.notes.first { $0.path == "Notes/note.md" }))
        store.startEditingSelectedFile(); store.editorText = "notes edit"
        await store.loadFile(try XCTUnwrap(store.code.first { $0.path == "Code/test.swift" }))
        store.startEditingSelectedFile(); store.editorText = "code edit"
        XCTAssertTrue(store.prepareForFileSurface("notes"))
        XCTAssertEqual(store.editorText, "notes edit")
        store.undoEditorChange(); XCTAssertEqual(store.editorText, "Notes/note.md")
        XCTAssertTrue(store.prepareForFileSurface("code"))
        XCTAssertEqual(store.editorText, "code edit")
        store.undoEditorChange(); XCTAssertEqual(store.editorText, "Code/test.swift")
    }

    func testMemoryPressureReleasesInactivePDFButPreservesBookmarkAndFiles() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("pdf fixture".utf8)
        try local.write(path: "Notes/book.pdf", data: data)
        await store.loadFile(try XCTUnwrap(store.notes.first { $0.path == "Notes/book.pdf" }))
        XCTAssertTrue(store.prepareForFileSurface("code"))
        let bookmark = PDFReadingState(pageIndex: 4, scale: 1.6, x: 20, y: 300)
        store.savePDFReadingState(bookmark, path: "Notes/book.pdf", scope: store.profileStorageScope)
        store.releaseInactiveFileSurfaces()
        XCTAssertEqual(store.retainedFileSurfaces, ["code"])
        XCTAssertNil(store.fileSurfaceState(for: "notes").rawFile)
        XCTAssertEqual(store.fileSurfaceState(for: "notes").reloadItem?.path, "Notes/book.pdf")
        XCTAssertEqual(store.pdfReadingState(for: "Notes/book.pdf"), bookmark)
        XCTAssertEqual(try local.read(path: "Notes/book.pdf"), data)
        XCTAssertTrue(store.prepareForFileSurface("notes"))
        await store.restoreFileSurfaceIfNeeded("notes")
        XCTAssertEqual(store.selectedRawFile?.path, "Notes/book.pdf")
        XCTAssertEqual(store.pdfReadingState(for: "Notes/book.pdf"), bookmark)
        store.releaseInactiveFileSurfaces()
        XCTAssertNotNil(store.selectedRawFile, "Active PDF must not be evicted")
    }

    func testRemoteOnlySnapshotIsNotDiscardedOnReturn() throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(store.prepareForFileSurface("notes"))
        store.selectedFile = FileResponse(path: "Notes/remote.md", name: "remote.md", kind: "markdown", size: 6, modifiedAt: "", content: "remote")
        store.editorText = "remote"
        XCTAssertTrue(store.prepareForFileSurface("code"))
        XCTAssertTrue(store.prepareForFileSurface("notes"))
        XCTAssertEqual(store.selectedFile?.path, "Notes/remote.md")
    }

    func testDeletedInactiveFileIsNotReopened() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.write(path: "Notes/note.md", data: Data("note".utf8))
        await store.loadFile(try XCTUnwrap(store.notes.first { $0.path == "Notes/note.md" }))
        XCTAssertTrue(store.prepareForFileSurface("code"))
        try local.delete(path: "Notes/note.md")
        XCTAssertTrue(store.prepareForFileSurface("notes"))
        XCTAssertNil(store.selectedFile)
    }

    func testLateRemoteLoadCannotReopenNotesFileAfterSwitchingToCode() async throws {
        let (directory, _, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertTrue(URLProtocol.registerClass(FileSurfaceURLProtocol.self))
        defer {
            FileSurfaceURLProtocol.control.finish()
            URLProtocol.unregisterClass(FileSurfaceURLProtocol.self)
        }
        store.serverURLText = "https://codmes-file-surface-test.invalid"
        store.isWorkspaceConnected = true
        let started = expectation(description: "File download started")
        FileSurfaceURLProtocol.control.prepare(started)
        let item = WorkspaceItem(name: "delayed.swift", path: "Notes/\(UUID().uuidString)/delayed.swift", kind: "code", isDirectory: false, size: 6, modifiedAt: "")
        let loading = Task { await store.loadFile(item) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(store.isLoading)
        XCTAssertTrue(store.prepareForFileSurface("code"))
        XCTAssertFalse(store.isLoading)
        FileSurfaceURLProtocol.control.finish()
        await loading.value
        XCTAssertNil(store.selectedFile)
        XCTAssertNil(store.selectedRawFile)
        XCTAssertNil(store.loadingRawFile)
        XCTAssertEqual(store.chatContextLabel, "Current file: none selected")
    }
}
