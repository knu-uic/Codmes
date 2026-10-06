import XCTest
@testable import Codmes

private actor SyncTestServer: WorkspaceSyncTransport {
    private var entries: [String: WorkspaceSyncEntry] = [:]
    private var contents: [String: Data] = [:]
    var dropNextResponse = false
    private var mergedResponse: Data?
    private let selective: Bool
    private var receipts: Set<String> = []
    private var tombstones: [WorkspaceSyncDeletedEntry] = []
    private var received: [WorkspaceSyncChange] = []
    func receivedChanges() -> [WorkspaceSyncChange] { received }
    private var policies: [String: [WorkspaceDevicePolicy]] = [:]
    init(selective: Bool = false) { self.selective = selective }
    func reportedModes() -> [String: [WorkspaceDevicePolicy]] { policies }
    func reportStoragePolicies(deviceId: String, policies: [WorkspaceDevicePolicy]) async throws { self.policies[deviceId] = policies }
    func mergeNextUpload(_ data: Data) { mergedResponse = data }
    func loseNextResponse() { dropNextResponse = true }
    private var pauseNext = false
    private var paused = false
    private var started: CheckedContinuation<Void, Never>?
    private var resume: CheckedContinuation<Void, Never>?
    func pauseNextUpload() { pauseNext = true }
    func waitForUpload() async { if !paused { await withCheckedContinuation { started = $0 } } }
    func resumeUpload() { resume?.resume(); resume = nil }
    func syncManifest() async throws -> WorkspaceSyncManifest {
        var list = Array(entries.values)
        for index in list.indices where list[index].kind == "pdf" && list[index].resource == "file" {
            list[index].annotationFingerprint = try LocalWorkspace.annotationFingerprint(contents["annotations:\(list[index].path)"])
        }
        return WorkspaceSyncManifest(version: 1, entries: list, conflictPolicies: ["merge-modified-v2"], deletedEntries: tombstones, selectiveSyncVersion: selective ? 1 : nil)
    }
    func moveSyncFile(_ move: WorkspaceSyncMove) async throws -> WorkspaceSyncResult {
        guard let own = entries.values.first(where: { $0.fileId == move.fileId && $0.resource != "annotations" }) else { return WorkspaceSyncResult(status: "conflict", entry: nil) }
        if own.path == move.to { return WorkspaceSyncResult(status: "applied", entry: own) }
        guard own.path == move.from, own.revision == move.expectedRevision else { return WorkspaceSyncResult(status: "conflict", entry: own) }
        for original in entries.values.filter({ $0.path == move.from || $0.path.hasPrefix(move.from + "/") }) {
            if original.resource != "folder" {
                tombstones.append(WorkspaceSyncDeletedEntry(path: original.path, resource: original.resource, versionId: "move_" + String(LocalWorkspace.digest(Data(move.to.utf8)).prefix(32)), modifiedAt: original.modifiedAt))
            }
            var moved = original; moved.path = move.to + original.path.dropFirst(move.from.count)
            entries.removeValue(forKey: original.key); entries[moved.key] = moved; contents[moved.key] = contents.removeValue(forKey: original.key)
        }
        return WorkspaceSyncResult(status: "applied", entry: entries.values.first { $0.path == move.to && $0.resource != "annotations" })
    }
    func downloadSyncBlob(_ entry: WorkspaceSyncEntry) async throws -> URL {
        guard let data = contents[entry.key] else { throw LocalWorkspaceError.missing }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: file); return file
    }
    func applySyncChange(_ change: WorkspaceSyncChange, file: URL?) async throws -> WorkspaceSyncResult {
        received.append(change)
        let key = "\(change.resource):\(change.path)"
        var data = try file.map { try Data(contentsOf: $0) }
        if pauseNext {
            pauseNext = false; paused = true; started?.resume(); started = nil
            await withCheckedContinuation { resume = $0 }
        }
        let existing = entries[key]
        if change.baseVersion?.hasPrefix("move_") == true {
            return WorkspaceSyncResult(status: "conflict", entry: existing, reason: "base-missing")
        }
        if selective, let id = change.fileId, let existing, existing.fileId != id {
            return WorkspaceSyncResult(status: "conflict", entry: existing, reason: "first-registration")
        }
        if let expected = change.expectedRevision, (existing?.revision ?? "missing") != expected { return WorkspaceSyncResult(status: "conflict", entry: existing, reason: "decision-stale") }
        if entries.values.contains(where: { $0.path == change.path && $0.resource != "annotations" && change.resource != "annotations" && $0.resource != change.resource }) {
            return WorkspaceSyncResult(status: "conflict", entry: nil)
        }
        if change.action == "delete" {
            guard existing?.revision == change.baseRevision || existing == nil else { return WorkspaceSyncResult(status: "conflict", entry: existing) }
            entries.removeValue(forKey: key); contents.removeValue(forKey: key)
        } else {
            if let mergedResponse { data = mergedResponse; self.mergedResponse = nil }
            let finalRevision = change.resource == "folder" ? "directory" : data.map(LocalWorkspace.digest)
            let entry = WorkspaceSyncEntry(path: change.path, resource: change.resource, kind: change.resource == "folder" ? "folder" : change.path.hasSuffix(".pdf") ? "pdf" : "markdown", isDirectory: change.resource == "folder", size: data?.count ?? 0, modifiedAt: "2026-10-01T00:00:00Z", revision: finalRevision!, fileId: selective ? existing?.fileId ?? change.fileId ?? UUID().uuidString : nil)
            entries[key] = entry; contents[key] = data
            tombstones.removeAll { $0.path == change.path && $0.resource == change.resource }
        }
        if dropNextResponse { dropNextResponse = false; throw URLError(.networkConnectionLost) }
        return WorkspaceSyncResult(status: "applied", entry: entries[key])
    }
}

