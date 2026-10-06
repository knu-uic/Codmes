import CryptoKit
import Foundation

/// Session-only editor undo, never a synchronized version archive.
struct TextEditHistory {
    private(set) var undo: [String] = []
    private(set) var redo: [String] = []
    private var lastEdit: Date?
    var canUndo: Bool { !undo.isEmpty }
    var canRedo: Bool { !redo.isEmpty }
    mutating func clear() { undo = []; redo = []; lastEdit = nil }
    mutating func record(_ before: String, at time: Date = Date(), groupTyping: Bool = true) {
        if !groupTyping || lastEdit == nil || time.timeIntervalSince(lastEdit!) > 0.6 || !redo.isEmpty { undo.append(before) }
        redo = []; lastEdit = groupTyping ? time : nil; trim()
    }
    mutating func backward(_ current: String) -> String? {
        guard let value = undo.popLast() else { return nil }
        redo.append(current); lastEdit = nil; trim(); return value
    }
    mutating func forward(_ current: String) -> String? {
        guard let value = redo.popLast() else { return nil }
        undo.append(current); lastEdit = nil; trim(); return value
    }
    private mutating func trim() {
        while undo.count + redo.count > 80 || (undo + redo).reduce(0, { $0 + $1.utf8.count }) > 8 * 1024 * 1024 {
            if !undo.isEmpty { undo.removeFirst() } else if !redo.isEmpty { redo.removeFirst() } else { break }
        }
    }
}

struct WorkspaceSyncEntry: Codable, Sendable, Equatable {
    var path: String
    let resource: String
    let kind: String
    let isDirectory: Bool
    let size: Int
    var modifiedAt: String
    let revision: String
    var versionId: String? = nil
    var logicalModifiedAt: String? = nil
    var fileId: String? = nil
    var annotationFingerprint: String? = nil
    var key: String { "\(resource):\(path)" }
}

struct WorkspaceSyncDeletedEntry: Codable, Sendable { let path: String; let resource: String; let versionId: String; let modifiedAt: String }
struct WorkspaceSyncManifest: Codable, Sendable { let version: Int; let entries: [WorkspaceSyncEntry]; var conflictPolicies: [String]? = nil; var deletedEntries: [WorkspaceSyncDeletedEntry]? = nil; var selectiveSyncVersion: Int? = nil; var catalogRevision: Int? = nil; var serverId: String? = nil; var documentBundleVersion: Int? = nil }
struct WorkspaceSyncResult: Codable, Sendable { let status: String; let entry: WorkspaceSyncEntry?; var reason: String? = nil }
struct WorkspaceHistoryEntry: Codable, Sendable, Identifiable {
    let versionId: String
    let revision: String?
    let modifiedAt: String
    let deviceId: String
    let deleted: Bool
    var original: Bool? = nil
    var baseline: Bool? = nil
    var id: String { versionId + (original == true ? "-original" : "") }
}
struct WorkspaceHistoryPage: Codable, Sendable { let entries: [WorkspaceHistoryEntry]; let nextOffset: Int? }
struct WorkspaceRecoveryEntry: Codable, Sendable { let path: String; let modifiedAt: String }
struct WorkspaceRecoveryIndex: Codable, Sendable { let entries: [WorkspaceRecoveryEntry] }
struct WorkspaceSyncChange: Encodable, Sendable, Equatable {
    var path: String
    let resource: String
    let action: String
    let baseRevision: String?
    var operationId: String? = nil
    var deviceId: String? = nil
    var modifiedAt: String? = nil
    var baseVersion: String? = nil
    var fileId: String? = nil
    var firstRegistration: Bool? = nil
    var expectedRevision: String? = nil
    var conflictPolicy: String { operationId == nil ? "merge-latest" : "merge-modified-v2" }
    enum CodingKeys: CodingKey { case path, resource, action, baseRevision, conflictPolicy, operationId, deviceId, modifiedAt, baseVersion, fileId, firstRegistration, expectedRevision }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path); try c.encode(resource, forKey: .resource)
        try c.encode(action, forKey: .action)
        try c.encode(conflictPolicy, forKey: .conflictPolicy)
        try c.encodeIfPresent(operationId, forKey: .operationId); try c.encodeIfPresent(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt); try c.encodeIfPresent(baseVersion, forKey: .baseVersion)
        try c.encodeIfPresent(fileId, forKey: .fileId); try c.encodeIfPresent(firstRegistration, forKey: .firstRegistration); try c.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
        if let baseRevision { try c.encode(baseRevision, forKey: .baseRevision) }
        else { try c.encodeNil(forKey: .baseRevision) }
    }
}

extension WorkspaceSyncChange: Decodable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path); resource = try c.decode(String.self, forKey: .resource)
        action = try c.decode(String.self, forKey: .action); baseRevision = try c.decodeIfPresent(String.self, forKey: .baseRevision)
        operationId = try c.decodeIfPresent(String.self, forKey: .operationId); deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        modifiedAt = try c.decodeIfPresent(String.self, forKey: .modifiedAt); baseVersion = try c.decodeIfPresent(String.self, forKey: .baseVersion)
        fileId = try c.decodeIfPresent(String.self, forKey: .fileId); firstRegistration = try c.decodeIfPresent(Bool.self, forKey: .firstRegistration); expectedRevision = try c.decodeIfPresent(String.self, forKey: .expectedRevision)
    }
}

protocol WorkspaceSyncTransport: Sendable {
    func syncManifest() async throws -> WorkspaceSyncManifest
    func downloadSyncBlob(_ entry: WorkspaceSyncEntry) async throws -> URL
    func applySyncChange(_ change: WorkspaceSyncChange, file: URL?) async throws -> WorkspaceSyncResult
    func reportStoragePolicies(deviceId: String, policies: [WorkspaceDevicePolicy]) async throws
    func moveSyncFile(_ move: WorkspaceSyncMove) async throws -> WorkspaceSyncResult
    func applyDocumentBundle(fileChange: WorkspaceSyncChange, file: URL, annotationChange: WorkspaceSyncChange, annotations: URL) async throws -> WorkspaceSyncResult
}
extension WorkspaceSyncTransport {
    func reportStoragePolicies(deviceId: String, policies: [WorkspaceDevicePolicy]) async throws {}
    func moveSyncFile(_ move: WorkspaceSyncMove) async throws -> WorkspaceSyncResult { throw LocalWorkspaceError.serverUpgradeRequired }
    func applyDocumentBundle(fileChange: WorkspaceSyncChange, file: URL, annotationChange: WorkspaceSyncChange, annotations: URL) async throws -> WorkspaceSyncResult { throw LocalWorkspaceError.serverUpgradeRequired }
}
struct WorkspaceSyncMove: Codable, Sendable, Equatable { var from: String; var to: String; let fileId: String; let expectedRevision: String }

enum WorkspaceStorageMode: String, Codable, CaseIterable, Sendable {
    case local, server, sync
    var title: String { switch self { case .local: "로컬"; case .server: "서버"; case .sync: "동기화" } }
    var icon: String { switch self { case .local: "internaldrive"; case .server: "cloud"; case .sync: "arrow.triangle.2.circlepath" } }
}
struct WorkspaceDevicePolicy: Codable, Sendable { let fileId: String; let mode: WorkspaceStorageMode; let locallyAvailable: Bool; let pending: Bool }
struct WorkspaceSyncConflict: Codable, Sendable, Identifiable, Equatable {
    let path: String; let server: WorkspaceSyncEntry?; let localRevision: String; let reason: String
    var localAnnotationFingerprint: String? = nil
    var id: String { path }
    var isNameConflict: Bool { ["structure", "first-registration", "destination-exists", "destination-state-exists"].contains(reason) }
    var title: String { isNameConflict ? "서버에 같은 경로의 다른 자료가 있습니다" : "동기화 확인이 필요합니다" }
    var message: String {
        switch reason {
        case "structure": "같은 경로에 파일과 폴더가 겹칩니다. 이름을 변경하거나 나중에 결정하세요."
        case "first-registration", "destination-exists", "destination-state-exists": "같은 경로의 다른 자료와 겹칩니다. 이름을 변경하거나 사용할 자료를 선택하세요."
        case "base-missing": "이름 중복이 아니라 동기화 기준 이력을 확인할 수 없는 상태입니다. 로컬 자료는 보존됩니다. 다시 동기화해 주세요."
        case "file-moved", "file-missing", "document-missing": "서버에서 자료가 이동되거나 삭제되었습니다. 로컬 자료는 보존됩니다. 다시 동기화해 주세요."
        default: "동기화 중 자료가 변경되었습니다. 로컬 자료는 보존됩니다. 다시 동기화하거나 사용할 자료를 선택하세요."
        }
    }
}

