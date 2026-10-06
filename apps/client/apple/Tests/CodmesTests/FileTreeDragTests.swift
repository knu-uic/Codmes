import XCTest
import UniformTypeIdentifiers
@testable import Codmes

#if os(macOS)
@MainActor
final class FileTreeDragTests: XCTestCase {
    func testProviderLoadsSinglePDFPathUsingWorkspaceType() async {
        let paths = ["Notes/그림 설명 테스트.pdf"]
        let provider = FileTreeDragItem(paths: paths).macOSProvider()
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.codmesWorkspaceItem.identifier))
        let loaded = expectation(description: "workspace drag payload loaded")
        XCTAssertTrue(FileTreeDragItem.loadPaths(from: [provider]) { result in
            XCTAssertEqual(result, paths)
            loaded.fulfill()
        })
        await fulfillment(of: [loaded], timeout: 3)
    }

    func testProviderPreservesMultiplePathsAndSkipsUnrelatedText() async {
        let paths = ["Code/main.swift", "Code/하위 폴더"]
        let unrelated = NSItemProvider(object: "not a workspace drag" as NSString)
        let loaded = expectation(description: "multiple workspace paths loaded")
        XCTAssertTrue(FileTreeDragItem.loadPaths(from: [unrelated, FileTreeDragItem(paths: paths).macOSProvider()]) { result in
            XCTAssertEqual(result, paths)
            loaded.fulfill()
        })
        await fulfillment(of: [loaded], timeout: 3)
    }

    func testUnrelatedTextCannotTriggerWorkspaceMove() {
        XCTAssertFalse(FileTreeDragItem.loadPaths(from: [NSItemProvider(object: "{}" as NSString)]) { _ in
            XCTFail("Text from outside the file tree must not move workspace files")
        })
    }
}
#endif