@MainActor
final class LocalWorkspaceTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codmes-local-sync-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func text(_ store: LocalWorkspace, _ path: String) throws -> String { String(decoding: try store.read(path: path), as: UTF8.self) }

    private func simulateLegacyMoveBase(_ local: LocalWorkspace, path: String) throws -> String {
        let journal = local.directory.appendingPathComponent("state.json")
        var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        var operations = try XCTUnwrap(state["pendingOperations"] as? [[String: Any]])
        let index = try XCTUnwrap(operations.firstIndex { ($0["change"] as? [String: Any])?["path"] as? String == path })
        var change = try XCTUnwrap(operations[index]["change"] as? [String: Any])
        let id = try XCTUnwrap(change["operationId"] as? String)
        change["baseVersion"] = "move_01234567890123456789012345678901"
        operations[index]["change"] = change; state["pendingOperations"] = operations
        try JSONSerialization.data(withJSONObject: state).write(to: journal, options: .atomic)
        return id
    }

    func testReusingMovedAwayNameDoesNotInheritSyntheticMoveBase() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let server = SyncTestServer(selective: true)
        let writer = try LocalWorkspace(scope: "writer", baseDirectory: dir)
        let reader = try LocalWorkspace(scope: "reader", baseDirectory: dir)
        try writer.write(path: "Notes/name.md", data: Data("original".utf8))
        _ = try await writer.synchronize(using: server); _ = try await reader.synchronize(using: server)
        try writer.transfer(from: "Notes/name.md", to: "Notes/moved.md", move: true)
        _ = try await writer.synchronize(using: server); _ = try await reader.synchronize(using: server)
        try reader.write(path: "Notes/name.md", data: Data("independent".utf8))
        _ = try await reader.synchronize(using: server)
        XCTAssertTrue(reader.syncConflicts.isEmpty)
        XCTAssertEqual(reader.pendingCount, 0)
        XCTAssertEqual(try text(reader, "Notes/moved.md"), "original")
        XCTAssertEqual(try text(reader, "Notes/name.md"), "independent")
    }

    func testLegacyMovedPathCreationRepairsItsBaseAndDependentEditsAcrossRestart() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "legacy-create", baseDirectory: dir)
        try local.write(path: "Notes/ㅇㅇ", data: Data("first".utf8))
        try local.write(path: "Notes/ㅇㅇ", data: Data("latest edit".utf8))
        let oldId = try simulateLegacyMoveBase(local, path: "Notes/ㅇㅇ")
        let restarted = try LocalWorkspace(scope: "legacy-create", baseDirectory: dir)
        let server = SyncTestServer(selective: true)
        _ = try await restarted.synchronize(using: server)
        let changes = await server.receivedChanges()
        XCTAssertEqual(changes.count, 2)
        XCTAssertNil(changes[0].baseVersion)
        XCTAssertNotEqual(changes[0].operationId, oldId)
        XCTAssertEqual(changes[1].baseVersion, changes[0].operationId)
        XCTAssertTrue(restarted.syncConflicts.isEmpty)
        XCTAssertEqual(restarted.pendingCount, 0)
        XCTAssertEqual(try text(restarted, "Notes/ㅇㅇ"), "latest edit")
    }

    func testLegacyBaseRepairDoesNotBypassRealNameCollision() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let server = SyncTestServer(selective: true)
        let remote = try LocalWorkspace(scope: "remote", baseDirectory: dir)
        try remote.write(path: "Notes/name.md", data: Data("server content".utf8))
        _ = try await remote.synchronize(using: server)
        let local = try LocalWorkspace(scope: "collision", baseDirectory: dir)
        try local.write(path: "Notes/name.md", data: Data("independent local content".utf8))
        _ = try simulateLegacyMoveBase(local, path: "Notes/name.md")
        let restarted = try LocalWorkspace(scope: "collision", baseDirectory: dir)
        _ = try await restarted.synchronize(using: server)
        XCTAssertEqual(restarted.syncConflicts.first?.reason, "first-registration")
        XCTAssertEqual(try text(restarted, "Notes/name.md"), "independent local content")
        let changes = await server.receivedChanges()
        XCTAssertEqual(changes.count, 1, "The independent local file must not replace the server file")
    }

    func testRenamingConflictingIndependentFileKeepsBothWithoutRepeatingConflict() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let server = SyncTestServer(selective: true)
        let remote = try LocalWorkspace(scope: "remote", baseDirectory: dir), local = try LocalWorkspace(scope: "local", baseDirectory: dir)
        try remote.write(path: "Notes/name.md", data: Data("remote".utf8)); _ = try await remote.synchronize(using: server)
        try local.write(path: "Notes/name.md", data: Data("local".utf8)); _ = try await local.synchronize(using: server)
        XCTAssertEqual(local.syncConflicts.count, 1)
        try local.transfer(from: "Notes/name.md", to: "Notes/renamed.md", move: true)
        XCTAssertTrue(local.syncConflicts.isEmpty)
        for _ in 0..<3 { _ = try await local.synchronize(using: server) }
        XCTAssertTrue(local.syncConflicts.isEmpty); XCTAssertEqual(local.pendingCount, 0)
        XCTAssertEqual(try text(local, "Notes/name.md"), "remote")
        XCTAssertEqual(try text(local, "Notes/renamed.md"), "local")
    }

    func testMissingBaseIsNotPresentedAsNameCollision() {
        let conflict = WorkspaceSyncConflict(path: "Notes/ㅇㅇ", server: nil, localRevision: "local", reason: "base-missing")
        XCTAssertFalse(conflict.isNameConflict)
        XCTAssertFalse(conflict.title.contains("같은 경로"))
        XCTAssertFalse(conflict.message.contains("이름을 변경"))
        XCTAssertTrue(conflict.message.contains("기준 이력"))
    }

    func testUnchangedSyncDoesNotRewriteJournalOrNotifyViews() async throws {
        let directory = try fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let local = try LocalWorkspace(scope: "idle-pdf", baseDirectory: directory)
        let server = SyncTestServer(selective: true)
        try local.write(path: "Notes/book.pdf", data: Data("unchanged PDF bytes".utf8))
        try local.write(path: "Notes/book.pdf", data: Data("{\"schemaVersion\":2,\"pages\":[],\"objects\":[]}".utf8), resource: "annotations")
        _ = try await local.synchronize(using: server)
        let journal = local.directory.appendingPathComponent("state.json")
        let saved = try Data(contentsOf: journal)
        let modifiedAt = try journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var changes = 0
        local.onChange = { changes += 1 }

        for _ in 0..<3 {
            let report = try await local.synchronize(using: server)
            XCTAssertEqual(report.uploaded, 0)
            XCTAssertEqual(report.downloaded, 0)
            XCTAssertEqual(report.statusMessage(pendingChanges: local.pendingSyncCount), "로컬 자료 최신 상태")
        }

        XCTAssertEqual(changes, 0)
        XCTAssertEqual(try Data(contentsOf: journal), saved)
        XCTAssertEqual(try journal.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modifiedAt)
        XCTAssertEqual(local.pendingSyncCount, 0)
    }

    func testSyncStatusDistinguishesTransfersPendingChangesAndPausedFiles() {
        XCTAssertEqual(LocalSyncReport().statusMessage(pendingChanges: 0), "로컬 자료 최신 상태")
        XCTAssertEqual(LocalSyncReport(uploaded: 1).statusMessage(pendingChanges: 0), "저장 모드에 따라 동기화 완료")
        XCTAssertEqual(LocalSyncReport(downloaded: 1).statusMessage(pendingChanges: 0), "저장 모드에 따라 동기화 완료")
        XCTAssertEqual(LocalSyncReport().statusMessage(pendingChanges: 1), "로컬 변경 보존 · 미전송 자료 1개")
        XCTAssertTrue(LocalSyncReport(conflicts: ["Notes/book.pdf"]).statusMessage(pendingChanges: 1).contains("충돌"))
        let paused = LocalSyncReport(paused: ["Notes/book.pdf"]).statusMessage(pendingChanges: 1)
        XCTAssertTrue(paused.contains("전송 보류"))
        XCTAssertFalse(paused.contains("동기화 완료"))
    }

    func testRemoteRenameKeepsIdentityAndModeWithoutCreatingAnotherBook() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let phone = try LocalWorkspace(scope: "renamer", baseDirectory: dir), mac = try LocalWorkspace(scope: "reader", baseDirectory: dir), server = SyncTestServer(selective: true)
        try phone.write(path: "Notes/book.md", data: Data("book".utf8)); _ = try await phone.synchronize(using: server); _ = try await mac.synchronize(using: server)
        let identity = mac.entry(path: "Notes/book.md")?.fileId
        try mac.setMode(path: "Notes/book.md", mode: .server)
        try phone.transfer(from: "Notes/book.md", to: "Code/renamed.md", move: true); _ = try await phone.synchronize(using: server); _ = try await mac.synchronize(using: server)
        XCTAssertEqual(mac.fileCount, 1); XCTAssertEqual(mac.entry(path: "Code/renamed.md")?.fileId, identity); XCTAssertEqual(mac.mode(path: "Code/renamed.md"), .server)
        XCTAssertNil(mac.entry(path: "Notes/book.md"))
    }
    func testDeletedLocalFileRecreationGetsFreshIdentityAndDoesNotInheritOldOverride() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "recreate", baseDirectory: dir)
        try local.write(path: "Notes/book.md", data: Data("first".utf8)); try local.setMode(path: "Notes/book.md", mode: .local)
        try local.delete(path: "Notes/book.md"); try local.write(path: "Notes/book.md", data: Data("second".utf8))
        XCTAssertEqual(local.mode(path: "Notes/book.md"), .sync)
    }
    func testLocalMetadataCannotFetchServerPayloadOnDemand() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let phone = try LocalWorkspace(scope: "publisher", baseDirectory: dir), mac = try LocalWorkspace(scope: "private-reader", baseDirectory: dir), server = SyncTestServer(selective: true)
        try phone.write(path: "Notes/book.md", data: Data("remote".utf8)); _ = try await phone.synchronize(using: server)
        try mac.setMode(path: "Notes", mode: .local); _ = try await mac.synchronize(using: server)
        do { try await mac.downloadOnDemand(path: "Notes/book.md", using: server); XCTFail("Local mode must not download") } catch LocalWorkspaceError.missing { }
        XCTAssertNil(mac.url(path: "Notes/book.md"))
    }
    func testExplicitModeSurvivesAChangedPayloadDownloadAndRestart() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let phone = try LocalWorkspace(scope: "publisher", baseDirectory: dir), mac = try LocalWorkspace(scope: "mode-reader", baseDirectory: dir), server = SyncTestServer(selective: true)
        try phone.write(path: "Notes/book.md", data: Data("first".utf8)); _ = try await phone.synchronize(using: server)
        try mac.setMode(path: "Notes", mode: .server); _ = try await mac.synchronize(using: server)
        try mac.setMode(path: "Notes/book.md", mode: .sync); _ = try await mac.synchronize(using: server)
        try phone.write(path: "Notes/book.md", data: Data("second".utf8)); _ = try await phone.synchronize(using: server); _ = try await mac.synchronize(using: server)
        XCTAssertEqual(try text(mac, "Notes/book.md"), "second"); XCTAssertEqual(mac.mode(path: "Notes/book.md"), .sync)
        let restarted = try LocalWorkspace(scope: "mode-reader", baseDirectory: dir); XCTAssertEqual(restarted.mode(path: "Notes/book.md"), .sync)
    }

    func testIndependentIDsAttachIdenticalBookWithoutCreatingAnotherFile() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try LocalWorkspace(scope: "mac", baseDirectory: dir), phone = try LocalWorkspace(scope: "phone", baseDirectory: dir), server = SyncTestServer(selective: true)
        try mac.write(path: "Notes/책1.pdf", data: Data("same book".utf8)); try mac.setMode(path: "Notes/책1.pdf", mode: .local)
        try phone.write(path: "Notes/책1.pdf", data: Data("same book".utf8)); _ = try await phone.synchronize(using: server)
        _ = try await mac.synchronize(using: server)
        XCTAssertEqual(mac.entry(path: "Notes/책1.pdf")?.fileId, phone.entry(path: "Notes/책1.pdf")?.fileId)
        XCTAssertEqual(mac.mode(path: "Notes/책1.pdf"), .sync); XCTAssertEqual(mac.pendingCount, 0)
        let manifest = try await server.syncManifest(); XCTAssertEqual(manifest.entries.filter { $0.resource == "file" }.count, 1)
    }
    func testExplicitLocalOnlyNeverUploadsOrAutoAdopts() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try LocalWorkspace(scope: "private", baseDirectory: dir), phone = try LocalWorkspace(scope: "public", baseDirectory: dir), server = SyncTestServer(selective: true)
        try mac.write(path: "Notes/book.md", data: Data("same".utf8)); try mac.setMode(path: "Notes/book.md", mode: .local, keepLocal: true)
        _ = try await mac.synchronize(using: server); let empty = try await server.syncManifest(); XCTAssertTrue(empty.entries.isEmpty)
        try phone.write(path: "Notes/book.md", data: Data("same".utf8)); _ = try await phone.synchronize(using: server)
        _ = try await mac.synchronize(using: server); XCTAssertEqual(mac.mode(path: "Notes/book.md"), .local)
        XCTAssertNil(mac.entry(path: "Notes/book.md")?.fileId)
    }
    func testDifferentFirstContentsRequireDecisionAndDoNotOverwrite() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try LocalWorkspace(scope: "A", baseDirectory: dir), phone = try LocalWorkspace(scope: "B", baseDirectory: dir), server = SyncTestServer(selective: true)
        try mac.write(path: "Notes/book.md", data: Data("mac book".utf8)); try phone.write(path: "Notes/book.md", data: Data("phone book".utf8))
        _ = try await phone.synchronize(using: server); _ = try await mac.synchronize(using: server)
        XCTAssertEqual(mac.syncConflicts.count, 1); XCTAssertEqual(try text(mac, "Notes/book.md"), "mac book")
        let remote = try await server.syncManifest(); let content = try await server.downloadSyncBlob(remote.entries[0]); defer { try? FileManager.default.removeItem(at: content) }
        XCTAssertEqual(try String(contentsOf: content, encoding: .utf8), "phone book")
        try await mac.resolveConflict(try XCTUnwrap(mac.syncConflicts.first), useServer: true, using: server)
        XCTAssertEqual(try text(mac, "Notes/book.md"), "phone book"); XCTAssertEqual(mac.pendingCount, 0)
    }
    func testServerModePublishesListWithoutPermanentDownloadThenOpensOnDemand() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let phone = try LocalWorkspace(scope: "sender", baseDirectory: dir), tablet = try LocalWorkspace(scope: "receiver", baseDirectory: dir), server = SyncTestServer(selective: true)
        try phone.write(path: "Notes/book.md", data: Data("book".utf8)); _ = try await phone.synchronize(using: server)
        try tablet.setMode(path: "Notes", mode: .server); _ = try await tablet.synchronize(using: server)
        XCTAssertEqual(tablet.items.count, 1); XCTAssertNil(tablet.url(path: "Notes/book.md"))
        try await tablet.downloadOnDemand(path: "Notes/book.md", using: server); XCTAssertEqual(try text(tablet, "Notes/book.md"), "book")
        _ = try await tablet.synchronize(using: server); XCTAssertNil(tablet.url(path: "Notes/book.md"))
    }
    func testCapacityFailureKeepsMetadataAndOtherLocalChanges() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let phone = try LocalWorkspace(scope: "source", baseDirectory: dir), tablet = try LocalWorkspace(scope: "small", baseDirectory: dir), server = SyncTestServer(selective: true)
        try phone.write(path: "Notes/book.md", data: Data("book".utf8)); _ = try await phone.synchronize(using: server)
        tablet.availableCapacity = { 0 }; _ = try await tablet.synchronize(using: server)
        XCTAssertEqual(tablet.items.count, 1); XCTAssertNil(tablet.url(path: "Notes/book.md")); XCTAssertNotNil(tablet.transferStates["Notes/book.md"])
        tablet.availableCapacity = { Int64.max }; _ = try await tablet.synchronize(using: server); XCTAssertEqual(try text(tablet, "Notes/book.md"), "book")
    }
    func testMovePreservesIdentityModeAndPendingEdits() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "move", baseDirectory: dir), server = SyncTestServer(selective: true)
        try local.write(path: "Notes/book.md", data: Data("book".utf8)); _ = try await local.synchronize(using: server)
        let id = local.entry(path: "Notes/book.md")?.fileId
        try local.write(path: "Notes/book.md", data: Data("new edit".utf8)); try local.setMode(path: "Notes", mode: .server)
        try local.setMode(path: "Code", mode: .local); try local.transfer(from: "Notes/book.md", to: "Code/book.md", move: true)
        XCTAssertEqual(local.mode(path: "Code/book.md"), .server); XCTAssertEqual(local.entry(path: "Code/book.md")?.fileId, id)
        _ = try await local.synchronize(using: server)
        let manifest = try await server.syncManifest(); XCTAssertFalse(manifest.entries.contains { $0.path == "Notes/book.md" })
        XCTAssertEqual(manifest.entries.first?.fileId, id)
    }
    func testPDFDifferentInkIsNotAutomaticallyLinked() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try LocalWorkspace(scope: "inkA", baseDirectory: dir), phone = try LocalWorkspace(scope: "inkB", baseDirectory: dir), server = SyncTestServer(selective: true)
        for (store, value) in [(mac, "mac"), (phone, "phone")] {
            try store.write(path: "Notes/book.pdf", data: Data("same PDF".utf8))
            try store.write(path: "Notes/book.pdf", data: Data("{\"schemaVersion\":2,\"pages\":[],\"objects\":[{\"id\":\"box\",\"text\":\"\(value)\"}]}".utf8), resource: "annotations")
        }
        _ = try await phone.synchronize(using: server); _ = try await mac.synchronize(using: server)
        XCTAssertEqual(mac.syncConflicts.count, 1); XCTAssertGreaterThan(mac.pendingCount, 0)
    }

    func testRepeatedIdenticalSavesAndDownloadsDoNotGrowStorage() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "dedup", baseDirectory: dir), server = SyncTestServer()
        for _ in 0..<30 { try local.write(path: "Notes/book.md", data: Data("unchanged".utf8)) }
        _ = try await local.synchronize(using: server)
        for _ in 0..<10 { _ = try await local.synchronize(using: server) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.directory.appendingPathComponent("objects").path).count, 1)
        XCTAssertEqual(local.pendingCount, 0)
    }
    func testCleanupProtectsEveryPendingSaveAcrossRestartThenReleasesAcknowledgedObjects() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "pending-gc", baseDirectory: dir), server = SyncTestServer()
        for n in 0..<25 { try local.write(path: "Notes/book.md", data: Data("offline \(n)".utf8)) }
        let reopened = try LocalWorkspace(scope: "pending-gc", baseDirectory: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: reopened.directory.appendingPathComponent("objects").path).count, 25)
        XCTAssertEqual(try text(reopened, "Notes/book.md"), "offline 24")
        _ = try await reopened.synchronize(using: server)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: reopened.directory.appendingPathComponent("objects").path).count, 1)
    }
    func testOpenPDFURLRemainsReadableDuringReplacement() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "open-url", baseDirectory: dir), server = SyncTestServer()
        try local.write(path: "Notes/book.pdf", data: Data("old pdf".utf8)); _ = try await local.synchronize(using: server)
        let displayed = try XCTUnwrap(local.url(path: "Notes/book.pdf")); local.setOpenFile(displayed)
        try local.write(path: "Notes/book.pdf", data: Data("new pdf".utf8)); _ = try await local.synchronize(using: server)
        XCTAssertEqual(try Data(contentsOf: displayed), Data("old pdf".utf8))
        local.setOpenFile(nil); _ = try await local.synchronize(using: server)
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayed.path))
        XCTAssertEqual(try text(local, "Notes/book.pdf"), "new pdf")
    }
    func testRetainedInactivePDFURLRemainsReadableDuringReplacementUntilReleased() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "retained-open-url", baseDirectory: dir), server = SyncTestServer()
        try local.write(path: "Notes/book.pdf", data: Data("old pdf".utf8)); _ = try await local.synchronize(using: server)
        let displayed = try XCTUnwrap(local.url(path: "Notes/book.pdf"))
        local.setRetainedOpenFiles([displayed]); local.setOpenFile(nil)
        try local.write(path: "Notes/book.pdf", data: Data("new pdf".utf8)); _ = try await local.synchronize(using: server)
        XCTAssertEqual(try Data(contentsOf: displayed), Data("old pdf".utf8))
        local.setRetainedOpenFiles([]); _ = try await local.synchronize(using: server)
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayed.path))
        XCTAssertEqual(try text(local, "Notes/book.pdf"), "new pdf")
    }

    func testPDFAnnotationOnlyChangesReuseOriginalPDFObject() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "pdf-dedup", baseDirectory: dir)
        var annotations = PDFAnnotationDocument(schemaVersion: 2, documentPath: "Notes/book.pdf", updatedAt: nil, pages: [], objects: [])
        for n in 0..<10 { annotations.updatedAt = "edit-\(n)"; try local.writePDF(path: "Notes/book.pdf", pdf: Data("%PDF original".utf8), annotations: annotations) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.directory.appendingPathComponent("objects").path).filter { $0.hasSuffix(".pdf") }.count, 1)
    }
    func testUndoRedoIsAutosavedAsNewChangesAndClearsWhenLeavingEditor() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "undo", baseDirectory: dir)
        try local.write(path: "Notes/book.md", data: Data("base".utf8))
        let store = WorkspaceStore(localWorkspace: local)
        await store.loadFile(try XCTUnwrap(local.items.first)); store.startEditingSelectedFile()
        store.editorText = "edited"; XCTAssertTrue(store.persistEditorText()); XCTAssertTrue(store.editorHistory.canUndo)
        store.undoEditorChange(); XCTAssertTrue(store.persistEditorText()); XCTAssertEqual(try text(local, "Notes/book.md"), "base")
        store.redoEditorChange(); XCTAssertTrue(store.persistEditorText()); XCTAssertEqual(try text(local, "Notes/book.md"), "edited")
        store.finishEditingSelectedFile(); XCTAssertFalse(store.editorHistory.canUndo); XCTAssertFalse(store.editorHistory.canRedo)
    }
    func testUndoHistoryGroupsTypingAndBoundsCountAndBytes() {
        var history = TextEditHistory(); let now = Date(timeIntervalSince1970: 1000)
        history.record("", at: now); history.record("h", at: now.addingTimeInterval(0.2))
        XCTAssertEqual(history.backward("hi"), ""); XCTAssertEqual(history.forward(""), "hi")
        history.record("replacement", groupTyping: false); XCTAssertFalse(history.canRedo)
        history.clear(); for n in 0..<200 { history.record("\(n)", groupTyping: false) }
        var count = 0; while history.backward("current") != nil { count += 1 }; XCTAssertEqual(count, 80)
        history.clear(); history.record(String(repeating: "x", count: 9 * 1024 * 1024), groupTyping: false); XCTAssertFalse(history.canUndo)
    }
    func testPDFSyncMetadataDoesNotInvalidateEditorUndoButRealContentDoes() throws {
        let local = PDFAnnotationDocument(schemaVersion: 2, documentPath: "", updatedAt: nil, pages: [PDFAnnotationPage(pageIndex: 0, inkDataBase64: nil, objects: [])], objects: [])
        var server = local; server.documentPath = "Notes/book.pdf"; server.updatedAt = "2026-01-01T00:00:00.123Z"; server.pages[0].pageId = "index:0"
        XCTAssertTrue(local.editorContentMatches(server))
        server.pages[0].inkDataBase64 = "changed opaque ink"
        XCTAssertFalse(local.editorContentMatches(server))
    }

    func testLocalFilesPersistAcrossRestartWithoutServerOrCache() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "guest", baseDirectory: dir)
        try local.createFolder(path: "Notes/books")
        try local.write(path: "Notes/books/book.md", data: Data("offline notes".utf8), createOnly: true)
        let reopened = try LocalWorkspace(scope: "guest", baseDirectory: dir)
        XCTAssertEqual(try text(reopened, "Notes/books/book.md"), "offline notes")
        XCTAssertEqual(reopened.pendingCount, 2)
        XCTAssertEqual(reopened.items.count, 2)
        XCTAssertFalse(reopened.directory.path.contains("Caches"))
    }
    func testAutosaveRetainsEditTimeInsteadOfLaterPersistenceTime() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "edit-time", baseDirectory: dir)
        let edit = Date(timeIntervalSince1970: 1_767_225_610)
        try local.write(path: "Notes/book.md", data: Data("first".utf8), modifiedAt: edit)
        let first = try XCTUnwrap(local.entry(path: "Notes/book.md"))
        XCTAssertEqual(first.modifiedAt, "2026-01-01T00:00:10.000Z")
        try local.write(path: "Notes/book.md", data: Data("second".utf8), modifiedAt: edit.addingTimeInterval(10))
        let reopened = try LocalWorkspace(scope: "edit-time", baseDirectory: dir)
        XCTAssertEqual(reopened.entry(path: "Notes/book.md")?.modifiedAt, "2026-01-01T00:00:20.000Z")
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: reopened.directory.appendingPathComponent("state.json"))) as! [String: Any]
        let operations = try XCTUnwrap(state["pendingOperations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, 2)
        let older = try XCTUnwrap(operations.first?["change"] as? [String: Any])
        let newer = try XCTUnwrap(operations.last?["change"] as? [String: Any])
        XCTAssertEqual(newer["baseVersion"] as? String, older["operationId"] as? String)
        XCTAssertEqual(older["modifiedAt"] as? String, first.modifiedAt)
    }
    func testEditorAutosavesOfflineWithoutSaveButtonAndRemainsEditing() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "autosave", baseDirectory: dir)
        try local.write(path: "Notes/book.md", data: Data("base".utf8))
        let store = WorkspaceStore(localWorkspace: local)
        await store.loadFile(try XCTUnwrap(local.items.first))
        store.startEditingSelectedFile(); store.editorText = "automatically saved"
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(try text(local, "Notes/book.md"), "automatically saved")
        XCTAssertTrue(store.isEditingFile); XCTAssertFalse(store.selectedFileIsDirty)
        let reopened = try LocalWorkspace(scope: "autosave", baseDirectory: dir)
        XCTAssertEqual(try text(reopened, "Notes/book.md"), "automatically saved")
    }
    func testNavigationAndBackgroundFlushPendingAutosaveToItsOriginalFile() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let local = try LocalWorkspace(scope: "autosave", baseDirectory: dir)
        try local.write(path: "Notes/a.md", data: Data("a".utf8)); try local.write(path: "Notes/b.md", data: Data("b".utf8))
        let store = WorkspaceStore(localWorkspace: local)
        await store.loadFile(try XCTUnwrap(local.items.first { $0.path == "Notes/a.md" }))
        store.startEditingSelectedFile(); store.editorText = "before navigation"
        await store.loadFile(try XCTUnwrap(local.items.first { $0.path == "Notes/b.md" }))
        XCTAssertEqual(try text(local, "Notes/a.md"), "before navigation")
        store.startEditingSelectedFile(); store.editorText = "before background"
        XCTAssertTrue(store.persistEditorText())
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(try text(local, "Notes/b.md"), "before background")
        XCTAssertEqual(try text(local, "Notes/a.md"), "before navigation")
    }
    func testTwoDevicesReadAndUpdateTheSameBook() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let phone = try LocalWorkspace(scope: "phone-A", baseDirectory: dir)
        let tablet = try LocalWorkspace(scope: "tablet-A", baseDirectory: dir)
        let server = SyncTestServer()
        try phone.write(path: "Notes/book.md", data: Data("phone".utf8))
        _ = try await phone.synchronize(using: server)
        _ = try await tablet.synchronize(using: server)
        XCTAssertEqual(try text(tablet, "Notes/book.md"), "phone")
        try tablet.write(path: "Notes/book.md", data: Data("tablet edit".utf8))
        _ = try await tablet.synchronize(using: server)
        _ = try await phone.synchronize(using: server)
        XCTAssertEqual(try text(phone, "Notes/book.md"), "tablet edit")
        XCTAssertEqual(phone.pendingCount, 0)
    }
    func testTransportAcknowledgementsReplaceBytesWithoutCreatingCopies() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir), b = try LocalWorkspace(scope: "b", baseDirectory: dir)
        let server = SyncTestServer()
        try a.write(path: "Notes/book.md", data: Data("base".utf8)); _ = try await a.synchronize(using: server); _ = try await b.synchronize(using: server)
        try a.write(path: "Notes/book.md", data: Data("offline A".utf8)); try b.write(path: "Notes/book.md", data: Data("offline B".utf8))
        _ = try await b.synchronize(using: server)
        let report = try await a.synchronize(using: server)
        XCTAssertEqual(report.conflicts.count, 0)
        XCTAssertEqual(try text(a, "Notes/book.md"), "offline A")
        _ = try await a.synchronize(using: server); _ = try await b.synchronize(using: server)
        XCTAssertEqual(b.fileCount, 1)
        XCTAssertEqual(try text(b, "Notes/book.md"), "offline A")
    }

    #if os(macOS)
    func testSwiftHTTPTransportMergesWithRealServerAndRecoversLostResponse() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        var root = URL(fileURLWithPath: #filePath)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("server/lib/test-support/versioned-http-fixture.mjs").path) {
            let parent = root.deletingLastPathComponent()
            guard parent.path != root.path else { throw CocoaError(.fileNoSuchFile) }
            root = parent
        }
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("server/lib/test-support/versioned-http-fixture.mjs").path]
        process.standardOutput = output; process.standardError = Pipe()
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        let config = try JSONSerialization.jsonObject(with: line) as! [String: String]
        let url = try XCTUnwrap(URL(string: try XCTUnwrap(config["url"])))
        let api = WorkspaceAPI(baseURL: url, authToken: "test-profile-a")
        let phone = try LocalWorkspace(scope: "native-phone", baseDirectory: dir)
        let tablet = try LocalWorkspace(scope: "native-tablet", baseDirectory: dir)
        try phone.write(path: "Notes/book.md", data: Data("red cat\n".utf8))
        _ = try await phone.synchronize(using: api); _ = try await tablet.synchronize(using: api)
        try phone.write(path: "Notes/book.md", data: Data("blue cat\n".utf8))
        try await Task.sleep(nanoseconds: 10_000_000)
        try tablet.write(path: "Notes/book.md", data: Data("red dog\n".utf8))
        _ = try await tablet.synchronize(using: api); _ = try await phone.synchronize(using: api)
        _ = try await tablet.synchronize(using: api)
        XCTAssertEqual(try text(phone, "Notes/book.md"), "blue dog\n")
        XCTAssertEqual(try text(tablet, "Notes/book.md"), "blue dog\n")
        var drop = URLRequest(url: url.appendingPathComponent("fixture/drop-next")); drop.httpMethod = "POST"
        drop.setValue("Bearer test-profile-a", forHTTPHeaderField: "Authorization")
        _ = try await URLSession.shared.data(for: drop)
        try phone.write(path: "Notes/book.md", data: Data("blue dog!\n".utf8))
        do { _ = try await phone.synchronize(using: api) } catch { /* May transparently retry; IDs remain stable. */ }
        let reopened = try LocalWorkspace(scope: "native-phone", baseDirectory: dir)
        _ = try await reopened.synchronize(using: api)
        XCTAssertEqual(reopened.pendingCount, 0)
        XCTAssertEqual(try text(reopened, "Notes/book.md"), "blue dog!\n")
        let history = try await api.syncHistory(path: "Notes/book.md", resource: "file")
        XCTAssertGreaterThan(history.entries.count, 2)
        let annotation = PDFAnnotationDocument(schemaVersion: 2, documentPath: "Notes/book.pdf", updatedAt: nil, pages: [PDFAnnotationPage(pageIndex: 0, inkDataBase64: nil, objects: [])], objects: [])
        try phone.writePDF(path: "Notes/book.pdf", pdf: Data("%PDF fixture".utf8), annotations: annotation)
        _ = try await phone.synchronize(using: api)
        let acknowledged = try JSONDecoder().decode(PDFAnnotationDocument.self, from: phone.read(path: "Notes/book.pdf", resource: "annotations"))
        XCTAssertTrue(annotation.editorContentMatches(acknowledged))
        // Independent original + ink imports attach to ONE server book, not two IDs.
        let independent = try LocalWorkspace(scope: "native-independent-pdf", baseDirectory: dir)
        try independent.writePDF(path: "Notes/book.pdf", pdf: Data("%PDF fixture".utf8), annotations: annotation)
        try independent.setMode(path: "Notes/book.pdf", mode: .local)
        _ = try await independent.synchronize(using: api)
        XCTAssertEqual(independent.entry(path: "Notes/book.pdf")?.fileId, phone.entry(path: "Notes/book.pdf")?.fileId)
        XCTAssertEqual(independent.mode(path: "Notes/book.pdf"), .sync)
        // Replacing a different original with no ink clears the old sidecar atomically.
        let replacement = try LocalWorkspace(scope: "native-replacement-pdf", baseDirectory: dir)
        try replacement.write(path: "Notes/book.pdf", data: Data("%PDF different book".utf8))
        _ = try await replacement.synchronize(using: api)
        let collision = try XCTUnwrap(replacement.syncConflicts.first { $0.path == "Notes/book.pdf" })
        try await replacement.resolveConflict(collision, useServer: false, using: api)
        _ = try await replacement.synchronize(using: api)
        XCTAssertEqual(replacement.pendingCount, 0)
        let finalPDF = try await api.syncManifest().entries.first { $0.path == "Notes/book.pdf" && $0.resource == "file" }
        XCTAssertEqual(finalPDF?.annotationFingerprint, "none")
        XCTAssertEqual(finalPDF?.revision, LocalWorkspace.digest(Data("%PDF different book".utf8)))
        let privateProfile = try LocalWorkspace(scope: "native-private", baseDirectory: dir)
        _ = try await privateProfile.synchronize(using: WorkspaceAPI(baseURL: url, authToken: "test-profile-b"))
        XCTAssertEqual(privateProfile.fileCount, 0)
        var stop = URLRequest(url: url.appendingPathComponent("fixture/stop")); stop.httpMethod = "POST"
        stop.setValue("Bearer test-profile-a", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: stop)
        process.waitUntilExit()
    }
    #endif
    func testOpenEditorKeepsDisplayedContentPairedWithItsOriginalAncestor() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir), b = try LocalWorkspace(scope: "b", baseDirectory: dir)
        let server = SyncTestServer()
        try a.write(path: "Notes/book.md", data: Data("base".utf8)); _ = try await a.synchronize(using: server); _ = try await b.synchronize(using: server)
        let before = a.entry(path: "Notes/book.md")?.revision
        a.setEditingPath("Notes/book.md")
        try b.write(path: "Notes/book.md", data: Data("remote".utf8)); _ = try await b.synchronize(using: server)
        _ = try await a.synchronize(using: server)
        XCTAssertEqual(try text(a, "Notes/book.md"), "base"); XCTAssertEqual(a.entry(path: "Notes/book.md")?.revision, before)
        try a.write(path: "Notes/book.md", data: Data("editor change".utf8))
        _ = try await a.synchronize(using: server); XCTAssertEqual(a.pendingCount, 1)
        a.setEditingPath(nil); _ = try await a.synchronize(using: server); XCTAssertEqual(a.pendingCount, 0)
    }
    func testMergedAcknowledgementDownloadsActualBytesInsteadOfRelabelingUploadedObject() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir); let server = SyncTestServer()
        try a.write(path: "Notes/book.md", data: Data("local".utf8))
        await server.mergeNextUpload(Data("remote and local merged".utf8))
        let report = try await a.synchronize(using: server)
        XCTAssertEqual(try text(a, "Notes/book.md"), "remote and local merged")
        XCTAssertEqual(a.entry(path: "Notes/book.md")?.revision, LocalWorkspace.digest(try a.read(path: "Notes/book.md")))
        XCTAssertEqual(a.pendingCount, 0); XCTAssertEqual(a.fileCount, 1); XCTAssertEqual(report.downloaded, 1)
    }
    func testEditDuringMergedUploadRetainsItsOriginalAncestorAndNewPendingContent() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir); let server = SyncTestServer()
        try a.write(path: "Notes/book.md", data: Data("base".utf8)); _ = try await a.synchronize(using: server)
        try a.write(path: "Notes/book.md", data: Data("first".utf8)); await server.pauseNextUpload()
        await server.mergeNextUpload(Data("merged with remote".utf8))
        let sync = Task { try await a.synchronize(using: server) }
        await server.waitForUpload(); try a.write(path: "Notes/book.md", data: Data("second".utf8)); await server.resumeUpload()
        _ = try await sync.value
        XCTAssertEqual(a.pendingCount, 1); XCTAssertEqual(try text(a, "Notes/book.md"), "second")
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: a.directory.appendingPathComponent("state.json"))) as! [String: Any]
        let records = state["records"] as! [String: [String: Any]]
        XCTAssertEqual(records["file:Notes/book.md"]?["baseRevision"] as? String, LocalWorkspace.digest(Data("base".utf8)))
        _ = try await a.synchronize(using: server); XCTAssertEqual(a.pendingCount, 0)
    }
    func testLostResponseRetriesWithoutDuplicatingOrLosingData() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir); let server = SyncTestServer()
        try a.write(path: "Notes/book.md", data: Data("important".utf8)); await server.loseNextResponse()
        _ = try await a.synchronize(using: server)
        XCTAssertNotNil(a.transferStates["Notes/book.md"], "An interrupted file stays pending without blocking other files")
        XCTAssertEqual(a.pendingCount, 1)
        let restart = try LocalWorkspace(scope: "a", baseDirectory: dir)
        _ = try await restart.synchronize(using: server)
        XCTAssertEqual(restart.pendingCount, 0); XCTAssertEqual(restart.fileCount, 1)
        XCTAssertEqual(try text(restart, "Notes/book.md"), "important")
    }
    func testEditingWhileUploadIsInFlightKeepsTheNewEditPending() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir); let server = SyncTestServer()
        try a.write(path: "Notes/book.md", data: Data("first".utf8)); await server.pauseNextUpload()
        let sync = Task { try await a.synchronize(using: server) }
        await server.waitForUpload()
        try a.write(path: "Notes/book.md", data: Data("second".utf8)); await server.resumeUpload()
        _ = try await sync.value
        XCTAssertEqual(a.pendingCount, 1); XCTAssertEqual(try text(a, "Notes/book.md"), "second")
        _ = try await a.synchronize(using: server); XCTAssertEqual(a.pendingCount, 0)
    }
    func testAccountIsolationAndExplicitGuestImportPreserveOriginals() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let guest = try LocalWorkspace(scope: "guest", baseDirectory: dir), a = try LocalWorkspace(scope: "server|A", baseDirectory: dir), b = try LocalWorkspace(scope: "server|B", baseDirectory: dir)
        try guest.write(path: "Notes/book.md", data: Data("guest".utf8)); try a.write(path: "Notes/book.md", data: Data("A".utf8))
        try a.importWorkspace(guest)
        XCTAssertEqual(a.fileCount, 2); XCTAssertEqual(b.fileCount, 0)
        XCTAssertEqual(try text(a, "Notes/book.md"), "A"); XCTAssertEqual(try text(guest, "Notes/book.md"), "guest")
        try a.importWorkspace(guest); XCTAssertEqual(a.fileCount, 2)
    }
    func testPDFAnnotationImportKeepsTheSidecarWithItsRenamedDocument() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let guest = try LocalWorkspace(scope: "guest", baseDirectory: dir), a = try LocalWorkspace(scope: "A", baseDirectory: dir)
        try guest.write(path: "Notes/book.pdf", data: Data("guest pdf".utf8))
        try guest.write(path: "Notes/book.pdf", data: Data(#"{"documentPath":"Notes/book.pdf","pages":[],"objects":[],"schemaVersion":2}"#.utf8), resource: "annotations")
        try a.write(path: "Notes/book.pdf", data: Data("account pdf".utf8)); try a.importWorkspace(guest)
        let imported = try XCTUnwrap(a.items.first(where: { $0.path != "Notes/book.pdf" }))
        let annotations = try JSONDecoder().decode(PDFAnnotationDocument.self, from: a.read(path: imported.path, resource: "annotations"))
        XCTAssertEqual(annotations.documentPath, imported.path)
        XCTAssertNil(a.entry(path: "Notes/book.pdf", resource: "annotations"))
    }
    func testDeletesAndMovesRetainCurrentAndPendingDataButReleaseOldCopies() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir); let server = SyncTestServer()
        try a.createFolder(path: "Code/project"); try a.write(path: "Code/project/test.swift", data: Data("let a = 1".utf8))
        _ = try await a.synchronize(using: server)
        try a.transfer(from: "Code/project", to: "Code/renamed", move: true)
        _ = try await a.synchronize(using: server)
        XCTAssertNil(a.entry(path: "Code/project/test.swift")); XCTAssertEqual(try text(a, "Code/renamed/test.swift"), "let a = 1")
        try a.delete(path: "Code/renamed"); _ = try await a.synchronize(using: server)
        XCTAssertEqual(a.fileCount, 0); XCTAssertEqual(a.pendingCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: a.directory.appendingPathComponent("objects").path).isEmpty)
    }
    func testRejectsTraversalAndDuplicateCreates() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir)
        for path in ["../outside", "Notes/../Code/x", "Notes/.codmes/x", "Notes//x"] { XCTAssertThrowsError(try a.write(path: path, data: Data())) }
        try a.write(path: "Notes/book.md", data: Data(), createOnly: true)
        XCTAssertThrowsError(try a.write(path: "Notes/book.md", data: Data(), createOnly: true))
    }
    func testFolderFileConflictKeepsLocalChildrenPendingWithoutCopies() async throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir), b = try LocalWorkspace(scope: "b", baseDirectory: dir)
        let server = SyncTestServer()
        try a.createFolder(path: "Notes/name"); try a.write(path: "Notes/name/book.md", data: Data("local child".utf8))
        try b.write(path: "Notes/name", data: Data("remote file".utf8)); _ = try await b.synchronize(using: server)
        let report = try await a.synchronize(using: server)
        XCTAssertTrue(report.conflicts.contains("Notes/name"))
        XCTAssertEqual(try text(a, "Notes/name/book.md"), "local child")
        XCTAssertFalse(a.items.contains { $0.path.contains("충돌 사본") })
        XCTAssertGreaterThan(a.pendingCount, 0)
    }
    func testPDFAndAnnotationsCommitTogetherAcrossRestart() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = try LocalWorkspace(scope: "a", baseDirectory: dir)
        let annotations = PDFAnnotationDocument(schemaVersion: 2, documentPath: "old", updatedAt: nil, pages: [], objects: [])
        try a.writePDF(path: "Notes/book.pdf", pdf: Data("%PDF-1.7\nfixture".utf8), annotations: annotations)
        let reopened = try LocalWorkspace(scope: "a", baseDirectory: dir)
        XCTAssertEqual(reopened.pendingCount, 2)
        XCTAssertEqual(reopened.url(path: "Notes/book.pdf")?.pathExtension, "pdf")
        XCTAssertEqual(try JSONDecoder().decode(PDFAnnotationDocument.self, from: reopened.read(path: "Notes/book.pdf", resource: "annotations")).documentPath, "Notes/book.pdf")
    }
    func testEditablePDFArchiveRoundTripAndCorruptionProtection() throws {
        let annotations = PDFAnnotationDocument(schemaVersion: 2, documentPath: "Notes/book.pdf", updatedAt: nil, pages: [], objects: [])
        let pdf = Data("%PDF-1.7\nfixture".utf8)
        let archive = try CodmesPDFArchive.create(pdf: pdf, annotations: annotations, title: "fixture")
        let decoded = try CodmesPDFArchive.read(archive)
        XCTAssertEqual(decoded.pdf, pdf); XCTAssertEqual(decoded.annotations.documentPath, annotations.documentPath)
        var corrupted = archive; corrupted[80] ^= 0xff
        XCTAssertThrowsError(try CodmesPDFArchive.read(corrupted))
        XCTAssertThrowsError(try CodmesPDFArchive.read(Data(archive.prefix(50))))
    }
    func testReadsDeflatedEditablePDFExportedByServer() throws {
        let fixture = "UEsDBBQAAAAIAACOQV0xni61/gAAAKUBAAANAAAAbWFuaWZlc3QuanNvbm2PTWrEMAxG93OKkHUTJCcTO7PrHUoX3cm2xKSd/BA7UChz99oJpVMoaCPp8fTp61QUpczrSLG8FKWb/cihWryUT3kT3JVHeuU1DPOUANyncYg3zrgMn3Fb+WDdyhTZP+8iBaqrECrAF4DLXm8HRsvy6yuhxhqOhQw3DmmWI6U2Z0iAn9028hTrn0xZMU1zpJgUmX9s6/eQvIm6H5Gu7D7CNj5o//jyC2eD4oyWBlTfsQii1to1jtH2ZKwGnQrJG7LsxVlqUAsLOANaqfafTEeI5EYFbK1trbLCDSabJxIANIq992jI92gaEILOpbtk+zO3ynPLZKGj/ZHT/fQNUEsDBBQAAAAIAACOQV16bM43EgAAABAAAAAMAAAAZG9jdW1lbnQucGRmUw1wcdM11DPnSsusKCktSgUAUEsDBBQAAAAIAACOQV2UZrmzUAAAAF0AAAAQAAAAYW5ub3RhdGlvbnMuanNvbqvmUlBQKk7OSM1NDEstKs7Mz1OyUjDSAYmm5CeX5qbmlQQklmQABZX88ktSi/WT8vOz9QpS0pTAagoS01OLgZLRsWBuflJWanIJRICrlgsAUEsBAhQAFAAAAAgAAI5BXTGeLrX+AAAApQEAAA0AAAAAAAAAAAAAAAAAAAAAAG1hbmlmZXN0Lmpzb25QSwECFAAUAAAACAAAjkFdemzONxIAAAAQAAAADAAAAAAAAAAAAAAAAAApAQAAZG9jdW1lbnQucGRmUEsBAhQAFAAAAAgAAI5BXZRmubNQAAAAXQAAABAAAAAAAAAAAAAAAAAAZQEAAGFubm90YXRpb25zLmpzb25QSwUGAAAAAAMAAwCzAAAA4wEAAAAA"
        let decoded = try CodmesPDFArchive.read(XCTUnwrap(Data(base64Encoded: fixture)))
        XCTAssertEqual(decoded.pdf, Data("%PDF-1.7\nfixture".utf8))
        XCTAssertEqual(decoded.annotations.documentPath, "Notes/book.pdf")
    }
}