enum LocalWorkspaceError: Error, LocalizedError {
        case invalidPath, exists, missing, incompleteDownload, invalidManifest, busy, serverUpgradeRequired, insufficientSpace, staleDecision
    var errorDescription: String? {
        switch self {
        case .invalidPath: "Notes 또는 Code 안의 유효한 경로를 사용하세요."
        case .exists: "같은 이름의 파일이나 폴더가 있습니다."
        case .missing: "로컬 자료가 없습니다. 먼저 다운로드하세요."
        case .incompleteDownload: "서버 파일이 변경되었거나 다운로드가 불완전합니다. 다음 동기화에서 다시 확인합니다."
        case .invalidManifest: "지원하지 않는 동기화 자료입니다. 로컬 자료는 유지됩니다."
        case .busy: "이 저장소를 동기화하는 중입니다."
        case .serverUpgradeRequired: "변경별 동기화를 지원하는 서버로 업데이트하세요. 로컬 자료와 미전송 변경은 유지됩니다."
        case .insufficientSpace: "저장공간이 부족합니다. 서버 모드로 변경하거나 공간 확보 후 다시 시도하세요."
        case .staleDecision: "확인 중 파일이 변경되었습니다. 최신 내용을 다시 확인하세요."
        }
    }
}

struct LocalSyncReport: Sendable {
    var uploaded = 0
    var downloaded = 0
    var conflicts: [String] = []
    var paused: [String] = []

    func statusMessage(pendingChanges: Int) -> String {
        if !paused.isEmpty { return "전송 보류 \(paused.count)개. 파일 옆 상태를 확인하세요." }
        if !conflicts.isEmpty {
            return "로컬 변경 보존 · 동기화 대기: \(conflicts.joined(separator: ", ")). 서버 버전 또는 파일·폴더/삭제 충돌을 확인하세요."
        }
        if pendingChanges > 0 { return "로컬 변경 보존 · 미전송 자료 \(pendingChanges)개" }
        return uploaded > 0 || downloaded > 0 ? "저장 모드에 따라 동기화 완료" : "로컬 자료 최신 상태"
    }
}

/// Permanent, local-first storage. Immutable objects are written BEFORE the atomic journal.
/// Current data and every unacknowledged edit survive cache trimming and cleanup.
@MainActor
final class LocalWorkspace {
    struct Record: Codable, Sendable, Equatable {
        var entry: WorkspaceSyncEntry
        var object: String?
        var baseRevision: String?
        var dirty: Bool
        var deleted: Bool
        var localId: String? = nil
        var linked: Bool? = nil
    }
    private struct PendingOperation: Codable, Equatable {
        var change: WorkspaceSyncChange
        var record: Record
    }
    private struct State: Codable, Equatable {
        var version = 1
        var records: [String: Record] = [:]
        var archived: [Record] = []
        var importedLocalObjects: Set<String> = []
        var importedDestinations: [String: String]? = [:]
        var pendingOperations: [PendingOperation]? = []
        var deviceId: String? = nil
        var lastModifiedTime: Double? = nil
        var modes: [String: WorkspaceStorageMode]? = nil
        var localOnly: Set<String>? = nil
        var conflicts: [String: WorkspaceSyncConflict]? = nil
        var pendingMoves: [WorkspaceSyncMove]? = nil
    }
    let directory: URL
    private var state: State
    private(set) var isSynchronizing = false
    var onChange: (() -> Void)?
    private(set) var transferStates: [String: String] = [:]
    private var serverEntries: [String: WorkspaceSyncEntry] = [:]
    var availableCapacity: (() throws -> Int64)?
    private var editingPath: String?
    private var openObject: String?
    private var retainedOpenObjects: Set<String> = []
    func setOpenFile(_ url: URL?) { openObject = url?.deletingLastPathComponent().standardizedFileURL.path == directory.appendingPathComponent("objects").standardizedFileURL.path ? url?.lastPathComponent : nil }
    func setRetainedOpenFiles(_ urls: [URL]) {
        let objectsPath = directory.appendingPathComponent("objects").standardizedFileURL.path
        retainedOpenObjects = Set(urls.filter { $0.deletingLastPathComponent().standardizedFileURL.path == objectsPath }.map(\.lastPathComponent))
    }
    // Pin displayed bytes and their ancestor until a pending editor draft is locally autosaved.
    func setEditingPath(_ path: String?) { editingPath = path }
    private let manager = FileManager.default
    private let encoder = JSONEncoder()

