import XCTest
@testable import Codmes

@MainActor
final class FileOperationFailureTests: XCTestCase {
    private func fixture() throws -> (URL, LocalWorkspace, WorkspaceStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("codmes-file-operation-test-\(UUID().uuidString)")
        let local = try LocalWorkspace(scope: "file-operations", baseDirectory: directory)
        return (directory, local, WorkspaceStore(localWorkspace: local, restoreSavedConnection: false))
    }

    func testDuplicateCreateReturnsVisibleFailureEveryTimeWithoutOverwriting() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.write(path: "Notes/test.md", data: Data("existing".utf8))
        let journal = try Data(contentsOf: local.directory.appendingPathComponent("state.json"))
        for _ in 0..<2 {
            let result = await store.createFile(root: "notes", name: "test.md")
            let failure = try XCTUnwrap(result)
            XCTAssertEqual(failure.title, "같은 이름의 자료가 있습니다")
            XCTAssertTrue(failure.message.contains("Notes/test.md"))
            XCTAssertTrue(failure.message.contains("아래 이름으로 변경"))
            XCTAssertEqual(failure.nameConflict?.suggestedName, "test(1).md")
            XCTAssertEqual(try local.read(path: "Notes/test.md"), Data("existing".utf8))
            XCTAssertEqual(try Data(contentsOf: local.directory.appendingPathComponent("state.json")), journal)
        }
    }

    func testDuplicateDragMoveReturnsDestinationFailureAndPreservesBothFiles() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.createFolder(path: "Notes/home")
        try local.createFolder(path: "Notes/home/folder")
        let source = "Notes/home/test.md", destination = "Notes/home/folder/test.md"
        try local.write(path: source, data: Data("source".utf8))
        try local.write(path: destination, data: Data("destination".utf8))
        let folder = try XCTUnwrap(store.notes.first { $0.path == "Notes/home/folder" })
        let journal = try Data(contentsOf: local.directory.appendingPathComponent("state.json"))
        let result = await store.moveTreeItems(root: "notes", sourcePaths: [source], into: folder)
        let failure = try XCTUnwrap(result)
        XCTAssertTrue(failure.message.contains(destination))
        XCTAssertTrue(failure.message.contains("이동할까요?"))
        XCTAssertEqual(failure.nameConflict?.sourcePath, source)
        XCTAssertEqual(failure.nameConflict?.suggestedName, "test(1).md")
        XCTAssertEqual(try local.read(path: source), Data("source".utf8))
        XCTAssertEqual(try local.read(path: destination), Data("destination".utf8))
        XCTAssertEqual(try Data(contentsOf: local.directory.appendingPathComponent("state.json")), journal)
    }

    func testDuplicateCodeCreationAndFolderCreationAlsoReturnFailure() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.write(path: "Code/test.swift", data: Data("existing code".utf8))
        try local.createFolder(path: "Notes/folder")
        let codeFailure = await store.createFile(root: "code", name: "test")
        XCTAssertTrue(try XCTUnwrap(codeFailure).message.contains("Code/test.swift"))
        let folderFailure = await store.createFolder(root: "notes", name: "folder")
        XCTAssertNotNil(folderFailure)
    }

    func testDuplicateRenameAndCopyReturnFailureWithoutOverwriting() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.write(path: "Notes/test.md", data: Data("source".utf8))
        try local.write(path: "Notes/other.md", data: Data("other".utf8))
        try local.createFolder(path: "Notes/folder")
        try local.write(path: "Notes/folder/test.md", data: Data("destination".utf8))
        let item = try XCTUnwrap(store.notes.first { $0.path == "Notes/test.md" })
        let renameFailure = await store.renameItem(root: "notes", item: item, newName: "other.md")
        let copyFailure = await store.copyItems(root: "notes", items: [item], destinationFolder: "folder")
        XCTAssertNotNil(renameFailure)
        XCTAssertNotNil(copyFailure)
        XCTAssertEqual(try local.read(path: "Notes/test.md"), Data("source".utf8))
        XCTAssertEqual(try local.read(path: "Notes/other.md"), Data("other".utf8))
        XCTAssertEqual(try local.read(path: "Notes/folder/test.md"), Data("destination".utf8))
    }

    func testDroppingInSameFolderIsASilentNoOpNotADuplicate() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.write(path: "Notes/test.md", data: Data("original".utf8))
        let result = await store.moveTreeItems(root: "notes", sourcePaths: ["Notes/test.md"], into: nil)
        XCTAssertNil(result)
    }

    func testSuccessfulCreateAndMoveDoNotReturnWarning() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let folderResult = await store.createFolder(root: "notes", name: "folder")
        let fileResult = await store.createFile(root: "notes", name: "test.md")
        XCTAssertNil(folderResult)
        XCTAssertNil(fileResult)
        let folder = try XCTUnwrap(store.notes.first { $0.path == "Notes/folder" })
        let moveResult = await store.moveTreeItems(root: "notes", sourcePaths: ["Notes/test.md"], into: folder)
        XCTAssertNil(moveResult)
        XCTAssertNil(local.entry(path: "Notes/test.md"))
        XCTAssertNotNil(local.entry(path: "Notes/folder/test.md"))
    }

    func testCreateSuggestionSkipsOccupiedNamesAndCanBeEditedBeforeRetry() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.write(path: "Notes/test.md", data: Data("original".utf8))
        try local.write(path: "Notes/test(1).md", data: Data("numbered".utf8))
        try local.createFolder(path: "Notes/test(2).md")
        let result = await store.createFile(root: "notes", name: "test.md")
        XCTAssertEqual(result?.nameConflict?.suggestedName, "test(3).md")
        let retry = await store.createFile(root: "notes", name: "edited.md")
        XCTAssertNil(retry)
        XCTAssertNotNil(local.entry(path: "Notes/edited.md"))
        XCTAssertEqual(try local.read(path: "Notes/test.md"), Data("original".utf8))
    }

    func testDuplicateMoveRetryRenamesOnlyIncomingFileAtDestination() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.createFolder(path: "Notes/folder")
        let source = "Notes/test.md", destination = "Notes/folder/test.md"
        try local.write(path: source, data: Data("incoming".utf8))
        try local.write(path: destination, data: Data("existing".utf8))
        let folder = try XCTUnwrap(store.notes.first { $0.path == "Notes/folder" })
        let result = await store.moveTreeItems(root: "notes", sourcePaths: [source], into: folder)
        let suggestion = try XCTUnwrap(result?.nameConflict?.suggestedName)
        let retry = await store.moveTreeItems(root: "notes", sourcePaths: [source], into: folder, replacementNames: [source: suggestion])
        XCTAssertNil(retry)
        XCTAssertNil(local.entry(path: source))
        XCTAssertNil(local.entry(path: "Notes/test(1).md"))
        XCTAssertEqual(try local.read(path: "Notes/folder/\(suggestion)"), Data("incoming".utf8))
        XCTAssertEqual(try local.read(path: destination), Data("existing".utf8))
    }

    func testRepeatedCollisionDuringRetryStillPreservesBothFiles() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.createFolder(path: "Notes/folder")
        try local.write(path: "Notes/test.md", data: Data("incoming".utf8))
        try local.write(path: "Notes/folder/test.md", data: Data("existing".utf8))
        let folder = try XCTUnwrap(store.notes.first { $0.path == "Notes/folder" })
        let journal = try Data(contentsOf: local.directory.appendingPathComponent("state.json"))
        let retry = await store.moveTreeItems(root: "notes", sourcePaths: ["Notes/test.md"], into: folder, replacementNames: ["Notes/test.md": "test.md"])
        XCTAssertEqual(retry?.nameConflict?.suggestedName, "test(1).md")
        XCTAssertEqual(try Data(contentsOf: local.directory.appendingPathComponent("state.json")), journal)
    }

    func testMultipleDuplicateCopiesResolveBeforeAnyCopyRuns() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        for path in ["Notes/a", "Notes/b", "Notes/target"] { try local.createFolder(path: path) }
        try local.write(path: "Notes/a/test.md", data: Data("a".utf8))
        try local.write(path: "Notes/b/test.md", data: Data("b".utf8))
        try local.write(path: "Notes/target/test.md", data: Data("target".utf8))
        let items = store.notes.filter { !$0.isDirectory && !$0.path.hasPrefix("Notes/target/") }
        let journal = try Data(contentsOf: local.directory.appendingPathComponent("state.json"))
        var names: [String: String] = [:]
        for _ in 0..<2 {
            let failure = await store.copyItems(root: "notes", items: items, destinationFolder: "target", replacementNames: names)
            let conflict = try XCTUnwrap(failure?.nameConflict)
            names[try XCTUnwrap(conflict.sourcePath)] = conflict.suggestedName
            XCTAssertEqual(try Data(contentsOf: local.directory.appendingPathComponent("state.json")), journal)
        }
        XCTAssertEqual(Set(names.values), ["test(1).md", "test(2).md"])
        let retry = await store.copyItems(root: "notes", items: items, destinationFolder: "target", replacementNames: names)
        XCTAssertNil(retry)
        XCTAssertEqual(try local.read(path: "Notes/target/test(1).md"), Data("a".utf8))
        XCTAssertEqual(try local.read(path: "Notes/target/test(2).md"), Data("b".utf8))
        XCTAssertEqual(try local.read(path: "Notes/target/test.md"), Data("target".utf8))
    }

    func testFolderSuggestionDoesNotTreatDotAsFileExtension() async throws {
        let (directory, local, store) = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try local.createFolder(path: "Notes/folder.v1")
        let failure = await store.createFolder(root: "notes", name: "folder.v1")
        XCTAssertEqual(failure?.nameConflict?.suggestedName, "folder.v1(1)")
        let retry = await store.createFolder(root: "notes", name: "folder.v1(1)")
        XCTAssertNil(retry)
    }
}