    init(scope: String, baseDirectory: URL? = nil) throws {
        let base = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codmes/LocalWorkspaces/v1", isDirectory: true)
        directory = base.appendingPathComponent(Self.digest(Data(scope.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("objects"), withIntermediateDirectories: true)
        let journal = directory.appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: journal.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: journal))
            guard state.version == 1 else { throw LocalWorkspaceError.invalidManifest }
        } else { state = State() }
        var migrated = state
        if migrated.deviceId == nil { migrated.deviceId = UUID().uuidString }
        for key in migrated.records.keys {
            let path = migrated.records[key]!.entry.path
            let document = migrated.records["file:\(path)"]
            let identity = migrated.records[key]?.localId ?? document?.localId ?? UUID().uuidString
            migrated.records[key]?.localId = identity
        }
        for key in migrated.records.keys where migrated.records[key]?.entry.resource == "annotations" {
            let path = migrated.records[key]!.entry.path
            let identity = migrated.records["file:\(path)"]?.localId
            migrated.records[key]?.localId = identity
        }
        if migrated.pendingOperations == nil {
            migrated.pendingOperations = []
            // Existing unsent v1 bytes retain their recorded local time, not the migration time.
            for record in state.records.values.filter({ $0.dirty && $0.entry.resource != "folder" }) {
                let id = UUID().uuidString
                var restored = record
                restored.entry.versionId = id
                let change = WorkspaceSyncChange(path: record.entry.path, resource: record.entry.resource, action: record.deleted ? "delete" : "put", baseRevision: record.baseRevision,
                    operationId: id, deviceId: migrated.deviceId, modifiedAt: record.entry.modifiedAt, baseVersion: record.baseRevision.map { "legacy:\($0)" })
                migrated.pendingOperations?.append(PendingOperation(change: change, record: restored))
                migrated.records[record.entry.key] = restored
            }
        }
        try commit(migrated)
    }

    nonisolated static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func digestFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1, ["Notes", "Code"].contains(parts[0]),
              !parts.contains(where: { $0.isEmpty || [".", "..", ".codmes", ".git"].contains($0) }),
              !path.contains("\\"), !path.contains("\0") else { throw LocalWorkspaceError.invalidPath }
    }
    private func commit(_ next: State) throws {
        var compact = next
        compact.archived = []
        for key in compact.records.keys where compact.records[key]?.deleted == true && compact.records[key]?.dirty == false { compact.records[key]?.object = nil }
        // Polling an unchanged manifest must not rewrite the journal or notify the UI.
        if compact != state {
            try encoder.encode(compact).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
            state = compact
            onChange?()
        }
        // Commit references first. A failed cleanup never turns a successful save into
        // a failure or deletes an unsent operation (including intermediate offline saves).
        var retained = Set(compact.records.values.compactMap(\.object))
        retained.formUnion((compact.pendingOperations ?? []).compactMap { $0.record.object })
        if let openObject { retained.insert(openObject) }
        retained.formUnion(retainedOpenObjects)
        if let files = try? manager.contentsOfDirectory(at: directory.appendingPathComponent("objects"), includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for file in files where !retained.contains(file.lastPathComponent) {
                guard let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), properties.isRegularFile == true, properties.isSymbolicLink != true else { continue }
                try? manager.removeItem(at: file)
            }
        }
    }
    private func objectURL(_ object: String) -> URL { directory.appendingPathComponent("objects").appendingPathComponent(object) }
    private func modificationTime(next: inout State, requested: Date? = nil) -> String {
        let milliseconds = max(((requested ?? Date()).timeIntervalSince1970 * 1000).rounded(.down), (next.lastModifiedTime ?? 0) + 1)
        next.lastModifiedTime = milliseconds
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
    private func newObject(data: Data, name: String? = nil) throws -> String {
        let ext = (name as NSString?)?.pathExtension ?? ""
        let object = Self.digest(data) + (ext.isEmpty ? "" : "." + ext)
        if !manager.fileExists(atPath: objectURL(object).path) { try data.write(to: objectURL(object), options: .atomic) }
        else if try Self.digestFile(objectURL(object)) != Self.digest(data) { throw LocalWorkspaceError.incompleteDownload }
        return object
    }
    private func newObject(file: URL, name: String? = nil) throws -> String {
        let ext = ((name ?? file.lastPathComponent) as NSString).pathExtension
        let object = try Self.digestFile(file) + (ext.isEmpty ? "" : "." + ext)
        if !manager.fileExists(atPath: objectURL(object).path) {
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".object-tmp")
            defer { try? manager.removeItem(at: temporary) }
            try manager.copyItem(at: file, to: temporary)
            try manager.moveItem(at: temporary, to: objectURL(object))
        } else if try Self.digestFile(objectURL(object)) != Self.digestFile(file) { throw LocalWorkspaceError.incompleteDownload }
        return object
    }
    var pendingCount: Int { state.records.values.filter(\.dirty).count }
    var pendingSyncCount: Int { state.records.values.filter { $0.dirty && mode(path: $0.entry.path) != .local }.count }
    var syncConflicts: [WorkspaceSyncConflict] { Array((state.conflicts ?? [:]).values).sorted { $0.path < $1.path } }
    var storageModeOverrides: [String: WorkspaceStorageMode] { state.modes ?? [:] }
    private func policyKey(_ path: String, in value: State) -> String {
        let record = value.records["file:\(path)"] ?? value.records["folder:\(path)"]
        return record?.localId.map { "id:\($0)" } ?? path
    }
    func mode(path: String) -> WorkspaceStorageMode {
        var scope = path
        while !scope.isEmpty {
            if let mode = state.modes?[policyKey(scope, in: state)] { return mode }
            if let mode = state.modes?[scope] { return mode }
            scope = (scope as NSString).deletingLastPathComponent
        }
        return .sync
    }
    func keepsLocal(path: String) -> Bool {
        guard mode(path: path) == .local else { return false }
        var scope = path
        while !scope.isEmpty {
            let key = policyKey(scope, in: state)
            if state.modes?[key] != nil || state.modes?[scope] != nil { return state.localOnly?.contains(key) == true || state.localOnly?.contains(scope) == true }
            scope = (scope as NSString).deletingLastPathComponent
        }
        return false
    }
    func setMode(path: String, mode: WorkspaceStorageMode?, keepLocal: Bool = false) throws {
        var next = state; next.modes = next.modes ?? [:]; next.localOnly = next.localOnly ?? []
        let key = policyKey(path, in: next)
        if key != path { next.modes?.removeValue(forKey: path); next.localOnly?.remove(path) }
        next.modes?[key] = mode
        if keepLocal && mode == .local { next.localOnly?.insert(key) } else { next.localOnly?.remove(key) }
        try commit(next)
    }
    var fileCount: Int { state.records.values.filter { !$0.deleted && $0.entry.resource == "file" }.count }
    var items: [WorkspaceItem] {
        state.records.values.filter { !$0.deleted && $0.entry.resource != "annotations" }.map {
            WorkspaceItem(name: ($0.entry.path as NSString).lastPathComponent, path: $0.entry.path,
                          kind: $0.entry.kind, isDirectory: $0.entry.isDirectory, size: $0.entry.size, modifiedAt: $0.entry.modifiedAt)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    func entry(path: String, resource: String = "file") -> WorkspaceSyncEntry? {
        guard let record = state.records["\(resource):\(path)"], !record.deleted else { return nil }
        return record.entry
    }
    func url(path: String, resource: String = "file") -> URL? {
        guard let record = state.records["\(resource):\(path)"], !record.deleted, let object = record.object else { return nil }
        let url = objectURL(object)
        return manager.fileExists(atPath: url.path) ? url : nil
    }
    func read(path: String, resource: String = "file") throws -> Data {
        guard let url = url(path: path, resource: resource) else { throw LocalWorkspaceError.missing }
        return try Data(contentsOf: url)
    }
    func kind(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) { return "markdown" }
        if ext == "pdf" { return "pdf" }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(ext) { return "image" }
        if ["xls", "xlsx"].contains(ext) { return "spreadsheet" }
        if ["doc", "docx", "ppt", "pptx", "hwp", "hwpx", "odt", "odp", "zip"].contains(ext) { return "document" }
        if ["swift", "js", "ts", "jsx", "tsx", "py", "go", "rs", "java", "c", "cpp", "h", "cs", "html", "css", "json", "yaml", "yml", "toml", "sh"].contains(ext) { return "code" }
        return "file"
    }
    private func putRecord(path: String, resource: String, object: String?, revision: String, size: Int, createOnly: Bool, next: inout State, modifiedAt: Date? = nil) throws {
        try Self.validate(path)
        let key = "\(resource):\(path)"
        if resource != "annotations", next.records.values.contains(where: {
            !$0.deleted && $0.entry.resource != "annotations" &&
            (($0.entry.path == path && $0.entry.resource != resource) ||
             ($0.entry.resource == "file" && path.hasPrefix($0.entry.path + "/")))
        }) { throw LocalWorkspaceError.exists }
        if createOnly && next.records.values.contains(where: { !$0.deleted && $0.entry.path == path && $0.entry.resource != "annotations" }) { throw LocalWorkspaceError.exists }
        let old = next.records[key]
        if let old, !old.deleted, old.entry.revision == revision { return }
        if let old { next.archived.append(old) }
        var entry = WorkspaceSyncEntry(path: path, resource: resource, kind: resource == "folder" ? "folder" : resource == "annotations" ? "annotations" : kind(for: path),
                                       isDirectory: resource == "folder", size: size, modifiedAt: modificationTime(next: &next, requested: modifiedAt), revision: revision)
        if resource != "folder" { entry.versionId = UUID().uuidString }
        let liveOld = old?.deleted == false ? old : nil
        entry.fileId = liveOld?.entry.fileId
        let record = Record(entry: entry, object: object, baseRevision: old?.baseRevision, dirty: true, deleted: false, localId: liveOld?.localId ?? (resource == "annotations" ? next.records["file:\(path)"]?.localId : nil) ?? UUID().uuidString, linked: liveOld?.linked)
        next.records[key] = record
        if resource != "folder" {
            let before = old?.deleted == false ? old?.entry.revision : nil
            // A move tombstone belongs to the document now at another path; its
            // synthetic version is not a causal base for a new independent file.
            let movedAway = old?.deleted == true && old?.entry.versionId?.hasPrefix("move_") == true
            let version = movedAway ? nil : old?.entry.versionId ?? before.map { "legacy:\($0)" }
            let change = WorkspaceSyncChange(path: path, resource: resource, action: "put", baseRevision: before,
                operationId: entry.versionId, deviceId: next.deviceId, modifiedAt: entry.modifiedAt, baseVersion: version)
            next.pendingOperations?.append(PendingOperation(change: change, record: record))
        }
    }
    func write(path: String, data: Data, resource: String = "file", createOnly: Bool = false, modifiedAt: Date? = nil) throws {
        guard ["file", "annotations"].contains(resource) else { throw LocalWorkspaceError.invalidPath }
        try Self.validate(path)
        let object = try newObject(data: data, name: resource == "file" ? path : nil)
        var next = state
        try putRecord(path: path, resource: resource, object: object, revision: Self.digest(data), size: data.count, createOnly: createOnly, next: &next, modifiedAt: modifiedAt)
        try commit(next)
    }
    func importFile(path: String, file: URL, createOnly: Bool = true) throws {
        try Self.validate(path)
        let object = try newObject(file: file, name: path)
        let size = (try manager.attributesOfItem(atPath: objectURL(object).path)[.size] as? NSNumber)?.intValue ?? 0
        var next = state
        try putRecord(path: path, resource: "file", object: object, revision: Self.digestFile(objectURL(object)), size: size, createOnly: createOnly, next: &next)
        try commit(next)
    }
    func writePDF(path: String, pdf: Data, annotations: PDFAnnotationDocument, createOnly: Bool = false) throws {
        try Self.validate(path)
        var document = annotations
        document.documentPath = path
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let annotationData = try encoder.encode(document)
        var next = state
        try putRecord(path: path, resource: "file", object: newObject(data: pdf, name: path), revision: Self.digest(pdf), size: pdf.count, createOnly: createOnly, next: &next)
        try putRecord(path: path, resource: "annotations", object: newObject(data: annotationData), revision: Self.digest(annotationData), size: annotationData.count, createOnly: false, next: &next)
        try commit(next)
    }
    func createFolder(path: String) throws {
        var next = state
        try putRecord(path: path, resource: "folder", object: nil, revision: "directory", size: 0, createOnly: true, next: &next)
        try commit(next)
    }
    func delete(path: String) throws {
        try Self.validate(path)
        var next = state
        for (key, record) in state.records where !record.deleted && (record.entry.path == path || record.entry.path.hasPrefix(path + "/")) {
            if mode(path: record.entry.path) == .local {
                var removed = record; removed.deleted = true; removed.dirty = false; removed.baseRevision = nil
                next.pendingOperations?.removeAll { $0.change.path == record.entry.path }
                next.records[key] = removed
            } else { enqueueDeletion(key: key, record: record, next: &next) }
        }
        try commit(next)
    }
    private func enqueueDeletion(key: String, record: Record, next: inout State) {
        next.archived.append(record)
        var deleted = record; deleted.deleted = true
        deleted.dirty = record.entry.resource != "folder" || record.baseRevision != nil
        if record.entry.resource != "folder" {
            let id = UUID().uuidString
            let time = modificationTime(next: &next)
            let change = WorkspaceSyncChange(path: record.entry.path, resource: record.entry.resource, action: "delete", baseRevision: record.entry.revision,
                operationId: id, deviceId: next.deviceId, modifiedAt: time, baseVersion: record.entry.versionId ?? "legacy:\(record.entry.revision)")
            deleted.entry.versionId = id
            next.pendingOperations?.append(PendingOperation(change: change, record: deleted))
        }
        next.records[key] = deleted
    }
    func transfer(from: String, to: String, move: Bool) throws {
        try Self.validate(from); try Self.validate(to)
        guard to != from, !to.hasPrefix(from + "/") else { throw LocalWorkspaceError.invalidPath }
        let source = state.records.values.filter { !$0.deleted && ($0.entry.path == from || $0.entry.path.hasPrefix(from + "/")) }
        guard !source.isEmpty else { throw LocalWorkspaceError.missing }
        var next = state
        if move && (source.allSatisfy({ $0.baseRevision == nil && $0.linked != true }) || source.contains(where: { $0.entry.path == from && $0.entry.resource != "annotations" && $0.entry.fileId != nil })) {
            for record in source where record.entry.resource != "annotations" {
                let destination = to + record.entry.path.dropFirst(from.count)
                if state.records.values.contains(where: { !$0.deleted && $0.entry.path == destination && $0.entry.resource != "annotations" }) { throw LocalWorkspaceError.exists }
            }
            for record in source {
                let destination = to + record.entry.path.dropFirst(from.count)
                var relocated = record; relocated.entry.path = destination
                next.records.removeValue(forKey: record.entry.key); next.records[relocated.entry.key] = relocated
                let key = policyKey(destination, in: next)
                next.modes = next.modes ?? [:]; next.modes?[key] = mode(path: record.entry.path)
                if keepsLocal(path: record.entry.path) { next.localOnly = next.localOnly ?? []; next.localOnly?.insert(key) }
                for index in (next.pendingOperations ?? []).indices where next.pendingOperations?[index].change.path == record.entry.path {
                    next.pendingOperations?[index].change.path = destination; next.pendingOperations?[index].record.entry.path = destination
                }
                next.conflicts?.removeValue(forKey: record.entry.path)
            }
            if let root = source.first(where: { $0.entry.path == from && $0.entry.resource != "annotations" }), let id = root.entry.fileId {
                next.pendingMoves = next.pendingMoves ?? []
                // Keep a move chain, so lost acknowledgements can be safely retried.
                next.pendingMoves?.append(WorkspaceSyncMove(from: from, to: to, fileId: id, expectedRevision: root.baseRevision ?? root.entry.revision))
            }
            try commit(next); return
        }
        for record in source {
            let destination = to + record.entry.path.dropFirst(from.count)
            let relocated = try relocate(record, to: destination)
            try putRecord(path: destination, resource: record.entry.resource, object: relocated.object, revision: relocated.revision, size: relocated.size, createOnly: record.entry.resource != "annotations", next: &next)
            if move {
                enqueueDeletion(key: record.entry.key, record: record, next: &next)
                next.conflicts?.removeValue(forKey: record.entry.path)
            }
        }
        try commit(next)
    }
    /// Explicitly adopt device-local data into an authenticated account. Never silently merge accounts.
    func importWorkspace(_ source: LocalWorkspace) throws {
        var next = state
        var destinations = next.importedDestinations ?? [:]
        var mapping: [String: String] = [:]
        let records = source.state.records.values.sorted {
            if ($0.entry.resource == "annotations") != ($1.entry.resource == "annotations") { return $0.entry.resource != "annotations" }
            return $0.entry.path.count < $1.entry.path.count
        }
        for record in records where !record.deleted {
            let sourceKey = "\(source.directory.path):\(record.entry.key)"
            let identity = "\(source.directory.path):\(record.entry.key):\(record.entry.revision)"
            if next.importedLocalObjects.contains(identity) {
                mapping[record.entry.path] = destinations[sourceKey] ?? record.entry.path
                continue
            }
            var destination = mapping[record.entry.path] ?? record.entry.path
            if let parent = mapping.keys.filter({ record.entry.path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) {
                destination = mapping[parent]! + record.entry.path.dropFirst(parent.count)
            }
            if record.entry.resource == "annotations" { destination = mapping[record.entry.path] ?? destinations["\(source.directory.path):file:\(record.entry.path)"] ?? destination }
            if next.records.values.contains(where: { !$0.deleted && $0.entry.path == destination && $0.entry.resource != "annotations" }) && record.entry.resource != "annotations" {
                if record.entry.resource != "folder" || next.records["folder:\(destination)"] == nil {
                    destination = conflictPath(destination, suffix: "로컬 가져오기")
                }
            }
            var copied = record
            copied.object = try record.object.map { try newObject(file: source.objectURL($0)) }
            let relocated = try relocate(copied, to: destination)
            try putRecord(path: destination, resource: record.entry.resource, object: relocated.object, revision: relocated.revision, size: relocated.size, createOnly: false, next: &next)
            mapping[record.entry.path] = destination
            destinations[sourceKey] = destination
            next.importedLocalObjects.insert(identity)
        }
        next.importedDestinations = destinations
        try commit(next)
    }

    private func relocate(_ record: Record, to path: String) throws -> (object: String?, revision: String, size: Int) {
        guard record.entry.resource == "annotations", let object = record.object else { return (record.object, record.entry.revision, record.entry.size) }
        guard var doc = try JSONSerialization.jsonObject(with: Data(contentsOf: objectURL(object))) as? [String: Any] else { throw LocalWorkspaceError.invalidManifest }
        doc["documentPath"] = path
        let data = try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys])
        return (try newObject(data: data), Self.digest(data), data.count)
    }
    private func conflictPath(_ path: String, suffix: String = "충돌 사본") -> String {
        let ns = path as NSString
        let ext = ns.pathExtension
        return "\(ns.deletingPathExtension) (\(suffix) \(UUID().uuidString.prefix(8)))\(ext.isEmpty ? "" : "." + ext)"
    }

    nonisolated static func annotationFingerprint(_ data: Data?) throws -> String {
        guard let data else { return "none" }
        guard var doc = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LocalWorkspaceError.invalidManifest }
        doc.removeValue(forKey: "updatedAt"); doc.removeValue(forKey: "documentPath")
        for key in ["objects", "elements", "pages"] where doc[key] == nil || doc[key] is NSNull { doc[key] = [Any]() }
        var pages = doc["pages"] as? [[String: Any]] ?? []
        for index in pages.indices {
            pages[index]["pageId"] = pages[index]["pageId"] ?? "index:\(pages[index]["pageIndex"] ?? 0)"
            for key in ["objects", "elements", "inkStrokes"] where pages[index][key] == nil || pages[index][key] is NSNull { pages[index][key] = [Any]() }
        }
        pages.sort { ($0["pageIndex"] as? Int ?? 0) < ($1["pageIndex"] as? Int ?? 0) }; doc["pages"] = pages
        if pages.isEmpty, (doc["objects"] as? [Any])?.isEmpty == true, (doc["elements"] as? [Any])?.isEmpty == true,
           Set(doc.keys).isSubset(of: ["schemaVersion", "pages", "objects", "elements"]) { return "none" }
        return digest(try JSONSerialization.data(withJSONObject: doc, options: [.sortedKeys, .withoutEscapingSlashes]))
    }

    /// Metadata is committed and published before any payload transfer.
    private func prepareManifest(_ manifest: WorkspaceSyncManifest) throws {
        guard manifest.version == 1, Set(manifest.entries.map(\.key)).count == manifest.entries.count else { throw LocalWorkspaceError.invalidManifest }
        for entry in manifest.entries {
            try Self.validate(entry.path)
            guard ["file", "folder", "annotations"].contains(entry.resource), entry.size >= 0,
                  entry.resource == "folder" ? entry.revision == "directory" : entry.revision.count == 64 && entry.revision.allSatisfy(\.isHexDigit) else { throw LocalWorkspaceError.invalidManifest }
        }
        serverEntries = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.key, $0) })
        var next = state; next.conflicts = [:]
        // A remote rename is the same document. Never download it as a second book.
        for entry in manifest.entries where entry.resource != "annotations" {
            if let id = entry.fileId, (next.pendingMoves ?? []).contains(where: { $0.fileId == id && $0.to != entry.path }) { continue }
            guard let id = entry.fileId, let old = next.records.values.first(where: { !$0.deleted && $0.entry.resource == entry.resource && $0.entry.fileId == id && $0.entry.path != entry.path }),
                  !(next.pendingMoves ?? []).contains(where: { $0.fileId == id }) else { continue }
            if mode(path: old.entry.path) == .local { continue }
            if let occupied = next.records[entry.key], !occupied.deleted, occupied.localId != old.localId {
                next.conflicts?[entry.path] = WorkspaceSyncConflict(path: entry.path, server: entry, localRevision: occupied.entry.revision, reason: "destination-exists"); continue
            }
            for record in next.records.values.filter({ !$0.deleted && ($0.entry.path == old.entry.path || old.entry.resource == "folder" && $0.entry.path.hasPrefix(old.entry.path + "/")) }) {
                var moved = record; let destination = entry.path + record.entry.path.dropFirst(old.entry.path.count); moved.entry.path = destination
                next.records.removeValue(forKey: record.entry.key); next.records[moved.entry.key] = moved
                let key = policyKey(destination, in: next)
                next.modes = next.modes ?? [:]; next.modes?[key] = mode(path: record.entry.path)
                for index in (next.pendingOperations ?? []).indices where next.pendingOperations?[index].change.path == record.entry.path {
                    next.pendingOperations?[index].change.path = destination; next.pendingOperations?[index].record.entry.path = destination
                }
            }
        }
        for entry in manifest.entries where entry.resource != "annotations" {
            if let id = entry.fileId, (next.pendingMoves ?? []).contains(where: { $0.fileId == id && $0.to != entry.path }) { continue }
            if let id = entry.fileId, next.records.values.contains(where: { !$0.deleted && $0.entry.fileId == id && $0.entry.path != entry.path && mode(path: $0.entry.path) == .local }) { continue }
            if next.records[entry.key]?.deleted == true && mode(path: entry.path) == .local { continue }
            if let local = next.records.values.first(where: { !$0.deleted && $0.entry.resource != "annotations" && $0.entry.path == entry.path && $0.entry.resource != entry.resource }) {
                next.conflicts?[entry.path] = WorkspaceSyncConflict(path: entry.path, server: entry, localRevision: local.entry.revision, reason: "structure")
                transferStates[entry.path] = "파일·폴더 이름 확인 필요"; continue
            }
            if next.conflicts?.keys.contains(where: { entry.path.hasPrefix($0 + "/") }) == true { continue }
            if var local = next.records[entry.key], !local.deleted {
                if local.entry.fileId == entry.fileId && local.entry.fileId != nil { continue }
                if (local.baseRevision != nil || local.linked == true), local.entry.fileId == nil { local.entry.fileId = entry.fileId; next.records[entry.key] = local; continue }
                if local.object != nil && local.entry.resource == "file" {
                    if keepsLocal(path: entry.path) { continue }
                    let annotationData = try? read(path: entry.path, resource: "annotations")
                    let fingerprint = entry.kind == "pdf" ? try Self.annotationFingerprint(annotationData) : "none"
                    let same = local.entry.revision == entry.revision && (entry.kind != "pdf" || fingerprint == (entry.annotationFingerprint ?? "none"))
                    if same {
                        local.entry = entry; local.baseRevision = entry.revision; local.dirty = false; local.linked = true
                        next.records[entry.key] = local
                        next.pendingOperations?.removeAll { $0.change.path == entry.path }
                        if mode(path: entry.path) == .local { let key = policyKey(entry.path, in: next); next.modes = next.modes ?? [:]; next.modes?[key] = .sync }
                        if let annotation = serverEntries["annotations:\(entry.path)"], var own = next.records[annotation.key] {
                            own.entry = annotation; own.baseRevision = annotation.revision; own.dirty = false; next.records[annotation.key] = own
                        }
                    } else {
                        next.conflicts?[entry.path] = WorkspaceSyncConflict(path: entry.path, server: entry, localRevision: local.entry.revision, reason: "first-registration", localAnnotationFingerprint: fingerprint)
                        transferStates[entry.path] = "확인 필요"
                    }
                    continue
                }
                if local.dirty { continue }
            }
            if next.records[entry.key]?.object == nil && next.records[entry.key]?.dirty != true {
                next.records[entry.key] = Record(entry: entry, object: nil, baseRevision: nil, dirty: false, deleted: false, localId: next.records[entry.key]?.localId ?? UUID().uuidString)
            }
        }
        // Include annotation metadata too, without downloading every PDF's sidecar.
        for entry in manifest.entries where entry.resource == "annotations" && next.records[entry.key] == nil {
            if let id = entry.fileId, next.records.values.contains(where: { !$0.deleted && $0.entry.fileId == id && $0.entry.path != entry.path && mode(path: $0.entry.path) == .local }) { continue }
            next.records[entry.key] = Record(entry: entry, object: nil, baseRevision: nil, dirty: false, deleted: false, localId: next.records["file:\(entry.path)"]?.localId)
        }
        try commit(next)
    }

    private func ensureSpace(_ entry: WorkspaceSyncEntry) throws {
        let free = try availableCapacity?() ?? Int64(directory.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0)
        guard entry.size <= (Int64.max - 8 * 1024 * 1024) / 2,
              free > Int64(entry.size) * 2 + 8 * 1024 * 1024 else { throw LocalWorkspaceError.insufficientSpace }
    }

    func downloadOnDemand(path: String, using transport: any WorkspaceSyncTransport) async throws {
        guard mode(path: path) != .local else { throw LocalWorkspaceError.missing }
        guard state.conflicts?[path] == nil, state.records.values.contains(where: { $0.entry.path == path && $0.dirty }) == false else { throw LocalWorkspaceError.staleDecision }
        let manifest = try await transport.syncManifest()
        let expected = state.records["file:\(path)"]?.entry.revision
        for entry in manifest.entries where entry.path == path && entry.resource != "folder" {
            if let own = state.records[entry.key], own.dirty || (own.entry.revision == entry.revision && own.object != nil) { continue }
            try ensureSpace(entry)
            transferStates[path] = "전송 중"; onChange?()
            defer { transferStates.removeValue(forKey: path); onChange?() }
            let file = try await transport.downloadSyncBlob(entry); defer { try? manager.removeItem(at: file) }
            guard try Self.digestFile(file) == entry.revision else { throw LocalWorkspaceError.incompleteDownload }
            if state.records[entry.key]?.dirty == true { throw LocalWorkspaceError.staleDecision }
            if let expected, state.records["file:\(path)"]?.entry.revision != expected, entry.resource == "file" { throw LocalWorkspaceError.staleDecision }
            var next = state
            next.records[entry.key] = Record(entry: entry, object: try newObject(file: file, name: entry.resource == "file" ? path : nil), baseRevision: entry.revision, dirty: false, deleted: false, localId: next.records[entry.key]?.localId ?? UUID().uuidString)
            try commit(next)
        }
    }

    func resolveConflict(_ conflict: WorkspaceSyncConflict, useServer: Bool, using transport: any WorkspaceSyncTransport) async throws {
        guard let current = state.records["file:\(conflict.path)"], current.entry.revision == conflict.localRevision, let server = conflict.server else { throw LocalWorkspaceError.staleDecision }
        let localInk = try Self.annotationFingerprint(try? read(path: conflict.path, resource: "annotations"))
        if let expected = conflict.localAnnotationFingerprint, localInk != expected { throw LocalWorkspaceError.staleDecision }
        let manifest = try await transport.syncManifest()
        guard let latest = manifest.entries.first(where: { $0.key == server.key }), latest.revision == server.revision,
              latest.fileId == server.fileId, latest.annotationFingerprint == server.annotationFingerprint else { throw LocalWorkspaceError.staleDecision }
        // Stage every server resource first. Never discard local work on a failed download.
        var downloaded: [(WorkspaceSyncEntry, URL)] = []
        defer { for (_, file) in downloaded { try? manager.removeItem(at: file) } }
        if useServer {
            let resources = manifest.entries.filter { $0.path == conflict.path && $0.resource != "folder" }
            var reservation = latest; reservation = WorkspaceSyncEntry(path: latest.path, resource: latest.resource, kind: latest.kind, isDirectory: false, size: resources.reduce(0) { $0 + $1.size }, modifiedAt: latest.modifiedAt, revision: latest.revision)
            try ensureSpace(reservation)
            for entry in manifest.entries where entry.path == conflict.path && entry.resource != "folder" {
                try ensureSpace(entry)
                let file = try await transport.downloadSyncBlob(entry)
                downloaded.append((entry, file))
                guard try Self.digestFile(file) == entry.revision else { throw LocalWorkspaceError.incompleteDownload }
            }
            let confirmed = try await transport.syncManifest()
            guard confirmed.entries.filter({ $0.path == conflict.path }).sorted(by: { $0.key < $1.key }) == manifest.entries.filter({ $0.path == conflict.path }).sorted(by: { $0.key < $1.key }) else { throw LocalWorkspaceError.staleDecision }
        }
        guard state.records["file:\(conflict.path)"]?.entry.revision == conflict.localRevision,
              try Self.annotationFingerprint(try? read(path: conflict.path, resource: "annotations")) == localInk else { throw LocalWorkspaceError.staleDecision }
        var next = state; next.pendingOperations?.removeAll { $0.change.path == conflict.path }
        if useServer {
            for key in next.records.keys where next.records[key]?.entry.path == conflict.path && next.records[key]?.entry.resource != "folder" { next.records.removeValue(forKey: key) }
            for (entry, file) in downloaded { next.records[entry.key] = Record(entry: entry, object: try newObject(file: file, name: entry.resource == "file" ? entry.path : nil), baseRevision: entry.revision, dirty: false, deleted: false, localId: current.localId, linked: true) }
        } else {
            if latest.kind == "pdf", next.records["annotations:\(conflict.path)"]?.object == nil {
                let data = Data("{\"schemaVersion\":2,\"pages\":[],\"objects\":[]}".utf8)
                try putRecord(path: conflict.path, resource: "annotations", object: newObject(data: data), revision: Self.digest(data), size: data.count, createOnly: false, next: &next)
                next.pendingOperations?.removeAll { $0.change.path == conflict.path }
            }
            for key in next.records.keys where next.records[key]?.entry.path == conflict.path && next.records[key]?.entry.resource != "folder" {
                guard var local = next.records[key], local.object != nil else { continue }
                let remote = manifest.entries.first { $0.key == key }
                let id = UUID().uuidString; let time = modificationTime(next: &next)
                local.entry.fileId = latest.fileId; local.entry.versionId = id; local.entry.modifiedAt = time; local.baseRevision = remote?.revision; local.dirty = true
                next.records[key] = local
                next.pendingOperations?.append(PendingOperation(change: WorkspaceSyncChange(path: conflict.path, resource: local.entry.resource, action: "put", baseRevision: remote?.revision, operationId: id, deviceId: next.deviceId, modifiedAt: time, baseVersion: remote?.versionId ?? remote.map { "legacy:\($0.revision)" }, fileId: latest.fileId, expectedRevision: remote?.revision ?? "missing"), record: local))
            }
        }
        let modeKey = policyKey(conflict.path, in: next)
        next.conflicts?.removeValue(forKey: conflict.path); next.modes = next.modes ?? [:]; next.modes?[modeKey] = .sync
        transferStates.removeValue(forKey: conflict.path); try commit(next)
    }

    func synchronize(using transport: any WorkspaceSyncTransport) async throws -> LocalSyncReport {
        guard !isSynchronizing else { throw LocalWorkspaceError.busy }
        isSynchronizing = true
        defer { isSynchronizing = false }
        var report = LocalSyncReport()
        let capabilities = try await transport.syncManifest()
        try repairMovedPathCreation(capabilities)
        for move in state.pendingMoves ?? [] where mode(path: state.records.values.first(where: { !$0.deleted && $0.entry.fileId == move.fileId && $0.entry.resource != "annotations" })?.entry.path ?? move.to) != .local {
            let result = try await transport.moveSyncFile(move)
            guard result.status == "applied" else {
                var next = state; next.conflicts = next.conflicts ?? [:]
                next.conflicts?[move.to] = WorkspaceSyncConflict(path: move.to, server: result.entry, localRevision: state.records["file:\(move.to)"]?.entry.revision ?? "directory", reason: result.reason ?? "move")
                transferStates[move.to] = "이동 확인 필요"; try commit(next); report.conflicts.append(move.to); return report
            }
            var next = state; next.pendingMoves?.removeAll { $0 == move }; try commit(next)
        }
        let catalog = (state.pendingMoves ?? []).isEmpty && capabilities.selectiveSyncVersion == 1 ? try await transport.syncManifest() : capabilities
        try prepareManifest(catalog)
        if !(state.pendingOperations ?? []).isEmpty, capabilities.conflictPolicies?.contains("merge-modified-v2") != true { throw LocalWorkspaceError.serverUpgradeRequired }
        var bundledPaths = Set<String>()
        if capabilities.documentBundleVersion == 1 {
            let candidates = Set((state.pendingOperations ?? []).filter { $0.change.resource == "file" && $0.change.action == "put" && $0.change.path.lowercased().hasSuffix(".pdf") && ($0.change.baseRevision == nil || $0.change.expectedRevision != nil) }.map { $0.change.path })
            for path in candidates.sorted() {
                guard mode(path: path) != .local, state.conflicts?[path] == nil, editingPath != path,
                      let original = state.records["file:\(path)"], let object = original.object else { continue }
                bundledPaths.insert(path)
                if state.records["annotations:\(path)"]?.object == nil {
                    try write(path: path, data: Data("{\"schemaVersion\":2,\"pages\":[],\"objects\":[]}".utf8), resource: "annotations")
                }
                let captured = (state.pendingOperations ?? []).filter { $0.change.path == path }
                guard let firstFile = captured.first(where: { $0.change.resource == "file" }), let lastFile = captured.last(where: { $0.change.resource == "file" }),
                      let firstInk = captured.first(where: { $0.change.resource == "annotations" }), let lastInk = captured.last(where: { $0.change.resource == "annotations" }), let inkObject = lastInk.record.object else { continue }
                var fileChange = lastFile.change, inkChange = lastInk.change
                let identity = original.entry.fileId ?? original.localId
                // Collapse only initial registration/explicit replacement, not ordinary edits.
                fileChange = WorkspaceSyncChange(path: path, resource: "file", action: "put", baseRevision: firstFile.change.baseRevision, operationId: lastFile.change.operationId, deviceId: state.deviceId, modifiedAt: lastFile.change.modifiedAt, baseVersion: firstFile.change.baseVersion, fileId: identity, firstRegistration: firstFile.change.baseRevision == nil, expectedRevision: firstFile.change.expectedRevision ?? firstFile.change.baseRevision ?? "missing")
                inkChange = WorkspaceSyncChange(path: path, resource: "annotations", action: "put", baseRevision: firstInk.change.baseRevision, operationId: lastInk.change.operationId, deviceId: state.deviceId, modifiedAt: lastInk.change.modifiedAt, baseVersion: firstInk.change.baseVersion, fileId: identity, expectedRevision: firstInk.change.expectedRevision ?? firstInk.change.baseRevision ?? "missing")
                transferStates[path] = "전송 중"; onChange?()
                do {
                    let result = try await transport.applyDocumentBundle(fileChange: fileChange, file: objectURL(object), annotationChange: inkChange, annotations: objectURL(inkObject))
                    var next = state
                    if result.status == "conflict" {
                        next.conflicts = next.conflicts ?? [:]
                        next.conflicts?[path] = WorkspaceSyncConflict(path: path, server: result.entry, localRevision: original.entry.revision, reason: result.reason ?? "first-registration", localAnnotationFingerprint: try Self.annotationFingerprint(try? read(path: path, resource: "annotations")))
                        transferStates[path] = "확인 필요"; report.conflicts.append(path)
                    } else {
                        guard result.status == "applied" else { throw LocalWorkspaceError.invalidManifest }
                        let ids = Set(captured.compactMap { $0.change.operationId })
                        next.pendingOperations?.removeAll { $0.change.operationId.map(ids.contains) == true }
                        for key in ["file:\(path)", "annotations:\(path)"] {
                            next.records[key]?.dirty = next.pendingOperations?.contains(where: { $0.record.entry.key == key }) == true
                            next.records[key]?.entry.fileId = result.entry?.fileId; next.records[key]?.linked = true
                        }
                        report.uploaded += 2; transferStates.removeValue(forKey: path)
                    }
                    try commit(next)
                } catch {
                    if error is CancellationError { throw error }
                    transferStates[path] = error.localizedDescription; onChange?()
                }
            }
        }
        let folders = state.records.values.filter { $0.dirty && $0.entry.resource == "folder" }
        let creates = folders.filter { !$0.deleted }.sorted { $0.entry.path.count < $1.entry.path.count }
        let deletes = folders.filter(\.deleted).sorted { $0.entry.path.count > $1.entry.path.count }
        let operations = state.pendingOperations ?? []
        // Folder parents first, then EVERY original save in its durable local order,
        // then empty folder removals. Never reorder dependent create/delete/recreate.
        let pending: [(Record, WorkspaceSyncChange)] = creates.map { ($0, WorkspaceSyncChange(path: $0.entry.path, resource: "folder", action: "put", baseRevision: $0.baseRevision)) }
            + operations.map { ($0.record, $0.change) }
            + deletes.map { ($0, WorkspaceSyncChange(path: $0.entry.path, resource: "folder", action: "delete", baseRevision: $0.baseRevision)) }
        var blockedKeys = Set<String>()
        for (record, change) in pending {
            try Task.checkCancellation()
            if bundledPaths.contains(record.entry.path) { continue }
            guard mode(path: record.entry.path) != .local, state.conflicts?.keys.contains(where: { record.entry.path == $0 || record.entry.path.hasPrefix($0 + "/") }) != true else { continue }
            if record.entry.resource == "file", record.entry.path == editingPath { continue }
            if blockedKeys.contains(record.entry.key) { continue }
            let file = record.deleted ? nil : record.object.map(objectURL)
            var outgoing = change
            if capabilities.selectiveSyncVersion == 1 {
                outgoing.fileId = change.resource == "annotations"
                    ? state.records["file:\(record.entry.path)"]?.entry.fileId ?? state.records["file:\(record.entry.path)"]?.localId
                    : state.records[record.entry.key]?.entry.fileId ?? record.localId
                outgoing.firstRegistration = change.resource == "file" && change.action == "put" && change.baseRevision == nil
            }
            transferStates[record.entry.path] = "전송 중"; onChange?()
            let result: WorkspaceSyncResult
            do { result = try await transport.applySyncChange(outgoing, file: file) }
            catch {
                if error is CancellationError { throw error }
                transferStates[record.entry.path] = error.localizedDescription; blockedKeys.insert(record.entry.key); onChange?(); continue
            }
            if result.status == "conflict" {
                report.conflicts.append(record.entry.path)
                blockedKeys.insert(record.entry.key)
                var next = state; next.conflicts = next.conflicts ?? [:]
                let local = state.records["file:\(record.entry.path)"] ?? record
                next.conflicts?[record.entry.path] = WorkspaceSyncConflict(path: record.entry.path, server: result.entry, localRevision: local.entry.revision, reason: result.reason ?? "conflict", localAnnotationFingerprint: try Self.annotationFingerprint(try? read(path: record.entry.path, resource: "annotations")))
                transferStates[record.entry.path] = "확인 필요"; try commit(next)
                continue
            }
            guard result.status == "applied" else { throw LocalWorkspaceError.invalidManifest }
            var next = state
            if let id = change.operationId { next.pendingOperations?.removeAll { $0.change.operationId == id } }
            if var latest = next.records[record.entry.key] {
                latest.dirty = next.pendingOperations?.contains { $0.record.entry.key == record.entry.key } == true
                    || (change.operationId == nil && (latest.entry.revision != record.entry.revision || latest.deleted != record.deleted))
                // The server may return merged bytes, not the uploaded object's bytes. Keep the
                // local content revision until the manifest downloads and verifies the merged object.
                // A newer in-flight edit still descends from the old ancestor if the response merged.
                if !latest.dirty { latest.baseRevision = result.entry?.revision }
                if let id = result.entry?.fileId { latest.entry.fileId = id }
                latest.linked = true
                if !latest.dirty, let entry = result.entry, entry.revision == record.entry.revision { latest.entry = entry }
                if !latest.dirty, result.entry == nil { next.archived.append(latest); latest.deleted = true }
                next.records[record.entry.key] = latest
            }
            if let observed = result.entry?.logicalModifiedAt, let date = Self.parseTime(observed) { next.lastModifiedTime = max(next.lastModifiedTime ?? 0, date.timeIntervalSince1970 * 1000) }
            try commit(next)
            report.uploaded += 1
            transferStates.removeValue(forKey: record.entry.path); onChange?()
        }
        let manifest = try await transport.syncManifest()
        guard manifest.version == 1 else { throw LocalWorkspaceError.invalidManifest }
        let keys = Set(manifest.entries.map(\.key))
        guard keys.count == manifest.entries.count else { throw LocalWorkspaceError.invalidManifest }
        for entry in manifest.entries {
            try Self.validate(entry.path)
            guard ["file", "folder", "annotations"].contains(entry.resource), entry.isDirectory == (entry.resource == "folder"),
                  entry.size >= 0,
                  entry.resource == "folder" ? entry.revision == "directory" : (entry.revision.count == 64 && entry.revision.allSatisfy(\.isHexDigit)) else { throw LocalWorkspaceError.invalidManifest }
            if entry.resource == "file", entry.path == editingPath { continue }
            if let id = entry.fileId, (state.pendingMoves ?? []).contains(where: { $0.fileId == id && $0.to != entry.path }) { continue }
            if let id = entry.fileId, state.records.values.contains(where: { !$0.deleted && $0.entry.fileId == id && $0.entry.path != entry.path && mode(path: $0.entry.path) == .local }) { continue }
            if mode(path: entry.path) == .local || mode(path: entry.path) == .server || state.conflicts?.keys.contains(where: { entry.path == $0 || entry.path.hasPrefix($0 + "/") }) == true { continue }
            if state.records[entry.key]?.dirty == true { continue }
            if let existing = state.records[entry.key], !existing.deleted, existing.entry.revision == entry.revision,
               entry.resource == "folder" || existing.object.map({ manager.fileExists(atPath: objectURL($0).path) }) == true {
                var next = state; next.records[entry.key]?.entry = entry
                if let observed = entry.logicalModifiedAt, let date = Self.parseTime(observed) { next.lastModifiedTime = max(next.lastModifiedTime ?? 0, date.timeIntervalSince1970 * 1000) }
                try commit(next); continue
            }
            let object: String?
            if entry.resource == "folder" { object = nil }
            else {
                let downloaded: URL
                do {
                    try ensureSpace(entry); transferStates[entry.path] = "전송 중"; onChange?()
                    downloaded = try await transport.downloadSyncBlob(entry)
                } catch {
                    if error is CancellationError { throw error }
                    transferStates[entry.path] = error.localizedDescription; onChange?(); continue
                }
                defer { try? manager.removeItem(at: downloaded) }
                let revision = try await Task.detached { try Self.digestFile(downloaded) }.value
                guard revision == entry.revision else { throw LocalWorkspaceError.incompleteDownload }
                // Local editing during the download always wins until it is explicitly synced.
                if mode(path: entry.path) != .sync || state.records[entry.key]?.dirty == true || (entry.resource == "file" && entry.path == editingPath) { continue }
                object = try newObject(file: downloaded, name: entry.path)
            }
            var next = state
            for (key, old) in state.records where !old.deleted && !old.dirty && old.entry.path == entry.path && old.entry.resource != "annotations" && entry.resource != "annotations" && old.entry.resource != entry.resource {
                next.archived.append(old)
                next.records.removeValue(forKey: key)
            }
            if let old = next.records[entry.key] { next.archived.append(old) }
            next.records[entry.key] = Record(entry: entry, object: object, baseRevision: entry.revision, dirty: false, deleted: false, localId: next.records[entry.key]?.localId ?? next.records["file:\(entry.path)"]?.localId ?? UUID().uuidString, linked: true)
            if let observed = entry.logicalModifiedAt, let date = Self.parseTime(observed) { next.lastModifiedTime = max(next.lastModifiedTime ?? 0, date.timeIntervalSince1970 * 1000) }
            try commit(next)
            report.downloaded += 1
            transferStates.removeValue(forKey: entry.path); onChange?()
        }
        var next = state
        for (key, record) in state.records where !record.dirty && !record.deleted && record.baseRevision != nil && !keys.contains(key) && mode(path: record.entry.path) != .local {
            if record.entry.resource == "file", record.entry.path == editingPath { continue }
            next.archived.append(record)
            next.records[key]?.deleted = true
            next.records[key]?.baseRevision = nil
            next.records[key]?.entry.versionId = nil
        }
        for tombstone in manifest.deletedEntries ?? [] {
            try Self.validate(tombstone.path)
            let key = "\(tombstone.resource):\(tombstone.path)"
            guard ["file", "annotations"].contains(tombstone.resource), !keys.contains(key), next.records[key]?.dirty != true else { continue }
            if mode(path: tombstone.path) == .local { continue }
            if tombstone.resource == "file", tombstone.path == editingPath { continue }
            var entry = next.records[key]?.entry ?? WorkspaceSyncEntry(path: tombstone.path, resource: tombstone.resource, kind: tombstone.resource == "annotations" ? "annotations" : kind(for: tombstone.path), isDirectory: false, size: 0, modifiedAt: tombstone.modifiedAt, revision: Self.digest(Data()))
            entry.versionId = tombstone.versionId; entry.logicalModifiedAt = tombstone.modifiedAt
            next.records[key] = Record(entry: entry, object: next.records[key]?.object, baseRevision: nil, dirty: false, deleted: true)
            if let date = Self.parseTime(tombstone.modifiedAt) { next.lastModifiedTime = max(next.lastModifiedTime ?? 0, date.timeIntervalSince1970 * 1000) }
        }
        for key in next.records.keys {
            guard var record = next.records[key], mode(path: record.entry.path) == .server, !record.dirty,
                  record.entry.path != editingPath, record.object != openObject,
                  !retainedOpenObjects.contains(record.object ?? ""),
                  (next.pendingOperations ?? []).allSatisfy({ $0.change.path != record.entry.path }) else { continue }
            record.object = nil; next.records[key] = record
        }
        try commit(next)
        if capabilities.selectiveSyncVersion == 1 {
            let policies = state.records.values.filter { !$0.deleted && $0.entry.resource != "annotations" }.compactMap { record -> WorkspaceDevicePolicy? in
                guard let fileId = record.entry.fileId else { return nil }
                return WorkspaceDevicePolicy(fileId: fileId, mode: mode(path: record.entry.path), locallyAvailable: record.object != nil, pending: record.dirty)
            }
            for offset in stride(from: 0, to: policies.count, by: 1000) {
                try await transport.reportStoragePolicies(deviceId: state.deviceId!, policies: Array(policies[offset..<min(offset + 1000, policies.count)]))
            }
        }
        report.conflicts = Array(Set(report.conflicts + syncConflicts.map(\.path))).sorted()
        report.paused = transferStates.keys.filter { transferStates[$0] != "전송 중" && !report.conflicts.contains($0) }.sorted()
        return report
    }

    /// Repair only unsent creations that inherited the old client's synthetic
    /// move tombstone. Never rebase linked edits or overwrite an occupied path.
    private func repairMovedPathCreation(_ manifest: WorkspaceSyncManifest) throws {
        let occupied = Set(manifest.entries.map(\.key))
        var next = state
        var replacements: [String: String] = [:]
        for index in (next.pendingOperations ?? []).indices {
            guard var operation = next.pendingOperations?[index], operation.change.action == "put",
                  operation.change.baseRevision == nil, operation.change.baseVersion?.hasPrefix("move_") == true,
                  !occupied.contains(operation.record.entry.key),
                  let current = next.records[operation.record.entry.key], !current.deleted,
                  current.entry.fileId == nil, current.linked != true, current.baseRevision == nil else { continue }
            let id = UUID().uuidString
            if let old = operation.change.operationId { replacements[old] = id }
            operation.change.baseVersion = nil; operation.change.operationId = id
            operation.record.entry.versionId = id
            if next.records[operation.record.entry.key]?.entry.versionId == next.pendingOperations?[index].change.operationId {
                next.records[operation.record.entry.key]?.entry.versionId = id
            }
            next.pendingOperations?[index] = operation
            next.conflicts?.removeValue(forKey: operation.change.path)
            transferStates.removeValue(forKey: operation.change.path)
        }
        for index in (next.pendingOperations ?? []).indices {
            if let base = next.pendingOperations?[index].change.baseVersion, let replacement = replacements[base] {
                next.pendingOperations?[index].change.baseVersion = replacement
            }
        }
        try commit(next)
    }
    private static func parseTime(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
