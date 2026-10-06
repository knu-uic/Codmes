import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct WorkspaceFileOperationFailure: Equatable, Sendable {
    struct NameConflict: Equatable, Sendable {
        let sourcePath: String?
        let suggestedName: String
    }
    let title: String
    let message: String
    var nameConflict: NameConflict? = nil
}

struct WorkspaceFileSurfaceState {
    var file: FileResponse?
    var rawFile: RawFilePreview?
    var loadingFile: WorkspaceItem?
    var loadError: String?
    var focus: PDFDocumentFocus?
    var editorText = ""
    var isEditing = false
    var history = TextEditHistory()
    var reloadItem: WorkspaceItem?
    var wasLocal = false
}

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var serverURLText = UserDefaults.standard.string(forKey: "workspace.serverURL") ?? "http://127.0.0.1:8787"
    @Published var serverAuthToken = ""
    @Published var serverAccountToken = ""
    @Published var serverProfiles: [ServerProfile] = []
    @Published var serverUsesProfiles = false
    @Published var serverAccountMessage = ""
    @Published var googleAccountIdentity: GoogleAccountIdentity?
    @Published var isCodmesAccountBusy = false
    private var accountSetupGoogleToken: (token: String, server: URL, created: Date)?

    var needsCodmesCredentials: Bool {
        googleLoginStage == "account_setup_required" || (!serverAccountToken.isEmpty && googleAccountIdentity?.credentialsConfigured == false)
    }
    @Published var googleAuthConfig: GoogleAuthConfig?
    @Published var googleLoginStage = "idle"
    @Published var googleLoginMessage = ""
    @Published var isGoogleLoginBusy = false
    @Published var activeServerProfileName = ""
    @Published var activeServerProfileId = ""
    @Published var workspace: WorkspaceInfo?
    @Published var notes: [WorkspaceItem] = []
    @Published var storageModesRevision = 0
    @Published var storageConflicts: [WorkspaceSyncConflict] = []
    @Published var storageTransferStates: [String: String] = [:]
    @Published var code: [WorkspaceItem] = []
    @Published var notesPath = ""
    @Published var codePath = ""
    @Published var selectedFile: FileResponse? { didSet { if !restoringFileSurface, selectedFile?.path != oldValue?.path { editorHistory.clear() } } }
    @Published var selectedRawFile: RawFilePreview? { didSet { localWorkspace?.setOpenFile(selectedRawFile?.url) } }
    @Published var loadingRawFile: WorkspaceItem?
    @Published var rawFileLoadError: String?
    @Published var selectedPDFFocus: PDFDocumentFocus?
    @Published var editorText = "" {
        didSet {
            guard !restoringFileSurface, editorText != oldValue else { return }
            if isEditingFile {
                if !applyingEditorHistory { editorHistory.record(oldValue) }
                editorModifiedAt = Date(); scheduleEditorAutosave()
            } else { editorHistory.clear() }
        }
    }
    @Published private(set) var editorHistory = TextEditHistory()
    private var applyingEditorHistory = false
    func undoEditorChange() {
        guard isEditingFile, let previous = editorHistory.backward(editorText) else { return }
        applyingEditorHistory = true; editorText = previous; applyingEditorHistory = false
    }
    func redoEditorChange() {
        guard isEditingFile, let next = editorHistory.forward(editorText) else { return }
        applyingEditorHistory = true; editorText = next; applyingEditorHistory = false
    }
    @Published var editorAutosaveError = ""
    private var editorAutosaveTask: Task<Void, Never>?
    private var editorModifiedAt: Date?
    @Published var isEditingFile = false {
        didSet { localWorkspace?.setEditingPath(isEditingFile ? selectedFile?.path : nil); if !isEditingFile && !restoringFileSurface { editorHistory.clear() } }
    }
    @Published private(set) var activeFileSurface: String?
    @Published private(set) var retainedFileSurfaces: Set<String> = []
    @Published private(set) var fileSurfaceRestoreID = UUID()
    @Published private var savedFileSurfaces: [String: WorkspaceFileSurfaceState] = [:]
    private var restoringFileSurface = false
    private var pendingFileSurfaceRestore: WorkspaceItem?
    private var pdfReadingStates: [String: PDFReadingState] = [:]
    @Published var searchResponse: SearchResponse?
    @Published var globalSearchResponse: GlobalSearchResponse?
    @Published var chatLines: [ChatLine] = [
        ChatLine(role: "system", text: "Codmes에 오신 것을 환영합니다. 서버 연결은 Settings → Connection에서 설정할 수 있습니다. AI 대화는 서버 연결 후 사용할 수 있습니다.")
    ]
    @Published var liveSessionId: String?
    @Published var hermesModels: [HermesModelOption] = []
    @Published var hermesSessions: [HermesSessionSummary] = []
    @Published var chatHistoryStorage = ChatHistoryStorage(bytes: 0, sessionCount: 0, assetCount: 0)
    @Published var activeHermesSessionTitle = "No session"
    @Published var selectedHermesModelId = ""
    @Published var chatAccessMode: ChatAccessMode = .confirm
    @Published var chatReasoningMode: ChatReasoningMode = .balanced
    @Published var chatContextScope: ChatContextScope = .currentFile
    @Published var activeChatSurface = "chat"
    @Published var activeChatRoute: String?
    @Published var statusMessage = "Not connected"
    @Published var activePDFStatusText = ""
    @Published var activePDFStatusPath = ""
    @Published var isWorkspaceConnected = false
    @Published var connectionDetail = "Enter the Workspace Server URL and connect."
    @Published var connectionStep = "Idle"
    @Published var isLoading = false
    @Published var sessionManagerSearch = ""
    @Published var selectedHermesProjectId = "__all__"
    @Published var conversationFolders: [ConversationFolder] = []
    @Published var uploadItems: [UploadItem] = []
    @Published var documentJobs: [DocumentJob] = []
    @Published var agentTasks: [AgentTaskSummary] = []
    @Published var codeTasks: [AgentTaskSummary] = []
    @Published var selectedCodeTask: CodeTaskRecord?
    @Published var selectedCodeTaskDiff = ""
    @Published var codeTaskInstruction = ""
    @Published var isLoadingCodeTask = false
    @Published var approvals: [WorkspaceApproval] = []
    @Published var isLoadingApprovals = false
    @Published var selectedApprovalDiffText = ""
    @Published var runtimeProviders: [RuntimeProviderOption] = []
    @Published var runtimeProviderModels: [String: [String]] = [:]
    @Published var runtimeProviderCredentials: [String: [RuntimeCredentialEntry]] = [:]
    @Published var runtimeOAuthSessions: [String: RuntimeOAuthLoginSession] = [:]
    @Published var runtimeModelSetupMessage = ""
    @Published var runtimePlugins: [RuntimePlugin] = []
    @Published var pluginSetupMessage = ""
    @Published private(set) var pluginMCPToolConsents: [String: PluginMCPToolConsent] = [:]
    @Published private(set) var pluginMCPToolOperations: Set<String> = []
    @Published var marketplacePlugins: [MarketplacePlugin] = []
    @Published var marketplaceMessage = ""
    @Published var marketplaceOperations: Set<String> = []
    @Published var isMarketplaceLoading = false
    @Published private(set) var pluginAuthStatuses: [String: PluginAuthStatus] = [:]
    @Published private(set) var pluginAuthOperations: [String: String] = [:]
    @Published private(set) var pluginAuthErrors: [String: String] = [:]
    @Published private(set) var pluginAuthRevision = 0
    @Published var mcpServers: [MCPServerConfig] = []
    @Published var mcpSetupMessage = ""
    @Published var searchConfig: SearchConfigResponse?
    @Published var searchSetupMessage = ""
    @Published var hiddenModelProviderIds: Set<String> = []
    @Published var hiddenModelIds: Set<String> = []
    @Published var localFileCacheLimitGB = WorkspaceStore.initialFileCacheLimitGB()
    @Published var localFileCacheUsageBytes: Int64 = 0
    @Published var localSyncMessage = "로컬 저장소 · 서버 연결 시 동기화"
    @Published var pendingLocalChanges = 0
    @Published var isLocalSyncBusy = false
    @Published var deviceLocalFileCount = 0
    @Published var localStorageError = ""
    @Published private(set) var localSyncRevision = 0
    private var localWorkspace: LocalWorkspace?
    private var localSyncTask: Task<Void, Never>?
    private var localSyncInProgress = false
    private var localStorageModeOverrides: [String: WorkspaceStorageMode] = [:]
    private var localBindingServer: String?
    private struct LocalBinding: Codable { let server: String; let profileId: String; let profileName: String }

    private let liveClient = LiveChatClient()
    private var activeActivityLineId: UUID?
    private var isChatTurnOpen = false
    private var activeFileLoadID: UUID?
    private var activeFileLoadPath: String?
    private var activeFileLoadItem: WorkspaceItem?
    private var rawFileCache: [String: (signature: String, preview: RawFilePreview)] = [:]
    private let fileDiskCache = WorkspaceFileDiskCache()
    private let chunkedUploadThresholdBytes: Int64 = 8 * 1024 * 1024
    private let uploadChunkSize = 1024 * 1024
    private var pluginAuthTasks: [String: Task<Void, Never>] = [:]
    private var pluginAuthMonitorTasks: [String: Task<Void, Never>] = [:]
    private var pluginAuthRefreshesInFlight: Set<String> = []
    private var lastPluginAuthRefreshAt: [String: Date] = [:]
    private let googleSignInController = GoogleSignInController()
    private let googleApprovalPolling = GoogleApprovalPolling()
    private var googleApprovalChecksInFlight: Set<String> = []
    private var authenticatedServerURL: URL?
    private var googleAuthConfigServerURL: URL?
    private var profileLoadsInFlight: Set<String> = []

    init(localWorkspace workspace: LocalWorkspace? = nil, restoreSavedConnection: Bool = true) {
        // Isolated file-operation tests must not read the user's keychain or
        // bind their temporary workspace to an authenticated server profile.
        if restoreSavedConnection {
            serverAuthToken = WorkspaceStore.initialServerAuthToken()
            serverAccountToken = KeychainStore.readServerAccountToken() ?? ""
        }
        authenticatedServerURL = URL(string: normalizedServerURL(
            UserDefaults.standard.string(forKey: "workspace.serverURL") ?? "http://127.0.0.1:8787"
        ))
        if restoreSavedConnection, !serverAccountToken.isEmpty,
           let data = UserDefaults.standard.data(forKey: "workspace.localBinding"),
           let binding = try? JSONDecoder().decode(LocalBinding.self, from: data),
           binding.server == normalizedServerURL(serverURLText) {
            activeServerProfileId = binding.profileId
            activeServerProfileName = binding.profileName
            localBindingServer = binding.server
        }
        if let workspace { localWorkspace = workspace; reloadLocalWorkspace() }
        else { openLocalWorkspace() }
        loadProfilePreferences()
    }

    private var localScope: String {
        guard let server = localBindingServer, !activeServerProfileId.isEmpty else { return "device-local" }
        return "\(server)|\(activeServerProfileId)"
    }

    private func openLocalWorkspace() {
        localSyncTask?.cancel()
        do {
            localWorkspace = try LocalWorkspace(scope: localScope)
            localStorageError = ""
            reloadLocalWorkspace()
            deviceLocalFileCount = (try? LocalWorkspace(scope: "device-local").fileCount) ?? 0
        } catch {
            localWorkspace = nil
            localStorageError = "로컬 저장소를 열 수 없습니다. 기존 자료는 변경하지 않았습니다: \(error.localizedDescription)"
        }
    }

    private func reloadLocalWorkspace() {
        guard let localWorkspace else { return }
        localWorkspace.onChange = { [weak self] in self?.reloadLocalWorkspace() }
        let items = localWorkspace.items
        let nextNotes = items.filter { $0.path.hasPrefix("Notes/") }
        let nextCode = items.filter { $0.path.hasPrefix("Code/") }
        if notes != nextNotes { notes = nextNotes }
        if code != nextCode { code = nextCode }
        if pendingLocalChanges != localWorkspace.pendingSyncCount { pendingLocalChanges = localWorkspace.pendingSyncCount }
        if storageConflicts != localWorkspace.syncConflicts { storageConflicts = localWorkspace.syncConflicts }
        if storageTransferStates != localWorkspace.transferStates { storageTransferStates = localWorkspace.transferStates }
        if localSyncInProgress {
            let transferring = pendingLocalChanges > 0 || storageTransferStates.values.contains("전송 중")
            if isLocalSyncBusy != transferring { isLocalSyncBusy = transferring }
        }
        if localStorageModeOverrides != localWorkspace.storageModeOverrides {
            localStorageModeOverrides = localWorkspace.storageModeOverrides
            storageModesRevision += 1
        }
    }

    func storageMode(path: String) -> WorkspaceStorageMode { localWorkspace?.mode(path: path) ?? .sync }
    func pluginStorageMode(_ pluginId: String) -> WorkspaceStorageMode {
        if pluginId == "com.codmes.notes" { return storageMode(path: "Notes") }
        if pluginId == "com.codmes.code" { return storageMode(path: "Code") }
        return WorkspaceStorageMode(rawValue: UserDefaults.standard.string(forKey: "workspace.pluginStorage.\(profileStorageScope).\(pluginId)") ?? "sync") ?? .sync
    }
    func setPluginStorageMode(_ pluginId: String, mode: WorkspaceStorageMode) {
        if pluginId == "com.codmes.notes" { setStorageMode(path: "Notes", mode: mode); return }
        if pluginId == "com.codmes.code" { setStorageMode(path: "Code", mode: mode); return }
        UserDefaults.standard.set(mode.rawValue, forKey: "workspace.pluginStorage.\(profileStorageScope).\(pluginId)")
        if mode == .server, let directory = try? pluginSnapshotURL(pluginId, routeId: nil).deletingLastPathComponent(),
           let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            // Only this plugin's derived read-only snapshots, never its source or drafts.
            for file in files where file.pathExtension == "json" {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
        storageModesRevision += 1
    }
    private func pluginSnapshotURL(_ pluginId: String, routeId: String?) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Codmes/PluginSnapshots/\(LocalWorkspace.digest(Data(profileStorageScope.utf8)))/\(LocalWorkspace.digest(Data(pluginId.utf8)))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(LocalWorkspace.digest(Data((routeId ?? "").utf8)) + ".json")
    }
    func pluginDocument(pluginId: String, routeId: String?) async throws -> PluginViewDocument {
        let file = try pluginSnapshotURL(pluginId, routeId: routeId)
        let mode = pluginStorageMode(pluginId)
        if mode == .local || !isWorkspaceConnected {
            guard mode != .server, let data = try? Data(contentsOf: file) else { throw LocalWorkspaceError.missing }
            return try JSONDecoder().decode(PluginViewDocument.self, from: data)
        }
        guard let api else { throw LocalWorkspaceError.missing }
        do {
            let document = try await api.pluginViewDocument(pluginId: pluginId, routeId: routeId)
            if mode == .sync {
                // A cache failure must not replace freshly fetched content with stale data.
                let data = try JSONEncoder().encode(document)
                if data.count <= 8 * 1024 * 1024 { try? data.write(to: file, options: .atomic) }
                if let files = try? FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isSymbolicLinkKey]) {
                    let ordered = files.filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true }.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                    var size = 0
                    for (index, cached) in ordered.enumerated() {
                        size += (try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        if index >= 100 || size > 32 * 1024 * 1024 { try? FileManager.default.removeItem(at: cached) }
                    }
                }
            }
            return document
        } catch {
            guard mode != .server, let data = try? Data(contentsOf: file) else { throw error }
            return try JSONDecoder().decode(PluginViewDocument.self, from: data)
        }
    }
    func setStorageMode(path: String, mode: WorkspaceStorageMode?, keepLocal: Bool = false) {
        do {
            try localWorkspace?.setMode(path: path, mode: mode, keepLocal: keepLocal)
            reloadLocalWorkspace(); if isWorkspaceConnected { scheduleLocalSync() }
        } catch { statusMessage = error.localizedDescription }
    }
    func resolveStorageConflict(_ conflict: WorkspaceSyncConflict, useServer: Bool) async {
        guard let api, let localWorkspace, !localSyncInProgress else { return }
        do {
            try await localWorkspace.resolveConflict(conflict, useServer: useServer, using: api)
            reloadLocalWorkspace(); await syncLocalWorkspace()
        } catch { statusMessage = error.localizedDescription }
    }

    private func localChangeSaved() {
        reloadLocalWorkspace()
        localSyncMessage = pendingLocalChanges > 0 ? "로컬에 저장됨 · 동기화 대기 \(pendingLocalChanges)개" : "로컬 자료 최신 상태"
        deviceLocalFileCount = localScope == "device-local" ? (localWorkspace?.fileCount ?? 0) : deviceLocalFileCount
        if isWorkspaceConnected { scheduleLocalSync() }
    }

    private func scheduleLocalSync() {
        localSyncTask?.cancel()
        localSyncTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await syncLocalWorkspace()
        }
    }

    func syncLocalWorkspace() async {
        guard let api, let localWorkspace, !activeServerProfileId.isEmpty,
              localBindingServer == normalizedServerURL(api.baseURL.absoluteString), !serverAuthToken.isEmpty,
              !needsCodmesCredentials, !localSyncInProgress else { return }
        let scope = localScope
        let selectedPath = selectedFile?.path ?? selectedRawFile?.path
        let selectedRevision = selectedPath.flatMap { localWorkspace.entry(path: $0)?.revision }
        localSyncInProgress = true
        if localWorkspace.pendingSyncCount > 0 {
            isLocalSyncBusy = true
            localSyncMessage = "로컬 자료 동기화 중…"
        }
        defer {
            localSyncInProgress = false
            if isLocalSyncBusy { isLocalSyncBusy = false }
        }
        do {
            let report = try await localWorkspace.synchronize(using: api)
            guard scope == localScope else { return }
            reloadLocalWorkspace()
            if report.downloaded > 0 || !report.conflicts.isEmpty { localSyncRevision += 1 }
            if let selectedPath,
               selectedPath == (selectedFile?.path ?? selectedRawFile?.path),
               selectedRevision != localWorkspace.entry(path: selectedPath)?.revision,
               let item = localWorkspace.items.first(where: { $0.path == selectedPath }) {
                if isEditingFile, selectedFile?.path == selectedPath,
                   let entry = localWorkspace.entry(path: selectedPath),
                   let content = String(data: try localWorkspace.read(path: selectedPath), encoding: .utf8),
                   let selectedFile {
                    // Clean merged bytes become the editor's next ancestor. New keystrokes made
                    // during upload remain dirty and were not replaced by the sync engine.
                    self.selectedFile = FileResponse(path: selectedPath, name: selectedFile.name, kind: selectedFile.kind,
                                                     size: entry.size, modifiedAt: entry.modifiedAt, content: content)
                    if editorText != content {
                        applyingEditorHistory = true; editorText = content; applyingEditorHistory = false
                        editorHistory.clear()
                    }
                } else { await loadFile(item) }
            }
            let status = report.statusMessage(pendingChanges: pendingLocalChanges)
            if localSyncMessage != status { localSyncMessage = status }
        } catch {
            guard scope == localScope else { return }
            reloadLocalWorkspace()
            if error is CancellationError { localSyncMessage = "로컬에 저장됨 · 동기화 대기"; return }
            if case WorkspaceAPIError.badStatus(404, _) = error {
                localSyncMessage = "로컬 자료는 저장되었습니다. Server Manager를 동기화 지원 버전으로 업데이트하세요."
            } else {
                localSyncMessage = "로컬 자료는 안전하게 저장됨 · 동기화 재시도 대기: \(error.localizedDescription)"
            }
        }
    }

    func monitorLocalSync() async {
        while !Task.isCancelled {
            if !serverAccountToken.isEmpty && !needsCodmesCredentials {
                if isWorkspaceConnected { await syncLocalWorkspace() }
                else { await refreshWorkspace() }
            }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }

    func importDeviceLocalWorkspace() async {
        guard let localWorkspace, localScope != "device-local", !activeServerProfileId.isEmpty else { return }
        do {
            try localWorkspace.importWorkspace(LocalWorkspace(scope: "device-local"))
            localChangeSaved()
            statusMessage = "이 기기의 로컬 자료를 현재 계정에 복사했습니다. 원본은 유지됩니다."
        } catch { statusMessage = error.localizedDescription }
    }

    func localAnnotations(path: String) throws -> PDFAnnotationDocument {
        guard let localWorkspace else { throw LocalWorkspaceError.missing }
        if let data = try? localWorkspace.read(path: path, resource: "annotations") {
            return stableAnnotationPages(try JSONDecoder().decode(PDFAnnotationDocument.self, from: data))
        }
        return PDFAnnotationDocument(schemaVersion: 2, documentPath: path, updatedAt: nil, pages: [], objects: [])
    }

    func saveLocalAnnotations(path: String, annotations: PDFAnnotationDocument) throws -> PDFAnnotationDocument {
        guard let localWorkspace else { throw LocalWorkspaceError.missing }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let annotations = stableAnnotationPages(annotations)
        try localWorkspace.write(path: path, data: encoder.encode(annotations), resource: "annotations")
        localChangeSaved()
        return annotations
    }

    func saveLocalPDF(path: String, pdf: Data, annotations: PDFAnnotationDocument, createOnly: Bool = false) throws {
        guard let localWorkspace else { throw LocalWorkspaceError.missing }
        try localWorkspace.writePDF(path: path, pdf: pdf, annotations: stableAnnotationPages(annotations), createOnly: createOnly)
        if selectedRawFile?.path == path, let url = localWorkspace.url(path: path) {
            selectedRawFile = RawFilePreview(path: path, name: (path as NSString).lastPathComponent, kind: "pdf", url: url)
        }
        localChangeSaved()
    }

    private func stableAnnotationPages(_ input: PDFAnnotationDocument) -> PDFAnnotationDocument {
        var doc = input
        for index in doc.pages.indices where doc.pages[index].pageId == nil { doc.pages[index].pageId = "index:\(doc.pages[index].pageIndex)" }
        return doc
    }


    private func availableLocalPath(_ path: String) -> String {
        guard localWorkspace?.items.contains(where: { $0.path == path }) == true else { return path }
        let ns = path as NSString, ext = ns.pathExtension
        return "\(ns.deletingPathExtension) (\(UUID().uuidString.prefix(8)))\(ext.isEmpty ? "" : "." + ext)"
    }

    /// Restore a remembered login without making server authentication an app-entry requirement.
    /// Fresh clients do not probe the default localhost server on launch.
    func restoreServerConnectionIfAvailable() async {
        guard !serverAccountToken.isEmpty else {
            if let url = currentServerURL { resumeGooglePendingRequest(for: url) }
            return
        }
        await loadServerProfiles()
        guard !serverAccountToken.isEmpty, !needsCodmesCredentials, !isWorkspaceConnected else { return }
        await refreshWorkspace()
    }

    var profileStorageScope: String {
        let savedServer = UserDefaults.standard.string(forKey: "workspace.serverURL") ?? serverURLText
        let server = normalizedServerURL(savedServer)
        return activeServerProfileId.isEmpty ? "device-local" : "\(server)|\(activeServerProfileId)"
    }

    private var profilePreferencesKey: String {
        let digest = SHA256.hash(data: Data(profileStorageScope.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadProfilePreferences() {
        hiddenModelProviderIds = Self.loadStringSet(modelVisibilityKey("codmes.hiddenModelProviderIds"))
        hiddenModelIds = Self.loadStringSet(modelVisibilityKey("codmes.hiddenModelIds"))
    }

    private func modelVisibilityKey(_ base: String) -> String {
        activeServerProfileId.isEmpty ? base : "\(base).\(profilePreferencesKey)"
    }

    private func clearProfileState() {
        _ = persistEditorText()
        for task in pluginAuthTasks.values { task.cancel() }
        for task in pluginAuthMonitorTasks.values { task.cancel() }
        pluginAuthTasks = [:]
        pluginAuthMonitorTasks = [:]
        pluginAuthRefreshesInFlight = []
        lastPluginAuthRefreshAt = [:]
        activeFileLoadID = nil
        activeFileLoadPath = nil
        activeFileLoadItem = nil
        savedFileSurfaces = [:]
        retainedFileSurfaces = []
        activeFileSurface = nil
        pendingFileSurfaceRestore = nil
        pdfReadingStates = [:]
        rawFileCache.removeAll()
        workspace = nil
        notes = []
        code = []
        notesPath = ""
        codePath = ""
        selectedFile = nil
        selectedRawFile = nil
        selectedPDFFocus = nil
        loadingRawFile = nil
        rawFileLoadError = nil
        editorText = ""
        isEditingFile = false
        searchResponse = nil
        globalSearchResponse = nil
        hermesModels = []
        hermesSessions = []
        chatHistoryStorage = ChatHistoryStorage(bytes: 0, sessionCount: 0, assetCount: 0)
        selectedHermesModelId = ""
        chatAccessMode = .confirm
        chatReasoningMode = .balanced
        chatContextScope = .currentFile
        sessionManagerSearch = ""
        selectedHermesProjectId = "__all__"
        conversationFolders = []
        uploadItems = []
        documentJobs = []
        agentTasks = []
        codeTasks = []
        selectedCodeTask = nil
        selectedCodeTaskDiff = ""
        codeTaskInstruction = ""
        isLoadingCodeTask = false
        approvals = []
        selectedApprovalDiffText = ""
        runtimeProviders = []
        runtimeProviderModels = [:]
        runtimeProviderCredentials = [:]
        runtimeOAuthSessions = [:]
        runtimeModelSetupMessage = ""
        runtimePlugins = []
        pluginSetupMessage = ""
        pluginMCPToolConsents = [:]
        pluginMCPToolOperations = []
        pluginAuthStatuses = [:]
        pluginAuthOperations = [:]
        pluginAuthErrors = [:]
        pluginAuthRevision += 1
        mcpServers = []
        mcpSetupMessage = ""
        marketplacePlugins = []
        marketplaceMessage = ""
        marketplaceOperations = []
        isMarketplaceLoading = false
        searchConfig = nil
        searchSetupMessage = ""
        activePDFStatusText = ""
        activePDFStatusPath = ""
        localFileCacheUsageBytes = 0
        statusMessage = "서버 연결 없이 사용 중"
        isWorkspaceConnected = false
        isLoading = false
    }

    var api: WorkspaceAPI? {
        guard let url = currentServerURL else { return nil }
        return WorkspaceAPI(baseURL: url, authToken: url == authenticatedServerURL ? serverAuthToken : "")
    }

    private var accountAPI: WorkspaceAPI? {
        guard let url = currentServerURL else { return nil }
        return WorkspaceAPI(baseURL: url, authToken: url == authenticatedServerURL ? serverAccountToken : "")
    }

    func loadServerProfiles() async {
        guard let accountAPI else { return }
        let serverURL = accountAPI.baseURL
        let loadKey = "\(serverURL.absoluteString)|\(accountAPI.authToken)"
        guard profileLoadsInFlight.insert(loadKey).inserted else { return }
        defer { profileLoadsInFlight.remove(loadKey) }
        let fetchedGoogleConfig = try? await WorkspaceAPI(baseURL: serverURL).googleAuthConfig()
        guard currentServerURL == serverURL else { return }
        googleAuthConfig = fetchedGoogleConfig
        googleAuthConfigServerURL = fetchedGoogleConfig == nil ? nil : serverURL
        if googleAuthConfig != nil { serverUsesProfiles = true }
        guard serverURL == authenticatedServerURL else { return }
        do {
            serverUsesProfiles = true
            guard !serverAccountToken.isEmpty else {
                resumeGooglePendingRequest(for: serverURL)
                return
            }
            let state = try await accountAPI.ensureGoogleProfile()
            guard currentServerURL == serverURL, serverAccountToken == accountAPI.authToken else { return }
            googleAccountIdentity = state.user
            serverProfiles = state.profile.map { [$0] } ?? []
            serverAccountMessage = ""
            if state.user.credentialsConfigured == false {
                serverAuthToken = ""
                persistServerAuthToken()
                return
            }
            if let profile = state.profile {
                // Always reopen using the approved Google session. Old shared
                // profile tokens must never keep another owner's data selected.
                if activeServerProfileId != profile.id || serverAuthToken.isEmpty {
                    await openServerProfile(profile, pin: "")
                }
            }
        } catch {
            if case WorkspaceAPIError.badStatus(401, _) = error, !serverAccountToken.isEmpty {
                signOutServer()
                serverAccountMessage = "서버 계정 세션이 만료되었거나 취소되었습니다. 다시 로그인하세요."
                return
            }
            serverAccountMessage = error.localizedDescription
        }
    }

    var googleLoginTransportIsSecure: Bool {
        guard let url = currentServerURL, let scheme = url.scheme?.lowercased(),
              let host = url.host(percentEncoded: false)?.lowercased() else { return false }
        return scheme == "https" || (scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host))
    }

    var googleAppRedirectIsConfigured: Bool {
        guard let clientID = GoogleOAuthAttempt.publisherClientID(),
              clientID == googleAuthConfig?.appleClientID else { return false }
        return (try? GoogleOAuthAttempt.registeredRedirectURI(for: clientID)) != nil
    }

    func signInWithGoogle() async {
        guard !isGoogleLoginBusy else { return }
        guard let serverURL = currentServerURL,
              let config = googleAuthConfig,
              googleAuthConfigServerURL == serverURL,
              config.enabled,
              let clientID = GoogleOAuthAttempt.publisherClientID() else {
            googleLoginMessage = "앱 또는 Server Manager에 배포자의 Google 로그인이 준비되지 않았습니다. 서버 운영자가 별도로 Google 프로젝트를 만들 필요는 없습니다."
            return
        }
        guard googleLoginTransportIsSecure else {
            googleLoginMessage = "원격 서버 로그인에는 HTTPS가 필요합니다. HTTP는 같은 기기의 localhost에서만 사용할 수 있습니다."
            return
        }
        isGoogleLoginBusy = true
        googleLoginMessage = "Google 계정을 확인하는 중입니다."
        defer { isGoogleLoginBusy = false }
        do {
            try GoogleOAuthAttempt.validatePublisher(clientID: clientID, serverClientID: config.appleClientID)
            let redirectURI = try GoogleOAuthAttempt.registeredRedirectURI(for: clientID)
            let idToken = try await googleSignInController.signIn(clientID: clientID, redirectURI: redirectURI)
            guard currentServerURL == serverURL else { return }
            guard let deviceID = KeychainStore.deviceID(for: serverURL) else {
                googleLoginMessage = "기기 등록 정보를 보안 저장소에 저장할 수 없습니다."
                return
            }
            #if os(iOS)
            let deviceName = UIDevice.current.name
            #else
            let deviceName = Host.current().localizedName ?? "Mac"
            #endif
            let response = try await WorkspaceAPI(baseURL: serverURL).googleClientLogin(idToken: idToken, deviceID: deviceID, deviceName: deviceName)
            guard currentServerURL == serverURL else { return }
            if response.status == "account_setup_required" { accountSetupGoogleToken = (idToken, serverURL, Date()) }
            await handleGoogleLoginResponse(response, serverURL: serverURL)
        } catch {
            googleLoginMessage = error.localizedDescription
        }
    }

    func signInWithCodmes(username: String, password: String, confirmation: String, register: Bool) async -> Bool {
        guard !isCodmesAccountBusy, let serverURL = currentServerURL, googleLoginTransportIsSecure,
              let deviceID = KeychainStore.deviceID(for: serverURL) else { return false }
        let setup = register || needsCodmesCredentials
        if setup && (password.count < 15 || password.count > 128 || password != confirmation) {
            googleLoginMessage = "비밀번호는 15~128자로 입력하고 확인란과 일치해야 합니다."
            return false
        }
        isCodmesAccountBusy = true
        defer { isCodmesAccountBusy = false }
        do {
            if !serverAccountToken.isEmpty && needsCodmesCredentials {
                guard let accountAPI else { return false }
                let response = try await accountAPI.updateCodmesAccount(action: "credentials", fields: ["username": username, "password": password])
                guard currentServerURL == serverURL, serverAccountToken == accountAPI.authToken else { return false }
                googleAccountIdentity = response.user
                googleLoginMessage = "Codmes 계정을 설정했습니다."
                await loadServerProfiles()
            } else {
                let response: GoogleClientLoginResponse
                if let google = accountSetupGoogleToken, needsCodmesCredentials {
                    guard google.server == serverURL && Date().timeIntervalSince(google.created) < 600 else {
                        cancelCodmesAccountSetup(); googleLoginMessage = "Google 인증 시간이 지났습니다. 다시 Google로 로그인하세요."; return false
                    }
                    response = try await WorkspaceAPI(baseURL: serverURL).googleClientLogin(idToken: google.token, deviceID: deviceID, deviceName: "Codmes Apple", username: username, password: password)
                } else {
                    response = try await WorkspaceAPI(baseURL: serverURL).codmesClientLogin(username: username, password: password, deviceID: deviceID, register: register)
                }
                guard currentServerURL == serverURL else { return false }
                accountSetupGoogleToken = nil
                await handleGoogleLoginResponse(response, serverURL: serverURL)
            }
            return true
        } catch { googleLoginMessage = error.localizedDescription; return false }
    }

    func cancelCodmesAccountSetup() {
        accountSetupGoogleToken = nil
        googleLoginStage = ""
        googleAccountIdentity = nil
        googleLoginMessage = ""
    }

    func changeCodmesPassword(current: String, password: String, confirmation: String) async -> Bool {
        guard password.count >= 15, password.count <= 128, password == confirmation else {
            serverAccountMessage = "비밀번호는 15~128자로 입력하고 확인란과 일치해야 합니다."; return false
        }
        return await updateCodmesAccount(action: "password", fields: ["currentPassword": current, "password": password])
    }

    func unlinkGoogleAccount(password: String) async -> Bool {
        await updateCodmesAccount(action: "google/unlink", fields: ["currentPassword": password])
    }

    func linkGoogleAccount(password: String) async -> Bool {
        guard !isGoogleLoginBusy, let serverURL = currentServerURL, googleLoginTransportIsSecure,
              let clientID = GoogleOAuthAttempt.publisherClientID(), let config = googleAuthConfig else { return false }
        let currentAccountToken = serverAccountToken
        isGoogleLoginBusy = true
        defer { isGoogleLoginBusy = false }
        do {
            try GoogleOAuthAttempt.validatePublisher(clientID: clientID, serverClientID: config.appleClientID)
            let redirect = try GoogleOAuthAttempt.registeredRedirectURI(for: clientID)
            let token = try await googleSignInController.signIn(clientID: clientID, redirectURI: redirect)
            guard currentServerURL == serverURL, serverAccountToken == currentAccountToken else { return false }
            return await updateCodmesAccount(action: "google/link", fields: ["currentPassword": password, "idToken": token])
        } catch { serverAccountMessage = error.localizedDescription; return false }
    }

    private func updateCodmesAccount(action: String, fields: [String: String]) async -> Bool {
        guard !isCodmesAccountBusy, let accountAPI else { return false }
        isCodmesAccountBusy = true
        defer { isCodmesAccountBusy = false }
        do {
            let response = try await accountAPI.updateCodmesAccount(action: action, fields: fields)
            guard currentServerURL == accountAPI.baseURL, serverAccountToken == accountAPI.authToken else { return false }
            googleAccountIdentity = response.user
            serverAccountMessage = "변경했습니다. 자료와 기기 승인은 유지되며 다른 로그인 세션은 해제됩니다."
            return true
        } catch { serverAccountMessage = error.localizedDescription; return false }
    }

    func refreshGoogleApproval() async {
        guard let serverURL = currentServerURL,
              let pending = KeychainStore.readGooglePendingRequest(for: serverURL) else { return }
        await checkGoogleApproval(pending, serverURL: serverURL)
    }

    private func resumeGooglePendingRequest(for serverURL: URL) {
        guard let pending = KeychainStore.readGooglePendingRequest(for: serverURL) else { return }
        googleAccountIdentity = pending.user
        googleLoginStage = "pending"
        googleLoginMessage = "서버 관리자에게 기기 등록 승인을 요청했습니다."
        updateSignInWaitStatus()
        startGooglePendingPolling(pending, serverURL: serverURL)
    }

    private func updateSignInWaitStatus() {
        isWorkspaceConnected = false
        if !serverAccountToken.isEmpty {
            statusMessage = "내 프로필 연결 중"
            connectionStep = "Loading Codmes account profile"
            connectionDetail = "기기 등록이 승인되었습니다. Codmes 계정의 자료를 불러옵니다."
        } else if googleLoginStage == "pending" {
            statusMessage = "기기 등록 승인 대기 중"
            connectionStep = "Waiting for device approval"
            connectionDetail = "서버 로그인이 완료되었습니다. 서버 관리자의 기기 등록 수락을 기다립니다."
        } else if googleLoginStage == "rejected" {
            statusMessage = "기기 등록이 거절되었습니다"
            connectionStep = "Device registration rejected"
            connectionDetail = "서버 관리자에게 접속 허용을 문의하세요."
        } else {
            statusMessage = "서버 로그인 필요"
            connectionStep = "Waiting for server sign-in"
            connectionDetail = "서버에 연결했습니다. Codmes ID·비밀번호 또는 연결된 Google 계정으로 로그인하고 기기 승인을 받아 주세요."
        }
        persistConnectionDiagnostics()
    }

    private func startGooglePendingPolling(_ pending: GooglePendingRequest, serverURL: URL) {
        googleApprovalPolling.start(requestID: pending.requestId) { [weak self] in
            guard let self, self.currentServerURL == serverURL else { return false }
            await self.checkGoogleApproval(pending, serverURL: serverURL)
            return self.googleLoginStage == "pending"
        }
    }

    private func checkGoogleApproval(_ pending: GooglePendingRequest, serverURL: URL) async {
        let checkID = "\(serverURL.absoluteString)|\(pending.requestId)"
        guard currentServerURL == serverURL,
              googleApprovalPolling.requestID == pending.requestId,
              googleApprovalChecksInFlight.insert(checkID).inserted else { return }
        defer { googleApprovalChecksInFlight.remove(checkID) }
        do {
            let response = try await WorkspaceAPI(baseURL: serverURL).googleClientStatus(
                requestID: pending.requestId,
                requestToken: pending.requestToken
            )
            guard currentServerURL == serverURL, googleApprovalPolling.requestID == pending.requestId else { return }
            await handleGoogleLoginResponse(response, serverURL: serverURL)
        } catch {
            guard currentServerURL == serverURL, googleApprovalPolling.requestID == pending.requestId else { return }
            if case WorkspaceAPIError.badStatus(401, _) = error {
                googleApprovalPolling.cancel()
                _ = KeychainStore.deleteGooglePendingRequest(for: serverURL)
                googleLoginStage = "expired"
                googleLoginMessage = "승인 요청이 만료되었습니다. 같은 Codmes 계정으로 다시 로그인하면 승인 상태를 이어받습니다."
                updateSignInWaitStatus()
                return
            }
            googleLoginMessage = "승인 상태를 확인하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func handleGoogleLoginResponse(_ response: GoogleClientLoginResponse, serverURL: URL) async {
        if let user = response.user { googleAccountIdentity = user }
        switch response.status {
        case "account_setup_required":
            googleLoginStage = "account_setup_required"
            googleLoginMessage = "Codmes ID·비밀번호를 한 번 설정하세요. 이후 ID·비밀번호 또는 Google로 로그인할 수 있습니다."
        case "approved":
            guard let token = response.token, !token.isEmpty else {
                googleLoginMessage = "승인은 되었지만 서버 계정 토큰을 받지 못했습니다."
                return
            }
            googleApprovalPolling.finish()
            _ = KeychainStore.deleteGooglePendingRequest(for: serverURL)
            googleLoginStage = "approved"
            googleLoginMessage = "기기 등록이 승인되었습니다."
            clearProfileState()
            serverAuthToken = ""
            activeServerProfileId = ""
            activeServerProfileName = ""
            loadProfilePreferences()
            persistServerAuthToken()
            serverAccountToken = token
            authenticatedServerURL = serverURL
            _ = KeychainStore.writeServerAccountToken(token)
            updateSignInWaitStatus()
            await loadServerProfiles()
        case "pending":
            let requestID = response.requestId
                ?? KeychainStore.readGooglePendingRequest(for: serverURL)?.requestId
            let requestToken = response.requestToken
                ?? KeychainStore.readGooglePendingRequest(for: serverURL)?.requestToken
            guard let requestID, let requestToken, !requestID.isEmpty, !requestToken.isEmpty else {
                googleLoginMessage = "승인 요청 정보를 받지 못했습니다. 다시 로그인해 주세요."
                return
            }
            let pending = GooglePendingRequest(requestId: requestID, requestToken: requestToken, user: googleAccountIdentity)
            guard KeychainStore.writeGooglePendingRequest(pending, for: serverURL) else {
                googleLoginMessage = "승인 요청을 보안 저장소에 저장할 수 없습니다."
                return
            }
            googleLoginStage = "pending"
            googleLoginMessage = "서버 관리자에게 기기 등록 승인을 요청했습니다. 승인되면 자동으로 연결됩니다."
            updateSignInWaitStatus()
            startGooglePendingPolling(pending, serverURL: serverURL)
        case "rejected":
            googleApprovalPolling.cancel()
            _ = KeychainStore.deleteGooglePendingRequest(for: serverURL)
            googleLoginStage = "rejected"
            googleLoginMessage = "서버 관리자가 이 기기 등록을 거절했습니다."
            updateSignInWaitStatus()
        default:
            googleLoginMessage = "서버에서 알 수 없는 기기 등록 상태를 받았습니다."
        }
    }

    func openServerProfile(_ profile: ServerProfile, pin: String) async {
        guard let accountAPI else { return }
        do {
            let opened = try await accountAPI.openProfile(id: profile.id, pin: pin)
            guard currentServerURL == accountAPI.baseURL, serverAccountToken == accountAPI.authToken else { return }
            clearProfileState()
            serverAuthToken = opened.token
            activeServerProfileName = opened.profile.name
            activeServerProfileId = opened.profile.id
            localBindingServer = normalizedServerURL(accountAPI.baseURL.absoluteString)
            let binding = LocalBinding(server: localBindingServer!, profileId: opened.profile.id, profileName: opened.profile.name)
            if let data = try? JSONEncoder().encode(binding) { UserDefaults.standard.set(data, forKey: "workspace.localBinding") }
            openLocalWorkspace()
            loadProfilePreferences()
            persistServerAuthToken()
            serverAccountMessage = ""
            await refreshWorkspace()
        } catch {
            serverAccountMessage = error.localizedDescription
        }
    }

    func changeServerProfilePIN(_ profile: ServerProfile, currentPin: String, pin: String) async -> Bool {
        guard let accountAPI else { return false }
        do {
            try await accountAPI.changeProfilePIN(id: profile.id, currentPin: currentPin, pin: pin)
            if activeServerProfileId == profile.id {
                clearProfileState()
                serverAuthToken = ""
                persistServerAuthToken()
                isWorkspaceConnected = false
                activeServerProfileName = ""
                activeServerProfileId = ""
                loadProfilePreferences()
            }
            await loadServerProfiles()
            return true
        } catch {
            serverAccountMessage = error.localizedDescription
            return false
        }
    }

    func archiveServerProfile(_ profile: ServerProfile, currentPin: String) async -> Bool {
        guard let accountAPI else { return false }
        do {
            try await accountAPI.archiveProfile(id: profile.id, currentPin: currentPin)
            if activeServerProfileId == profile.id {
                clearProfileState()
                serverAuthToken = ""
                persistServerAuthToken()
                isWorkspaceConnected = false
                activeServerProfileName = ""
                activeServerProfileId = ""
                loadProfilePreferences()
            }
            await loadServerProfiles()
            return true
        } catch {
            serverAccountMessage = error.localizedDescription
            return false
        }
    }

    func signOutServer() {
        let oldAccountToken = serverAccountToken
        let oldServerURL = authenticatedServerURL
        googleApprovalPolling.cancel()
        if let serverURL = currentServerURL {
            _ = KeychainStore.deleteGooglePendingRequest(for: serverURL)
        }
        googleLoginStage = "idle"
        googleLoginMessage = ""
        googleAccountIdentity = nil
        accountSetupGoogleToken = nil
        authenticatedServerURL = currentServerURL
        clearProfileState()
        serverAccountToken = ""
        _ = KeychainStore.deleteServerAccountToken()
        serverAuthToken = ""
        persistServerAuthToken()
        serverProfiles = []
        activeServerProfileName = ""
        activeServerProfileId = ""
        localBindingServer = nil
        UserDefaults.standard.removeObject(forKey: "workspace.localBinding")
        openLocalWorkspace()
        loadProfilePreferences()
        if !oldAccountToken.isEmpty, let oldServerURL {
            Task {
                try? await WorkspaceAPI(baseURL: oldServerURL, authToken: oldAccountToken).signOutAccount()
            }
        }
        Task { await loadServerProfiles() }
    }

    func pluginAuthStatus(for pluginId: String?) -> PluginAuthStatus? {
        guard let pluginId else { return nil }
        return pluginAuthStatuses[pluginId]
    }

    func pluginAuthOperation(for pluginId: String?) -> String? {
        guard let pluginId else { return nil }
        return pluginAuthOperations[pluginId]
    }

    func pluginAuthError(for pluginId: String?) -> String? {
        guard let pluginId else { return nil }
        return pluginAuthErrors[pluginId]
    }

    func refreshPluginAuthStatus(pluginId: String) async {
        guard !pluginAuthRefreshesInFlight.contains(pluginId) else { return }
        if let lastRefresh = lastPluginAuthRefreshAt[pluginId],
           Date().timeIntervalSince(lastRefresh) < 2 {
            return
        }
        guard let api else {
            pluginAuthErrors[pluginId] = "Codmes 서버에 연결되지 않았습니다."
            return
        }
        pluginAuthRefreshesInFlight.insert(pluginId)
        lastPluginAuthRefreshAt[pluginId] = Date()
        defer { pluginAuthRefreshesInFlight.remove(pluginId) }
        do {
            let status = try await api.pluginAuthStatus(pluginId: pluginId)
            updatePluginAuthStatus(status, pluginId: pluginId)
            pluginAuthErrors[pluginId] = nil
        } catch {
            pluginAuthErrors[pluginId] = error.localizedDescription
        }
    }

    func startPluginLogin(pluginId: String, username: String, password: String) {
        guard pluginAuthTasks[pluginId] == nil else { return }
        guard let api else {
            pluginAuthErrors[pluginId] = "Codmes 서버에 연결되지 않았습니다."
            return
        }

        let submittedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedPassword = password
        pluginAuthErrors[pluginId] = nil
        pluginAuthOperations[pluginId] = "login"
        pluginAuthTasks[pluginId] = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await api.loginPlugin(
                    pluginId: pluginId,
                    username: submittedUsername,
                    password: submittedPassword
                )
                guard !Task.isCancelled else { return }
                self.updatePluginAuthStatus(
                    PluginAuthStatus(
                        supported: true,
                        authenticated: response.authenticated,
                        username: response.username,
                        reachable: true
                    ),
                    pluginId: pluginId
                )
                self.pluginAuthErrors[pluginId] = nil
                self.finishPluginAuthOperation(pluginId)
                self.startPluginAuthMonitoring(pluginId: pluginId)
            } catch {
                guard !Task.isCancelled else { return }
                self.pluginAuthErrors[pluginId] = error.localizedDescription
                self.finishPluginAuthOperation(pluginId)
            }
        }
    }

    func startPluginLogout(pluginId: String) {
        guard pluginAuthTasks[pluginId] == nil else { return }
        guard let api else {
            pluginAuthErrors[pluginId] = "Codmes 서버에 연결되지 않았습니다."
            return
        }

        pluginAuthMonitorTasks[pluginId]?.cancel()
        pluginAuthMonitorTasks[pluginId] = nil
        pluginAuthErrors[pluginId] = nil
        pluginAuthOperations[pluginId] = "logout"
        pluginAuthTasks[pluginId] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await api.logoutPlugin(pluginId: pluginId)
                guard !Task.isCancelled else { return }
                self.updatePluginAuthStatus(
                    PluginAuthStatus(
                        supported: true,
                        authenticated: false,
                        username: nil,
                        reachable: true
                    ),
                    pluginId: pluginId
                )
                self.pluginAuthErrors[pluginId] = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.pluginAuthErrors[pluginId] = error.localizedDescription
            }
            self.finishPluginAuthOperation(pluginId)
        }
    }

    private func finishPluginAuthOperation(_ pluginId: String) {
        pluginAuthOperations[pluginId] = nil
        pluginAuthTasks[pluginId] = nil
    }

    private func updatePluginAuthStatus(_ status: PluginAuthStatus, pluginId: String) {
        if pluginAuthStatuses[pluginId] != status {
            pluginAuthStatuses[pluginId] = status
            pluginAuthRevision += 1
        }
    }

    private func startPluginAuthMonitoring(pluginId: String) {
        pluginAuthMonitorTasks[pluginId]?.cancel()
        pluginAuthMonitorTasks[pluginId] = Task { [weak self] in
            guard let self else { return }
            for attempt in 0..<120 {
                await self.refreshPluginAuthStatus(pluginId: pluginId)
                guard !Task.isCancelled else { return }
                guard let status = self.pluginAuthStatuses[pluginId],
                      status.authenticated else { break }
                if status.reachable != false,
                   status.profileSyncing != true {
                    break
                }
                if attempt < 119 {
                    let delay = status.reachable == false ? 10 : 3
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
            self.pluginAuthMonitorTasks[pluginId] = nil
        }
    }

    var effectiveServerURLText: String {
        normalizedServerURL(serverURLText)
    }

    var localFileCacheLimitBytes: Int64 {
        Int64(localFileCacheLimitGB) * 1_024 * 1_024 * 1_024
    }

    var activeDocumentJobs: [DocumentJob] {
        documentJobs.filter(\.isRunning)
    }

    var documentJobProgress: Double {
        guard !activeDocumentJobs.isEmpty else { return 0 }
        return activeDocumentJobs.map(\.progress).reduce(0, +) / Double(activeDocumentJobs.count)
    }

    func refreshDocumentJobs() async {
        guard let api else {
            if !documentJobs.isEmpty { documentJobs = [] }
            return
        }
        do {
            let jobs = try await api.documentJobs()
            if documentJobs != jobs { documentJobs = jobs }
        } catch {
            if !isWorkspaceConnected {
                if !documentJobs.isEmpty { documentJobs = [] }
            }
        }
    }

    func monitorDocumentJobs() async {
        while !Task.isCancelled {
            if isWorkspaceConnected { await refreshDocumentJobs() }
            let interval: UInt64 = activeDocumentJobs.isEmpty ? 2_000_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    func setLocalFileCacheLimitGB(_ value: Int) {
        localFileCacheLimitGB = min(max(value, 1), 50)
        UserDefaults.standard.set(localFileCacheLimitGB, forKey: "workspace.localFileCacheLimitGB")
        let scope = profileStorageScope
        Task {
            await fileDiskCache.trim(to: localFileCacheLimitBytes, keeping: selectedRawFile?.url, scope: scope)
            await refreshLocalFileCacheUsage()
        }
    }

    func refreshLocalFileCacheUsage() async {
        let scope = profileStorageScope
        let bytes = await fileDiskCache.usageBytes(scope: scope)
        if scope == profileStorageScope { localFileCacheUsageBytes = bytes }
    }

    func clearLocalFileCache() async {
        let scope = profileStorageScope
        await fileDiskCache.clear(keeping: selectedRawFile?.url, scope: scope)
        rawFileCache = rawFileCache.filter {
            FileManager.default.fileExists(atPath: $0.value.preview.url.path)
        }
        await refreshLocalFileCacheUsage()
    }

    private var currentServerURL: URL? {
        URL(string: effectiveServerURLText)
    }

    var serverURLUsesLocalhost: Bool {
        guard let host = URL(string: serverURLText)?.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    var serverConnectionHint: String {
        if serverURLUsesLocalhost {
            #if os(iOS)
            return "On iPhone/iPad, 127.0.0.1 means this device. Use the Mac/Tailscale address, for example http://100.x.x.x:8787."
            #else
            return "127.0.0.1 works only on this Mac. Other devices need this Mac's LAN or Tailscale address."
            #endif
        }
        return "Use the Workspace Server URL, for example http://100.x.x.x:8787 over Tailscale."
    }

    var selectableRuntimeProviders: [RuntimeProviderOption] {
        runtimeProviders.filter { $0.configured == true || $0.isLocalProvider }
    }

    var macTailscaleServerURL: String {
        "http://100.123.26.117:8787"
    }

    func saveServerURL() {
        let previous = authenticatedServerURL
        let cleaned = normalizedServerURL(serverURLText)
        serverURLText = cleaned
        UserDefaults.standard.set(cleaned, forKey: "workspace.serverURL")
        if previous != URL(string: cleaned) {
            signOutServer()
            resetLiveConnectionForServerSettingsChange("Server URL changed")
        }
    }

    func persistServerURLText() {
        UserDefaults.standard.set(serverURLText, forKey: "workspace.serverURL")
    }

    func persistServerAuthToken() {
        let previous = WorkspaceStore.initialServerAuthToken()
        if KeychainStore.writeServerAuthToken(serverAuthToken) {
            UserDefaults.standard.removeObject(forKey: "workspace.serverAuthToken")
        } else {
            UserDefaults.standard.set(serverAuthToken, forKey: "workspace.serverAuthToken")
        }
        if previous != serverAuthToken {
            resetLiveConnectionForServerSettingsChange("Server token changed")
        }
    }

    func useMacTailscaleServerURL() {
        serverURLText = macTailscaleServerURL
        saveServerURL()
    }

    private func resetLiveConnectionForServerSettingsChange(_ reason: String) {
        liveSessionId = nil
        activeHermesSessionTitle = "No session"
        activeActivityLineId = nil
        isChatTurnOpen = false
        chatLines = [ChatLine(role: "system", text: "\(reason). Connect again to use \(effectiveServerURLText).")]
        Task {
            await liveClient.disconnect()
        }
    }

    func refreshWorkspace() async {
        saveServerURL()
        guard let api else {
            statusMessage = "Invalid server URL"
            isWorkspaceConnected = false
            connectionDetail = "Could not parse \(serverURLText)"
            connectionStep = "URL parse"
            persistConnectionDiagnostics()
            return
        }
        let profileToken = serverAuthToken
        let profileScope = profileStorageScope
        isLoading = true
        defer {
            if profileToken == serverAuthToken && profileScope == profileStorageScope { isLoading = false }
        }
        do {
            connectionStep = "Checking /api/health"
            connectionDetail = "Trying \(effectiveServerURLText)/api/health"
            let health = try await api.health()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            connectionDetail = "Health OK: \(health.service) at \(serverURLText)"
            if (health.authRequired == true || serverUsesProfiles) && profileToken.isEmpty {
                await loadServerProfiles()
                guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
                updateSignInWaitStatus()
                return
            }
            connectionStep = "Loading /api/workspace"
            let loadedWorkspace = try await api.workspace()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            workspace = loadedWorkspace
            connectionStep = "Synchronizing local Notes and Code"
            await syncLocalWorkspace()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            reloadLocalWorkspace()
            connectionStep = "Loading surfaces"
            await refreshPlugins()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            connectionStep = "Loading MCP servers"
            await refreshMCPServers()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            connectionStep = "Loading Marketplace"
            await refreshMarketplace()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            await refreshSearchConfig()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            connectionStep = "Loading runtime metadata"
            await refreshHermesMetadata()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            connectionStep = "Loading pending approvals"
            await refreshApprovals()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            connectionStep = "Loading agent tasks"
            await refreshAgentTasks()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            await refreshDocumentJobs()
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            statusMessage = "Connected"
            isWorkspaceConnected = true
            connectionStep = "Ready"
            persistConnectionDiagnostics()
        } catch {
            guard profileToken == serverAuthToken && profileScope == profileStorageScope else { return }
            if case WorkspaceAPIError.badStatus(401, _) = error, !profileToken.isEmpty {
                serverAuthToken = ""
                persistServerAuthToken()
                isWorkspaceConnected = false
                await loadServerProfiles()
                return
            }
            statusMessage = "Connection failed"
            isWorkspaceConnected = false
            connectionDetail = "\(connectionStep) failed for \(serverURLText): \(describeConnectionError(error))"
            persistConnectionDiagnostics()
        }
    }

    func refreshHermesMetadata() async {
        guard let api else { return }
        do {
            hermesModels = try await api.hermesModelOptions()
            hermesSessions = try await api.hermesSessions()
            chatHistoryStorage = try await api.chatHistoryStorage()
            conversationFolders = try await api.conversationFolders()
            if selectedHermesModelId.isEmpty {
                selectedHermesModelId = visibleHermesModels.first?.id ?? hermesModels.first?.id ?? ""
            }
            ensureVisibleSelectedModel()
            updateActiveSessionTitle()
        } catch {
            statusMessage = "Runtime metadata: \(error.localizedDescription)"
        }
    }

    func createConversationFolder(name: String) async {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            statusMessage = "Folder name is required"
            return
        }
        guard let api else { return }
        do {
            let folder = try await api.createConversationFolder(name: cleaned)
            conversationFolders.append(folder)
            selectedHermesProjectId = folder.id
            statusMessage = "Created group folder \(folder.name)"
            await refreshHermesMetadata()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteConversationFolder(_ folder: ConversationFolder) async {
        guard let api else { return }
        do {
            try await api.deleteConversationFolder(folderId: folder.id)
            conversationFolders.removeAll { $0.id == folder.id }
            if selectedHermesProjectId == folder.id {
                selectedHermesProjectId = "__all__"
            }
            statusMessage = "Deleted group folder \(folder.name)"
            await refreshHermesMetadata()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameConversationFolder(_ folder: ConversationFolder, name: String) async {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            statusMessage = "Project name is required"
            return
        }
        guard let api else { return }
        do {
            let updated = try await api.updateConversationFolder(folderId: folder.id, name: cleaned)
            conversationFolders = conversationFolders.map { $0.id == folder.id ? updated : $0 }
            statusMessage = "Renamed project to \(cleaned)"
            await refreshHermesMetadata()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func moveSession(
        _ session: HermesSessionSummary,
        toFolderId folderId: String?,
        projectId: String? = nil,
        projectTitle: String? = nil
    ) async {
        guard let api else { return }
        do {
            try await api.moveSession(
                sessionId: session.id,
                folderId: folderId,
                projectId: projectId,
                projectTitle: projectTitle
            )
            statusMessage = "Moved \(session.title)"
            await refreshHermesMetadata()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func moveSessions(
        _ sessions: [HermesSessionSummary],
        toFolderId folderId: String?,
        projectId: String? = nil,
        projectTitle: String? = nil
    ) async {
        guard let api, !sessions.isEmpty else { return }
        var movedIds = Set<String>()
        var failureCount = 0
        for session in sessions {
            do {
                try await api.moveSession(
                    sessionId: session.id,
                    folderId: folderId,
                    projectId: projectId,
                    projectTitle: projectTitle
                )
                movedIds.insert(session.id)
            } catch {
                failureCount += 1
            }
        }
        statusMessage = failureCount == 0
            ? "Moved \(movedIds.count) sessions"
            : "Moved \(movedIds.count), failed \(failureCount)"
        await refreshHermesMetadata()
    }

    func refreshRuntimeProviders() async {
        guard let api else { return }
        do {
            runtimeProviders = try await api.runtimeProviders()
            runtimeModelSetupMessage = ""
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
        }
    }

    var pluginViews: [PluginView] {
        runtimePlugins.filter(\.supportsCurrentPlatform).flatMap(\.views)
    }

    func refreshPlugins() async {
        guard let api else { return }
        do {
            runtimePlugins = try await api.runtimePlugins()
            pluginSetupMessage = ""
        } catch {
            pluginSetupMessage = error.localizedDescription
        }
    }

    func refreshMarketplace() async {
        guard let api else {
            marketplaceMessage = "The Workspace server URL is invalid."
            return
        }
        isMarketplaceLoading = true
        defer { isMarketplaceLoading = false }
        do {
            marketplacePlugins = try await api.marketplacePlugins()
            marketplaceMessage = ""
        } catch {
            marketplaceMessage = error.localizedDescription
        }
    }

    func installMarketplacePlugin(_ plugin: MarketplacePlugin) async {
        await performMarketplaceOperation(plugin.id, progress: "Installing \(plugin.name)…") { api in
            try await api.installMarketplacePlugin(pluginId: plugin.id, version: plugin.version)
            return "Installed \(plugin.name) \(plugin.version) on the server."
        }
    }

    func updateMarketplacePlugin(
        _ plugin: MarketplacePlugin,
        acceptedPermissions: [String] = []
    ) async {
        await performMarketplaceOperation(plugin.id, progress: "Updating \(plugin.name)…") { api in
            try await api.updateMarketplacePlugin(
                pluginId: plugin.id,
                version: plugin.version,
                acceptedPermissions: acceptedPermissions
            )
            return "Updated \(plugin.name) to \(plugin.version) for all profiles."
        }
    }

    func rollbackMarketplacePlugin(_ plugin: MarketplacePlugin) async {
        await performMarketplaceOperation(plugin.id, progress: "Restoring \(plugin.name)…") { api in
            try await api.rollbackPlugin(pluginId: plugin.id, version: plugin.previousVersion)
            return "Restored \(plugin.name) \(plugin.previousVersion ?? "") for all profiles."
        }
    }

    func removeMarketplacePlugin(_ plugin: MarketplacePlugin) async {
        await performMarketplaceOperation(plugin.id, progress: "Removing \(plugin.name)…") { api in
            try await api.removePlugin(pluginId: plugin.id)
            return "Removed \(plugin.name) from the server for all profiles. Saved credentials and service data were not deleted."
        }
    }

    private func performMarketplaceOperation(
        _ pluginId: String,
        progress: String,
        operation: (WorkspaceAPI) async throws -> String
    ) async {
        guard let api, !marketplaceOperations.contains(pluginId) else { return }
        marketplaceOperations.insert(pluginId)
        marketplaceMessage = progress
        defer { marketplaceOperations.remove(pluginId) }
        do {
            let successMessage = try await operation(api)
            await refreshMarketplace()
            await refreshPlugins()
            await refreshMCPServers()
            marketplaceMessage = successMessage
        } catch {
            marketplaceMessage = error.localizedDescription
        }
    }

    func refreshMCPServers() async {
        guard let api else { return }
        do {
            mcpServers = try await api.mcpServers()
            if mcpServers.isEmpty {
                mcpSetupMessage = "No optional MCP servers configured."
            } else {
                mcpSetupMessage = "Loaded \(mcpServers.count) optional MCP server(s)."
            }
        } catch {
            mcpSetupMessage = error.localizedDescription
        }
    }

    func refreshSearchConfig() async {
        guard let api else { return }
        do {
            searchConfig = try await api.searchConfig()
            searchSetupMessage = "Search settings loaded."
        } catch {
            searchSetupMessage = error.localizedDescription
        }
    }

    func saveSearchConfig(
        rootsText: String,
        embeddingsProvider: String,
        openaiBaseUrl: String,
        openaiApiKey: String,
        openaiEmbedModel: String,
        openaiEmbedDim: String,
        vlmProvider: String,
        vlmModel: String,
        vlmBaseUrl: String,
        vlmApiKey: String
    ) async {
        guard let api else { return }
        let roots = rootsText
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !roots.isEmpty else {
            searchSetupMessage = "At least one indexing root is required."
            return
        }
        guard let dim = Int(openaiEmbedDim.trimmingCharacters(in: .whitespacesAndNewlines)), dim > 0 else {
            searchSetupMessage = "Embedding dimension must be a positive number."
            return
        }
        do {
            let body = SearchConfigUpdateBody(
                roots: roots,
                embeddingsProvider: embeddingsProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "openai" : embeddingsProvider.trimmingCharacters(in: .whitespacesAndNewlines),
                openaiBaseUrl: openaiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                openaiApiKey: openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                openaiEmbedModel: openaiEmbedModel.trimmingCharacters(in: .whitespacesAndNewlines),
                openaiEmbedDim: dim,
                vlmProvider: vlmProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : vlmProvider.trimmingCharacters(in: .whitespacesAndNewlines),
                vlmModel: vlmModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : vlmModel.trimmingCharacters(in: .whitespacesAndNewlines),
                vlmBaseUrl: vlmBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : vlmBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                vlmApiKey: vlmApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : vlmApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                includeGlobs: nil,
                excludeGlobs: nil,
                dbPath: nil
            )
            searchConfig = try await api.updateSearchConfig(body: body)
            searchSetupMessage = "Saved Search settings."
        } catch {
            searchSetupMessage = error.localizedDescription
        }
    }

    func saveMCPServer(name: String, transport: String, command: String, argsText: String, envText: String, scopePath: String, url: String, credentialId: String, enabled: Bool, editingExisting: Bool) async {
        guard let api else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            mcpSetupMessage = "MCP name is required."
            return
        }
        guard transport == "streamable_http" || !cleanedCommand.isEmpty else {
            mcpSetupMessage = "MCP command is required."
            return
        }
        do {
            let updatesExistingServer = editingExisting || mcpServers.contains(where: { $0.name == cleanedName })
            let body = MCPServerUpdateBody(
                name: updatesExistingServer ? nil : cleanedName,
                transport: transport,
                command: transport == "stdio" ? cleanedCommand : nil,
                args: transport == "stdio" ? splitShellLikeArgs(argsText) : nil,
                enabled: enabled,
                env: transport == "stdio" ? parseEnvLines(envText) : nil,
                scopePath: transport == "stdio" ? scopePath.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                url: transport == "streamable_http" ? url.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                credentialId: transport == "streamable_http" ? credentialId.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
                surfaces: transport == "streamable_http" ? ["chat"] : nil
            )
            if updatesExistingServer {
                _ = try await api.updateMCPServer(name: cleanedName, body: body)
            } else {
                _ = try await api.addMCPServer(body: body)
            }
            mcpSetupMessage = "Saved MCP server \(cleanedName)."
            await refreshMCPServers()
        } catch {
            mcpSetupMessage = error.localizedDescription
        }
    }

    func setMCPServerEnabled(_ server: MCPServerConfig, enabled: Bool) async {
        guard let api else { return }
        do {
            _ = try await api.setMCPServerEnabled(name: server.name, enabled: enabled)
            await refreshMCPServers()
        } catch {
            mcpSetupMessage = error.localizedDescription
        }
    }

    func deleteMCPServer(_ server: MCPServerConfig) async {
        guard let api else { return }
        do {
            try await api.deleteMCPServer(name: server.name)
            mcpSetupMessage = "Removed MCP server \(server.name)."
            await refreshMCPServers()
        } catch {
            mcpSetupMessage = error.localizedDescription
        }
    }

    func setPluginEnabled(_ plugin: RuntimePlugin, enabled: Bool) async {
        guard let api else { return }
        do {
            _ = try await api.updatePluginConfiguration(
                pluginId: plugin.id,
                body: PluginConfigurationBody(
                    enabled: enabled,
                    remove: nil
                )
            )
            await refreshPlugins()
        } catch {
            pluginSetupMessage = error.localizedDescription
        }
    }

    func pluginMCPToolConsent(for pluginId: String) -> PluginMCPToolConsent? {
        pluginMCPToolConsents[pluginId]
    }

    func loadPluginMCPToolConsent(pluginId: String) async {
        guard let api else { return }
        do {
            pluginMCPToolConsents[pluginId] = try await api.pluginMCPToolConsent(pluginId: pluginId)
        } catch {
            pluginSetupMessage = error.localizedDescription
        }
    }

    func refreshPluginMCPTools(pluginId: String) async {
        guard let api, !pluginMCPToolOperations.contains(pluginId) else { return }
        pluginMCPToolOperations.insert(pluginId)
        defer { pluginMCPToolOperations.remove(pluginId) }
        do {
            let consent = try await api.refreshPluginMCPTools(pluginId: pluginId)
            pluginMCPToolConsents[pluginId] = consent
            pluginSetupMessage = consent.pendingTools.isEmpty
                ? "MCP tools are up to date."
                : "\(consent.pendingTools.count) new MCP tool(s) are waiting for approval."
        } catch {
            pluginSetupMessage = error.localizedDescription
        }
    }

    func setPluginMCPToolApproved(pluginId: String, toolName: String, approved: Bool) async {
        guard let api, let current = pluginMCPToolConsents[pluginId] else { return }
        var names = Set(current.approvedTools)
        if approved { names.insert(toolName) } else { names.remove(toolName) }
        do {
            pluginMCPToolConsents[pluginId] = try await api.updatePluginMCPToolConsent(
                pluginId: pluginId,
                approvedTools: names.sorted()
            )
            pluginSetupMessage = approved
                ? "Approved MCP tool \(toolName)."
                : "Disabled MCP tool \(toolName)."
        } catch {
            pluginSetupMessage = error.localizedDescription
        }
    }

    func discoverRuntimeModels(providerId: String) async {
        guard let api else { return }
        do {
            let response = try await api.runtimeProviderModels(providerId: providerId)
            runtimeProviderModels[providerId] = response.models
            runtimeModelSetupMessage = response.models.isEmpty ? "No models found." : "Found \(response.models.count) model(s)."
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
        }
    }

    func saveRuntimeProviderValues(providerId: String, apiKey: String = "", baseUrl: String = "") async -> Bool {
        guard let api else { return false }
        do {
            var values: [String: String] = [:]
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values["apiKey"] = apiKey
            }
            if !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values["baseUrl"] = baseUrl
            }
            if !values.isEmpty {
                try await api.updateRuntimeProviderAuth(providerId: providerId, values: values)
                runtimeModelSetupMessage = "Provider settings saved."
                await refreshRuntimeProviders()
            }
            return true
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
            return false
        }
    }

    func refreshRuntimeProviderCredentials(providerId: String) async {
        guard let api else { return }
        do {
            let response = try await api.runtimeProviderAuth(providerId: providerId)
            runtimeProviderCredentials[providerId] = response.credentials
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
        }
    }

    func selectRuntimeProviderCredential(providerId: String, credentialId: String) async {
        guard let api else { return }
        do {
            try await api.selectRuntimeProviderCredential(providerId: providerId, credentialId: credentialId)
            runtimeModelSetupMessage = "Provider account selected."
            await refreshRuntimeProviderCredentials(providerId: providerId)
            await refreshRuntimeProviders()
            await refreshHermesMetadata()
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
        }
    }

    func deleteRuntimeProviderCredential(providerId: String, credentialId: String) async {
        guard let api else { return }
        do {
            try await api.deleteRuntimeProviderCredential(providerId: providerId, credentialId: credentialId)
            runtimeModelSetupMessage = "Provider account removed."
            await refreshRuntimeProviderCredentials(providerId: providerId)
            await refreshRuntimeProviders()
            await refreshHermesMetadata()
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
        }
    }

    func disconnectRuntimeProvider(providerId: String) async {
        guard let api else { return }
        do {
            try await api.deleteRuntimeProviderAuth(providerId: providerId)
            runtimeProviderCredentials[providerId] = []
            runtimeModelSetupMessage = "Provider disconnected."
            await refreshRuntimeProviders()
            await refreshHermesMetadata()
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
        }
    }

    func startOpenAICodexLogin() async -> RuntimeOAuthLoginSession? {
        guard let api else { return nil }
        do {
            let session = try await api.startOpenAICodexLogin()
            runtimeOAuthSessions[session.id] = session
            runtimeModelSetupMessage = "OpenAI Codex sign-in started."
            return session
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
            return nil
        }
    }

    func refreshRuntimeOAuthLogin(providerId: String, sessionId: String) async {
        guard let api else { return }
        do {
            let session = try await api.runtimeOAuthLogin(providerId: providerId, sessionId: sessionId)
            runtimeOAuthSessions[session.id] = session
            if session.status == "approved" {
                runtimeModelSetupMessage = "OpenAI Codex account connected."
                await refreshRuntimeProviderCredentials(providerId: providerId)
                await refreshRuntimeProviders()
                await refreshHermesMetadata()
            } else if let error = session.error, !error.isEmpty {
                runtimeModelSetupMessage = error
            }
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
        }
    }

    func cancelRuntimeOAuthLogin(providerId: String, sessionId: String) async {
        guard let api else { return }
        do {
            try await api.cancelRuntimeOAuthLogin(providerId: providerId, sessionId: sessionId)
            await refreshRuntimeOAuthLogin(providerId: providerId, sessionId: sessionId)
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
        }
    }

    func runtimeDefaultModel() async -> RuntimeDefaultModel? {
        guard let api else { return nil }
        do {
            return try await api.runtimeDefaultModel()
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
            return nil
        }
    }

    func saveRuntimeModelSelection(providerId: String, model: String) async -> Bool {
        guard let api else { return false }
        do {
            try await api.setRuntimeDefaultModel(provider: providerId, model: model)
            await refreshRuntimeProviders()
            await refreshHermesMetadata()
            selectedHermesModelId = "\(providerId):\(model)"
            runtimeModelSetupMessage = "Active model updated."
            return true
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
            return false
        }
    }

    func saveRuntimeModelConfiguration(providerId: String, model: String, apiKey: String, baseUrl: String) async -> Bool {
        guard let api else { return false }
        do {
            var values: [String: String] = [:]
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values["apiKey"] = apiKey
            }
            if !baseUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values["baseUrl"] = baseUrl
            }
            if !values.isEmpty {
                try await api.updateRuntimeProviderAuth(providerId: providerId, values: values)
            }
            try await api.setRuntimeDefaultModel(provider: providerId, model: model, baseUrl: baseUrl)
            await refreshRuntimeProviders()
            await refreshHermesMetadata()
            selectedHermesModelId = "\(providerId):\(model)"
            runtimeModelSetupMessage = "Active model updated."
            return true
        } catch {
            runtimeModelSetupMessage = error.localizedDescription
            return false
        }
    }

    func items(for root: String) -> [WorkspaceItem] {
        root == "code" ? code : notes
    }

    func surfaceEnabled(_ surfaceId: String) -> Bool {
        if surfaceId == "chat" { return true }
        guard !pluginViews.isEmpty else { return true }
        return pluginViews.first { $0.id == surfaceId }?.isEnabled ?? true
    }

    var enabledBuiltInPluginViews: [PluginView] {
        let primaryViewIds: Set<String> = ["chat", "notes", "code"]
        return pluginViews.filter { view in
            view.distribution == "builtin"
                && !primaryViewIds.contains(view.id)
                && view.isEnabled
        }
    }

    var enabledCommunityPluginViews: [PluginView] {
        pluginViews.filter { view in
            view.distribution == "community" && view.isEnabled
        }
    }

    func currentPath(for root: String) -> String {
        root == "code" ? codePath : notesPath
    }

    func sectionSubtitle(root: String) -> String {
        let path = currentPath(for: root)
        let rootName = root == "code" ? "Code" : "Notes"
        return path.isEmpty ? rootName : "\(rootName)/\(path)"
    }

    func selectFolder(root: String, item: WorkspaceItem?) {
        let path = item.map { nestedPath(root: root, workspacePath: $0.path) } ?? ""
        if root == "code" {
            codePath = path
        } else {
            notesPath = path
        }
    }

    func refreshTree(root: String) async {
        await loadTree(root: root, path: currentPath(for: root), showStatus: false)
    }

    private func fileOperationFailure(operation: String, message: String) -> WorkspaceFileOperationFailure {
        statusMessage = message
        return WorkspaceFileOperationFailure(title: "\(operation)할 수 없습니다", message: message)
    }

    private func duplicateFailure(operation: String, path: String, sourcePath: String? = nil, isDirectory: Bool = false, reservedPaths: Set<String> = []) -> WorkspaceFileOperationFailure {
        let url = URL(fileURLWithPath: path)
        let ext = isDirectory ? "" : url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let occupied = Set((localWorkspace?.items ?? (notes + code)).map(\.path)).union(reservedPaths)
        var number = 1
        var suggestion: String
        repeat {
            suggestion = "\(stem)(\(number))" + (ext.isEmpty ? "" : ".\(ext)")
            number += 1
        } while occupied.contains(siblingWorkspacePath(for: path, newName: suggestion))
            || localWorkspace?.entry(path: siblingWorkspacePath(for: path, newName: suggestion)) != nil
            || localWorkspace?.entry(path: siblingWorkspacePath(for: path, newName: suggestion), resource: "folder") != nil
        let failure = WorkspaceFileOperationFailure(
            title: "같은 이름의 자료가 있습니다",
            message: "\(path)\n이미 같은 이름의 파일 또는 폴더가 있습니다. 아래 이름으로 변경하여 \(operation)할까요? 기존 자료는 그대로 유지됩니다.",
            nameConflict: .init(sourcePath: sourcePath, suggestedName: suggestion)
        )
        statusMessage = failure.message
        return failure
    }

    private func fileOperationFailure(operation: String, error: Error, destination: String, sourcePath: String? = nil, isDirectory: Bool = false) -> WorkspaceFileOperationFailure {
        if let localError = error as? LocalWorkspaceError, case .exists = localError {
            return duplicateFailure(operation: operation, path: destination, sourcePath: sourcePath, isDirectory: isDirectory)
        }
        return fileOperationFailure(operation: operation, message: error.localizedDescription)
    }

    @discardableResult
    func createFolder(root: String, name: String) async -> WorkspaceFileOperationFailure? {
        guard let localWorkspace else { return fileOperationFailure(operation: "폴더를 생성", message: localStorageError) }
        let cleaned = cleanNewItemName(name)
        guard !cleaned.isEmpty else {
            return fileOperationFailure(operation: "폴더를 생성", message: "폴더 이름을 입력하세요.")
        }
        isLoading = true
        defer { isLoading = false }
        let path = workspacePathForNewItem(root: root, name: cleaned)
        do {
            try localWorkspace.createFolder(path: path)
            localChangeSaved()
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = "Created folder \(cleaned)"
            return nil
        } catch {
            return fileOperationFailure(operation: "폴더를 생성", error: error, destination: path, isDirectory: true)
        }
    }

    @discardableResult
    func createFile(root: String, name: String) async -> WorkspaceFileOperationFailure? {
        guard let localWorkspace else { return fileOperationFailure(operation: "파일을 생성", message: localStorageError) }
        let cleaned = cleanNewItemName(name)
        guard !cleaned.isEmpty else {
            return fileOperationFailure(operation: "파일을 생성", message: "파일 이름을 입력하세요.")
        }
        isLoading = true
        defer { isLoading = false }
        let finalName = defaultExtensionName(cleaned, root: root)
        let path = workspacePathForNewItem(root: root, name: finalName)
        do {
            try localWorkspace.write(path: path, data: Data(defaultFileContent(for: finalName).utf8), createOnly: true)
            localChangeSaved()
            await loadTree(root: root, path: currentPath(for: root))
            if let item = items(for: root).first(where: { $0.path == path }) {
                await loadFile(item)
            }
            statusMessage = "Created file \(finalName)"
            return nil
        } catch {
            return fileOperationFailure(operation: "파일을 생성", error: error, destination: path)
        }
    }

    @discardableResult
    func renameItem(root: String, item: WorkspaceItem, newName: String) async -> WorkspaceFileOperationFailure? {
        guard let localWorkspace else { return fileOperationFailure(operation: "이름을 변경", message: localStorageError) }
        let cleaned = cleanNewItemName(newName)
        guard !cleaned.isEmpty else {
            return fileOperationFailure(operation: "이름을 변경", message: "새 이름을 입력하세요.")
        }
        guard cleaned != item.name else { return nil }
        isLoading = true
        defer { isLoading = false }
        let destination = siblingWorkspacePath(for: item.path, newName: cleaned)
        do {
            try localWorkspace.transfer(from: item.path, to: destination, move: true)
            localChangeSaved()
            clearSelectionIfNeeded(paths: [item.path])
            await loadTree(root: root, path: currentPath(for: root))
            if !item.isDirectory, let renamed = items(for: root).first(where: { $0.path == destination }) {
                await loadFile(renamed)
            }
            statusMessage = "Renamed \(item.name) to \(cleaned)"
            return nil
        } catch {
            return fileOperationFailure(operation: "이름을 변경", error: error, destination: destination, sourcePath: item.path, isDirectory: item.isDirectory)
        }
    }

    @discardableResult
    func moveItem(root: String, item: WorkspaceItem, destinationFolder: String) async -> WorkspaceFileOperationFailure? {
        guard let localWorkspace else { return fileOperationFailure(operation: "이동", message: localStorageError) }
        let destination = workspacePath(in: root, folder: destinationFolder, name: item.name)
        guard destination != item.path else { return nil }
        isLoading = true
        defer { isLoading = false }
        do {
            try localWorkspace.transfer(from: item.path, to: destination, move: true)
            localChangeSaved()
            clearSelectionIfNeeded(paths: [item.path])
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = "Moved \(item.name)"
            return nil
        } catch {
            return fileOperationFailure(operation: "이동", error: error, destination: destination)
        }
    }

    @discardableResult
    func copyItem(root: String, item: WorkspaceItem, destinationFolder: String) async -> WorkspaceFileOperationFailure? {
        return await copyItems(root: root, items: [item], destinationFolder: destinationFolder)
    }

    @discardableResult
    func copyItems(root: String, items: [WorkspaceItem], destinationFolder: String, replacementNames: [String: String] = [:]) async -> WorkspaceFileOperationFailure? {
        guard let localWorkspace else { return fileOperationFailure(operation: "복사", message: localStorageError) }
        let items = topLevelWorkspaceItems(items)
        guard !items.isEmpty else { return nil }
        let names = items.map { cleanNewItemName(replacementNames[$0.path] ?? $0.name) }
        guard !names.contains("") else { return fileOperationFailure(operation: "복사", message: "새 이름을 입력하세요.") }
        let destinations = names.map { workspacePath(in: root, folder: destinationFolder, name: $0) }
        let existingPaths = Set(localWorkspace.items.map(\.path))
        var reserved = existingPaths
        for (item, destination) in zip(items, destinations) {
            if !reserved.insert(destination).inserted {
                return duplicateFailure(operation: "복사", path: destination, sourcePath: item.path, isDirectory: item.isDirectory, reservedPaths: Set(destinations))
            }
        }
        isLoading = true
        defer { isLoading = false }
        var activeTransfer: (WorkspaceItem, String)?
        do {
            for (item, destination) in zip(items, destinations) {
                activeTransfer = (item, destination)
                try localWorkspace.transfer(from: item.path, to: destination, move: false)
            }
            localChangeSaved()
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = items.count == 1 ? "Copied \(items[0].name)" : "Copied \(items.count) items"
            return nil
        } catch {
            await loadTree(root: root, path: currentPath(for: root))
            return fileOperationFailure(operation: "복사", error: error, destination: activeTransfer?.1 ?? "", sourcePath: activeTransfer?.0.path, isDirectory: activeTransfer?.0.isDirectory ?? false)
        }
    }

    @discardableResult
    func moveTreeItem(root: String, sourcePath: String, into folder: WorkspaceItem?) async -> WorkspaceFileOperationFailure? {
        return await moveTreeItems(root: root, sourcePaths: [sourcePath], into: folder)
    }

    @discardableResult
    func moveTreeItems(root: String, sourcePaths: [String], into folder: WorkspaceItem?, replacementNames: [String: String] = [:]) async -> WorkspaceFileOperationFailure? {
        guard let localWorkspace else { return fileOperationFailure(operation: "이동", message: localStorageError) }
        let sourcePathSet = Set(sourcePaths)
        let draggedItems = topLevelWorkspaceItems(items(for: root).filter { sourcePathSet.contains($0.path) })
        guard !draggedItems.isEmpty else {
            return fileOperationFailure(operation: "이동", message: "이동하려는 항목이 더 이상 존재하지 않습니다.")
        }
        if let folder {
            guard folder.isDirectory else { return fileOperationFailure(operation: "이동", message: "대상 폴더를 선택하세요.") }
            guard !draggedItems.contains(where: {
                folder.path == $0.path || folder.path.hasPrefix($0.path + "/")
            }) else {
                return fileOperationFailure(operation: "이동", message: "폴더를 자기 자신이나 하위 폴더로 이동할 수 없습니다.")
            }
        }
        let destinationFolder = folder.map { nestedPath(root: root, workspacePath: $0.path) } ?? ""
        let names = draggedItems.map { cleanNewItemName(replacementNames[$0.path] ?? $0.name) }
        guard !names.contains("") else { return fileOperationFailure(operation: "이동", message: "새 이름을 입력하세요.") }
        let destinations = names.map { workspacePath(in: root, folder: destinationFolder, name: $0) }
        // Keep other selected sources occupied too: renaming one onto another
        // source must never overwrite it or depend on the transfer order.
        let existingPaths = Set(localWorkspace.items.map(\.path))
        var reserved: Set<String> = []
        for (item, destination) in zip(draggedItems, destinations) {
            if (destination != item.path && existingPaths.contains(destination)) || !reserved.insert(destination).inserted {
                return duplicateFailure(operation: "이동", path: destination, sourcePath: item.path, isDirectory: item.isDirectory, reservedPaths: Set(destinations))
            }
        }
        let moves = Array(zip(draggedItems, destinations).filter { $0.0.path != $0.1 })
        guard !moves.isEmpty else { return nil }
        isLoading = true
        defer { isLoading = false }
        var activeTransfer: (WorkspaceItem, String)?
        do {
            for (item, destination) in moves {
                activeTransfer = (item, destination)
                try localWorkspace.transfer(from: item.path, to: destination, move: true)
            }
            localChangeSaved()
            clearSelectionIfNeeded(paths: draggedItems.map(\.path))
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = draggedItems.count == 1
                ? "Moved \(draggedItems[0].name)"
                : "Moved \(draggedItems.count) items"
            return nil
        } catch {
            await loadTree(root: root, path: currentPath(for: root))
            return fileOperationFailure(operation: "이동", error: error, destination: activeTransfer?.1 ?? "", sourcePath: activeTransfer?.0.path, isDirectory: activeTransfer?.0.isDirectory ?? false)
        }
    }

    func uploadLocalFile(root: String, fileURL: URL) async {
        guard let localWorkspace else { statusMessage = localStorageError; return }
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        let destination = workspacePathForNewItem(root: root, name: fileURL.lastPathComponent)
        let uploadId = UUID()
        addUploadItem(id: uploadId, root: root, fileURL: fileURL, destination: destination)
        do {
            updateUploadItem(uploadId, status: .reading, progress: 0, message: "Preparing file")
            let totalBytes = try localFileSize(fileURL)
            updateUploadItem(uploadId, totalBytes: totalBytes)
            try localWorkspace.importFile(path: destination, file: fileURL)
            localChangeSaved()
            updateUploadItem(uploadId, status: .completed, progress: 1, bytesSent: totalBytes, message: "로컬에 저장됨 · 연결 시 동기화")
            await loadTree(root: root, path: currentPath(for: root))
            if let item = items(for: root).first(where: { $0.path == destination }) {
                await loadFile(item)
            }
            statusMessage = "Attached \(fileURL.lastPathComponent)"
        } catch {
            updateUploadItem(uploadId, status: .failed, message: uploadErrorMessage(error))
            statusMessage = error.localizedDescription
        }
    }

    func uploadLocalFiles(root: String, fileURLs: [URL]) async {
        for fileURL in fileURLs {
            await uploadLocalFile(root: root, fileURL: fileURL)
        }
    }

    func importLocalFiles(root: String, fileURLs: [URL]) async {
        let packages = fileURLs.filter { $0.pathExtension.lowercased() == "codmespdf" }
        for packageURL in packages {
            await importCodmesPDFPackage(root: root, fileURL: packageURL)
        }

        let regularFiles = fileURLs.filter { $0.pathExtension.lowercased() != "codmespdf" }
        let hasLegacyState = regularFiles.contains { $0.lastPathComponent.lowercased().hasSuffix(".codmes.json") }
        let hasLegacyPDF = regularFiles.contains { $0.pathExtension.lowercased() == "pdf" }
        if hasLegacyState && hasLegacyPDF {
            await importLegacyCodmesPDF(root: root, fileURLs: regularFiles)
        } else {
            await uploadLocalFiles(root: root, fileURLs: regularFiles)
        }
    }

    private func importCodmesPDFPackage(root: String, fileURL: URL) async {
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { fileURL.stopAccessingSecurityScopedResource() }
        }
        let baseName = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let pdfName = "\(baseName.isEmpty ? "document" : baseName).pdf"
        let destination = availableLocalPath(workspacePathForNewItem(root: root, name: pdfName))
        let uploadId = UUID()
        addUploadItem(id: uploadId, root: root, fileURL: fileURL, destination: destination)
        do {
            updateUploadItem(uploadId, status: .reading, progress: 0.1, message: "Reading editable Codmes PDF")
            let packageData = try await Task.detached { try Data(contentsOf: fileURL) }.value
            let totalBytes = Int64(packageData.count)
            updateUploadItem(uploadId, status: .uploading, progress: 0.45, bytesSent: totalBytes, totalBytes: totalBytes, message: "Restoring PDF and annotations")
            let contents = try await Task.detached { try CodmesPDFArchive.read(packageData) }.value
            try saveLocalPDF(path: destination, pdf: contents.pdf, annotations: contents.annotations, createOnly: true)
            updateUploadItem(uploadId, status: .completed, progress: 1, bytesSent: totalBytes, totalBytes: totalBytes, message: "로컬에 PDF와 필기 저장됨")
            await loadTree(root: root, path: currentPath(for: root))
            if let item = items(for: root).first(where: { $0.path == destination }) {
                await loadFile(item)
            }
            statusMessage = "로컬에 PDF와 필기를 복원했습니다."
        } catch {
            updateUploadItem(uploadId, status: .failed, message: uploadErrorMessage(error))
            statusMessage = error.localizedDescription
        }
    }

    private func importLegacyCodmesPDF(root: String, fileURLs: [URL]) async {
        let scoped = fileURLs.map { url in
            (url, url.startAccessingSecurityScopedResource())
        }
        defer {
            for (url, didAccess) in scoped where didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let pdfURL = fileURLs.first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
            statusMessage = "Select a PDF file."
            return
        }
        let stateURL = fileURLs.first(where: { $0.lastPathComponent.lowercased().hasSuffix(".codmes.json") })
        let destination = availableLocalPath(workspacePathForNewItem(root: root, name: pdfURL.lastPathComponent))
        let uploadId = UUID()
        addUploadItem(id: uploadId, root: root, fileURL: pdfURL, destination: destination)
        do {
            updateUploadItem(uploadId, status: .reading, progress: 0.1, message: "Reading Codmes package")
            let pdfData = try Data(contentsOf: pdfURL)
            let stateData = try stateURL.map { try Data(contentsOf: $0) }
            updateUploadItem(uploadId, status: .uploading, progress: 0.45, bytesSent: Int64(pdfData.count), totalBytes: Int64(pdfData.count), message: "Importing")
            guard pdfData.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { throw CocoaError(.fileReadCorruptFile) }
            let annotations = try stateData.map { try JSONDecoder().decode(PDFAnnotationDocument.self, from: $0) }
                ?? PDFAnnotationDocument(schemaVersion: 2, documentPath: destination, updatedAt: nil, pages: [], objects: [])
            try saveLocalPDF(path: destination, pdf: pdfData, annotations: annotations, createOnly: true)
            updateUploadItem(uploadId, status: .completed, progress: 1, bytesSent: Int64(pdfData.count), totalBytes: Int64(pdfData.count), message: "로컬에 PDF와 필기 저장됨")
            await loadTree(root: root, path: currentPath(for: root))
            if let item = items(for: root).first(where: { $0.path == destination }) {
                await loadFile(item)
            }
            statusMessage = "로컬에 PDF와 필기를 복원했습니다."
        } catch {
            updateUploadItem(uploadId, status: .failed, message: uploadErrorMessage(error))
            statusMessage = error.localizedDescription
        }
    }

    func clearFinishedUploads(root: String? = nil) {
        uploadItems.removeAll {
            (root == nil || $0.root == root) && !$0.isActive
        }
    }

    func uploads(for root: String) -> [UploadItem] {
        uploadItems.filter { $0.root == root }
    }

    var currentCodeScopePath: String {
        codePath.isEmpty ? "Code" : "Code/\(codePath)"
    }

    func refreshApprovals() async {
        guard let api else { return }
        isLoadingApprovals = true
        defer { isLoadingApprovals = false }
        do {
            approvals = try await api.approvals(status: "pending", limit: 60)
        } catch {
            statusMessage = "Approvals error: \(error.localizedDescription)"
        }
    }

    func respondToWorkspaceApproval(id: String, approved: Bool, runChecksAfterApply: Bool = false, reason: String? = nil) async {
        guard let api else { return }
        isLoadingApprovals = true
        defer { isLoadingApprovals = false }
        do {
            _ = try await api.respondToApproval(
                id: id,
                approved: approved,
                runChecksAfterApply: runChecksAfterApply,
                checksApproved: runChecksAfterApply,
                reason: reason
            )
            statusMessage = approved ? "Approval submitted" : "Rejection submitted"
            await refreshApprovals()
            await refreshAgentTasks()
            await refreshCodeTasks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshAgentTasks() async {
        guard let api else { return }
        do {
            agentTasks = try await api.agentTasks(type: nil, limit: 80)
        } catch {
            statusMessage = "Tasks error: \(error.localizedDescription)"
        }
    }

    func resumeAgentTask(_ task: AgentTaskSummary) async {
        guard let api else { return }
        do {
            _ = try await api.resumeAgentTask(id: task.id)
            statusMessage = "Task resumed"
            await refreshApprovals()
            await refreshAgentTasks()
            await refreshCodeTasks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func cancelAgentTask(_ task: AgentTaskSummary, reason: String? = nil) async {
        guard let api else { return }
        do {
            _ = try await api.cancelAgentTask(id: task.id, reason: reason ?? "Cancelled in Apple client.")
            statusMessage = "Task cancelled"
            await refreshApprovals()
            await refreshAgentTasks()
            await refreshCodeTasks()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadApprovalDiff(diffRef: String) async {
        guard let api, !diffRef.isEmpty else {
            selectedApprovalDiffText = ""
            return
        }
        do {
            selectedApprovalDiffText = try await api.file(path: diffRef).content
        } catch {
            selectedApprovalDiffText = "Failed to load diff content: \(error.localizedDescription)"
        }
    }

    func refreshCodeTasks(selectLatest: Bool = false) async {
        guard let api else { return }
        isLoadingCodeTask = true
        defer { isLoadingCodeTask = false }
        do {
            codeTasks = try await api.agentTasks(type: "code", limit: 60)
            if selectLatest, let first = codeTasks.first {
                await loadCodeTask(first)
            } else if let selectedCodeTask,
                      let summary = codeTasks.first(where: { $0.id == selectedCodeTask.id }) {
                await loadCodeTask(summary)
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createCodeInspectTask() async {
        guard let api else { return }
        let instruction = codeTaskInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else {
            statusMessage = "Describe the code task first"
            return
        }
        isLoadingCodeTask = true
        defer { isLoadingCodeTask = false }
        do {
            let response = try await api.createCodeTask(scopePath: currentCodeScopePath, instruction: instruction)
            codeTaskInstruction = ""
            statusMessage = "Code task prepared"
            codeTasks = try await api.agentTasks(type: "code", limit: 60)
            if let summary = codeTasks.first(where: { $0.id == response.taskId }) {
                await loadCodeTask(summary)
            } else {
                selectedCodeTask = try await api.agentTask(id: response.taskId)
                await loadSelectedCodeTaskDiff()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadCodeTask(_ summary: AgentTaskSummary) async {
        guard let api else { return }
        isLoadingCodeTask = true
        defer { isLoadingCodeTask = false }
        do {
            selectedCodeTask = try await api.agentTask(id: summary.id)
            await loadSelectedCodeTaskDiff()
            statusMessage = "Loaded code task"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applyCodePatch(_ proposal: CodePatchProposal, runChecksAfterApply: Bool = false) async {
        guard let api, let selectedCodeTask else { return }
        isLoadingCodeTask = true
        defer { isLoadingCodeTask = false }
        do {
            let response = try await api.applyCodePatch(
                taskId: selectedCodeTask.id,
                proposalId: proposal.id,
                runChecksAfterApply: runChecksAfterApply
            )
            self.selectedCodeTask = try await api.agentTask(id: selectedCodeTask.id)
            await loadSelectedCodeTaskDiff()
            await refreshTree(root: "code")
            statusMessage = response.checkRun == nil ? "Patch applied" : "Patch applied and checks finished"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func rejectCodePatch(_ proposal: CodePatchProposal) async {
        guard let api, let selectedCodeTask else { return }
        isLoadingCodeTask = true
        defer { isLoadingCodeTask = false }
        do {
            _ = try await api.rejectCodePatch(taskId: selectedCodeTask.id, proposalId: proposal.id)
            self.selectedCodeTask = try await api.agentTask(id: selectedCodeTask.id)
            await loadSelectedCodeTaskDiff()
            statusMessage = "Patch rejected"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func runSelectedCodeTaskChecks() async {
        guard let api, let selectedCodeTask else { return }
        isLoadingCodeTask = true
        defer { isLoadingCodeTask = false }
        do {
            _ = try await api.runCodeChecks(taskId: selectedCodeTask.id)
            self.selectedCodeTask = try await api.agentTask(id: selectedCodeTask.id)
            await loadSelectedCodeTaskDiff()
            statusMessage = "Checks finished"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loadSelectedCodeTaskDiff() async {
        let proposalDiffRef = selectedCodeTask?.patchProposals?
            .reversed()
            .first(where: { $0.status == "proposed" || $0.status == "applied" })?
            .diffRef
        let diffRef = proposalDiffRef ?? selectedCodeTask?.git?.diffRef
        guard let api, let diffRef, !diffRef.isEmpty else {
            selectedCodeTaskDiff = ""
            return
        }
        do {
            selectedCodeTaskDiff = try await api.file(path: diffRef).content
        } catch {
            selectedCodeTaskDiff = ""
        }
    }

    private func addUploadItem(id: UUID, root: String, fileURL: URL, destination: String) {
        uploadItems.insert(UploadItem(
            id: id,
            root: root,
            fileName: fileURL.lastPathComponent,
            destinationPath: destination,
            status: .reading,
            progress: 0,
            bytesSent: 0,
            totalBytes: 0,
            message: "Queued"
        ), at: 0)
        uploadItems = Array(uploadItems.prefix(12))
    }

    private func updateUploadItem(
        _ id: UUID,
        status: UploadStatus? = nil,
        progress: Double? = nil,
        bytesSent: Int64? = nil,
        totalBytes: Int64? = nil,
        message: String? = nil
    ) {
        guard let index = uploadItems.firstIndex(where: { $0.id == id }) else { return }
        if let status { uploadItems[index].status = status }
        if let progress { uploadItems[index].progress = min(max(progress, 0), 1) }
        if let bytesSent { uploadItems[index].bytesSent = bytesSent }
        if let totalBytes { uploadItems[index].totalBytes = totalBytes }
        if let message { uploadItems[index].message = message }
    }

    private func uploadChunked(api: WorkspaceAPI, uploadItemId: UUID, sourceURL: URL, destination: String, totalBytes: Int64) async throws {
        updateUploadItem(uploadItemId, status: .uploading, progress: 0, bytesSent: 0, totalBytes: totalBytes, message: "Starting large upload")
        let start = try await api.startChunkedUpload(path: destination, size: totalBytes)
        var shouldCancelRemoteUpload = true
        do {
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer {
                try? handle.close()
            }
            var offset: Int64 = 0
            while offset < totalBytes {
                try Task.checkCancellation()
                guard let chunk = try handle.read(upToCount: uploadChunkSize), !chunk.isEmpty else {
                    break
                }
                let response = try await api.uploadChunk(uploadId: start.uploadId, offset: offset, data: chunk)
                offset = response.received
                let progress = totalBytes > 0 ? Double(offset) / Double(totalBytes) : 1
                updateUploadItem(uploadItemId, status: .uploading, progress: progress, bytesSent: offset, message: "Uploading \(formatBytes(offset)) of \(formatBytes(totalBytes))")
            }
            try await api.completeChunkedUpload(uploadId: start.uploadId)
            shouldCancelRemoteUpload = false
            updateUploadItem(uploadItemId, status: .completed, progress: 1, bytesSent: totalBytes, message: "Uploaded")
        } catch {
            if shouldCancelRemoteUpload {
                try? await api.cancelChunkedUpload(uploadId: start.uploadId)
            }
            throw error
        }
    }

    private func localFileSize(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        if let fileSize = values.fileSize {
            return Int64(fileSize)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func uploadErrorMessage(_ error: Error) -> String {
        if case let WorkspaceAPIError.badStatus(status, _) = error, status == 409 {
            return "A file with this name already exists."
        }
        return error.localizedDescription
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    func deleteItem(root: String, item: WorkspaceItem) async {
        await deleteItems(root: root, items: [item])
    }

    func deleteItems(root: String, items: [WorkspaceItem]) async {
        guard let localWorkspace else { statusMessage = localStorageError; return }
        let items = topLevelWorkspaceItems(items)
        guard !items.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            for item in items {
                try localWorkspace.delete(path: item.path)
            }
            localChangeSaved()
            clearSelectionIfNeeded(paths: items.map(\.path))
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = items.count == 1 ? "Deleted \(items[0].name)" : "Deleted \(items.count) items"
        } catch {
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = error.localizedDescription
        }
    }

    func fileSurfaceState(for surface: String?) -> WorkspaceFileSurfaceState {
        if surface == nil || surface == activeFileSurface {
            return captureFileSurface()
        }
        return savedFileSurfaces[surface ?? ""] ?? WorkspaceFileSurfaceState()
    }

    private func captureFileSurface() -> WorkspaceFileSurfaceState {
        WorkspaceFileSurfaceState(file: selectedFile, rawFile: selectedRawFile,
            loadingFile: loadingRawFile, loadError: rawFileLoadError, focus: selectedPDFFocus,
            editorText: editorText, isEditing: isEditingFile, history: editorHistory,
            reloadItem: activeFileLoadItem ?? pendingFileSurfaceRestore,
            wasLocal: selectedResourcePath.map { localWorkspace?.entry(path: $0) != nil } ?? false)
    }

    private func fileSurface(for path: String?) -> String? {
        guard let path else { return nil }
        if path.hasPrefix("Notes/") { return "notes" }
        if path.hasPrefix("Code/") { return "code" }
        return nil
    }

    /// Keep one independent work session per file surface. Navigation only
    /// swaps the active bindings; the inactive preview remains mounted.
    @discardableResult
    func prepareForFileSurface(_ surface: String) -> Bool {
        guard surface == "notes" || surface == "code" else { return true }
        let previous = activeFileSurface ?? fileSurface(for: activeFileLoadPath ?? selectedResourcePath ?? loadingRawFile?.path)
        if previous == surface {
            activeFileSurface = surface
            retainedFileSurfaces.insert(surface)
            return true
        }
        guard persistEditorText() else { return false }
        if let previous { savedFileSurfaces[previous] = captureFileSurface() }
        let wasLoadingFile = activeFileLoadID != nil || loadingRawFile != nil
        activeFileLoadID = nil
        activeFileLoadPath = nil
        activeFileLoadItem = nil
        activeFileSurface = surface
        retainedFileSurfaces.insert(surface)
        var state = savedFileSurfaces[surface] ?? WorkspaceFileSurfaceState()
        if let path = state.file?.path ?? state.rawFile?.path ?? state.reloadItem?.path {
            if state.wasLocal, let localWorkspace, localWorkspace.entry(path: path) == nil,
               state.reloadItem == nil {
                state = WorkspaceFileSurfaceState()
                savedFileSurfaces[surface] = state
            } else if let raw = state.rawFile, !FileManager.default.fileExists(atPath: raw.url.path) {
                state.reloadItem = workspaceItem(for: state)
                state.rawFile = nil
            }
        }
        restoringFileSurface = true
        selectedFile = state.file
        selectedRawFile = state.rawFile
        loadingRawFile = state.reloadItem ?? state.loadingFile
        rawFileLoadError = state.loadError
        selectedPDFFocus = state.focus
        editorText = state.editorText
        isEditingFile = state.isEditing
        editorHistory = state.history
        restoringFileSurface = false
        pendingFileSurfaceRestore = state.reloadItem
        updateRetainedOpenFiles()
        activePDFStatusPath = ""
        activePDFStatusText = ""
        editorAutosaveError = ""
        if wasLoadingFile { isLoading = false }
        fileSurfaceRestoreID = UUID()
        return true
    }

    private func workspaceItem(for state: WorkspaceFileSurfaceState) -> WorkspaceItem? {
        let path = state.rawFile?.path ?? state.file?.path ?? state.loadingFile?.path
        if let path, let item = localWorkspace?.items.first(where: { $0.path == path }) { return item }
        if let raw = state.rawFile { return WorkspaceItem(name: raw.name, path: raw.path, kind: raw.kind, isDirectory: false, size: 0, modifiedAt: "") }
        return state.loadingFile ?? state.reloadItem
    }

    func restoreFileSurfaceIfNeeded(_ surface: String) async {
        guard activeFileSurface == surface, let item = pendingFileSurfaceRestore else { return }
        pendingFileSurfaceRestore = nil
        await loadFile(item)
    }

    func pdfFocus(for path: String) -> PDFDocumentFocus? {
        guard let surface = fileSurface(for: path) else { return nil }
        let focus = fileSurfaceState(for: surface).focus
        return focus?.path == path ? focus : nil
    }

    func pdfReadingState(for path: String) -> PDFReadingState? { pdfReadingStates[path] }

    func savePDFReadingState(_ state: PDFReadingState, path: String, scope: String) {
        guard scope == profileStorageScope else { return }
        pdfReadingStates[path] = state
    }

    /// UIKit memory warnings evict only inactive heavy previews, not files,
    /// annotations, editor buffers, or lightweight PDF position bookmarks.
    func releaseInactiveFileSurfaces() {
        for surface in retainedFileSurfaces where surface != activeFileSurface {
            guard var state = savedFileSurfaces[surface] else { continue }
            if state.rawFile != nil {
                state.reloadItem = workspaceItem(for: state)
                state.rawFile = nil
            }
            savedFileSurfaces[surface] = state
        }
        retainedFileSurfaces = activeFileSurface.map { [$0] } ?? []
        rawFileCache = rawFileCache.filter { fileSurface(for: $0.key) == activeFileSurface }
        updateRetainedOpenFiles()
    }

    private func updateRetainedOpenFiles() {
        localWorkspace?.setRetainedOpenFiles(savedFileSurfaces.values.compactMap { $0.rawFile?.url })
    }

    func loadFile(_ item: WorkspaceItem) async {
        guard !item.isDirectory else { return }
        if let surface = fileSurface(for: item.path), activeFileSurface != surface {
            guard prepareForFileSurface(surface) else { return }
        }
        guard persistEditorText() else { return }
        if storageMode(path: item.path) == .local, localWorkspace?.url(path: item.path) == nil { statusMessage = LocalWorkspaceError.missing.localizedDescription; return }
        // Allocate the request before the first await, including on-demand
        // downloads, so navigation can invalidate every kind of file load.
        let loadID = UUID()
        activeFileLoadID = loadID
        activeFileLoadPath = item.path
        activeFileLoadItem = item
        var showsLoading = false
        defer {
            if activeFileLoadID == loadID {
                activeFileLoadID = nil
                activeFileLoadPath = nil
                activeFileLoadItem = nil
                if showsLoading { isLoading = false }
            }
        }
        if let localWorkspace, localWorkspace.url(path: item.path) == nil,
           localWorkspace.entry(path: item.path) != nil, storageMode(path: item.path) != .server || item.kind != "pdf",
           isWorkspaceConnected, let api {
            do { try await localWorkspace.downloadOnDemand(path: item.path, using: api) }
            catch {
                guard activeFileLoadID == loadID else { return }
                statusMessage = error.localizedDescription
                return
            }
        }
        guard activeFileLoadID == loadID else { return }
        if let localWorkspace, let entry = localWorkspace.entry(path: item.path), let url = localWorkspace.url(path: item.path) {
            loadingRawFile = nil
            rawFileLoadError = nil
            isEditingFile = false
            selectedPDFFocus = nil
            if ["pdf", "image", "spreadsheet", "document"].contains(entry.kind) {
                selectedRawFile = RawFilePreview(path: entry.path, name: item.name, kind: entry.kind, url: url)
                selectedFile = nil
                editorText = ""
            } else {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    selectedFile = FileResponse(path: entry.path, name: item.name, kind: entry.kind, size: entry.size, modifiedAt: entry.modifiedAt, content: content)
                    selectedRawFile = nil
                    editorText = content
                } catch { statusMessage = error.localizedDescription; return }
            }
            statusMessage = "로컬에서 열었음 · \(item.name)"
            return
        }
        guard isWorkspaceConnected, let api else { statusMessage = "아직 다운로드하지 않은 자료입니다. 서버 연결 후 동기화하세요."; return }

        let cacheScope = profileStorageScope
        showsLoading = true
        isLoading = true
        rawFileLoadError = nil

        if item.kind == "pdf" {
            loadingRawFile = item
            selectedFile = nil
            selectedRawFile = nil
            editorText = ""
            isEditingFile = false
        } else {
            loadingRawFile = nil
        }

        do {
            if selectedPDFFocus?.path != item.path {
                selectedPDFFocus = nil
            }
            if item.kind == "pdf" {
                let signature = "\(item.size):\(item.modifiedAt)"
                let preview: RawFilePreview
                if let cached = rawFileCache[item.path],
                   cached.signature == signature,
                   FileManager.default.fileExists(atPath: cached.preview.url.path) {
                    preview = cached.preview
                } else if let cached = await fileDiskCache.cachedURL(for: item, scope: cacheScope) {
                    preview = RawFilePreview(path: item.path, name: item.name, kind: item.kind, url: cached)
                } else {
                    async let metadataRequest = api.pdfMetadata(path: item.path)
                    async let skeletonRequest = api.downloadPDFSkeleton(path: item.path, name: item.name)
                    let (metadata, skeletonURL) = try await (metadataRequest, skeletonRequest)
                    guard activeFileLoadID == loadID else { return }
                    let cache = fileDiskCache
                    let limitBytes = localFileCacheLimitBytes
                    guard let session = StreamedPDFSession(
                        path: item.path,
                        name: item.name,
                        metadata: metadata,
                        skeletonURL: skeletonURL,
                        api: api,
                        cachedPageLoader: { pageIndex in
                            await cache.cachedURL(for: Self.streamedPDFPageItem(source: item, pageIndex: pageIndex), scope: cacheScope)
                        },
                        pageCacheWriter: { temporaryURL, pageIndex in
                            try await cache.storeDownloadedFile(
                                temporaryURL,
                                for: Self.streamedPDFPageItem(source: item, pageIndex: pageIndex),
                                limitBytes: limitBytes,
                                scope: cacheScope
                            )
                        }
                    ) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    let initialPageIndex = max(0, (selectedPDFFocus?.page ?? 1) - 1)
                    await session.preparePage(initialPageIndex)
                    session.requestPages(around: initialPageIndex)
                    preview = RawFilePreview(
                        path: item.path,
                        name: item.name,
                        kind: item.kind,
                        url: skeletonURL,
                        streamSession: session
                    )
                }
                guard activeFileLoadID == loadID else { return }
                if let previous = rawFileCache[item.path], previous.preview.url != preview.url {
                    try? FileManager.default.removeItem(at: previous.preview.url)
                }
                rawFileCache[item.path] = (signature, preview)
                selectedRawFile = preview
                selectedFile = nil
                editorText = ""
            } else if ["image", "spreadsheet", "document"].contains(item.kind) {
                let url: URL
                if let cached = await fileDiskCache.cachedURL(for: item, scope: cacheScope) {
                    url = cached
                } else {
                    let downloaded = try await api.downloadRawFile(path: item.path, name: item.name)
                    url = try await fileDiskCache.storeDownloadedFile(
                        downloaded,
                        for: item,
                        limitBytes: localFileCacheLimitBytes,
                        scope: cacheScope
                    )
                }
                guard activeFileLoadID == loadID else { return }
                selectedRawFile = RawFilePreview(path: item.path, name: item.name, kind: item.kind, url: url)
                selectedFile = nil
                editorText = ""
            } else {
                let file: FileResponse
                if let cachedURL = await fileDiskCache.cachedURL(for: item, scope: cacheScope),
                   let content = try? String(contentsOf: cachedURL, encoding: .utf8) {
                    file = FileResponse(
                        path: item.path,
                        name: item.name,
                        kind: item.kind,
                        size: item.size,
                        modifiedAt: item.modifiedAt,
                        content: content
                    )
                } else {
                    file = try await api.file(path: item.path)
                    _ = try await fileDiskCache.store(
                        Data(file.content.utf8),
                        for: WorkspaceItem(
                            name: file.name,
                            path: file.path,
                            kind: file.kind,
                            isDirectory: false,
                            size: file.size,
                            modifiedAt: file.modifiedAt
                        ),
                        limitBytes: localFileCacheLimitBytes,
                        scope: cacheScope
                    )
                }
                guard activeFileLoadID == loadID else { return }
                selectedFile = file
                selectedRawFile = nil
                editorText = selectedFile?.content ?? ""
            }
            loadingRawFile = nil
            rawFileLoadError = nil
            isEditingFile = false
            statusMessage = "Opened \(item.name)"
        } catch {
            guard activeFileLoadID == loadID else { return }
            if item.kind == "pdf" {
                rawFileLoadError = error.localizedDescription
            } else {
                loadingRawFile = nil
            }
            statusMessage = error.localizedDescription
        }
    }

    func openSearchResult(_ result: SearchResponse.Result) async {
        let item = WorkspaceItem(
            name: URL(fileURLWithPath: result.path).lastPathComponent,
            path: result.path,
            kind: result.kind,
            isDirectory: false,
            size: result.size,
            modifiedAt: result.modifiedAt
        )
        if result.kind == "pdf" {
            selectedPDFFocus = PDFDocumentFocus(path: result.path, page: result.page, bbox: result.bbox)
        }
        await loadFile(item)
        if result.kind == "pdf", selectedRawFile?.path == result.path {
            selectedPDFFocus = PDFDocumentFocus(path: result.path, page: result.page, bbox: result.bbox)
        }
    }

    func openGlobalSearchResult(_ result: GlobalSearchResult) async {
        if let path = result.target.path {
            let kind = WorkspaceStore.kindForSearchPath(path, fallback: result.kind)
            let item = WorkspaceItem(
                name: URL(fileURLWithPath: path).lastPathComponent,
                path: path,
                kind: kind,
                isDirectory: false,
                size: 0,
                modifiedAt: result.updatedAt ?? ""
            )
            if kind == "pdf" {
                selectedPDFFocus = PDFDocumentFocus(path: path, page: result.target.page, bbox: result.target.bbox)
            }
            await loadFile(item)
            if kind == "pdf", selectedRawFile?.path == path {
                selectedPDFFocus = PDFDocumentFocus(path: path, page: result.target.page, bbox: result.target.bbox)
            }
            return
        }
        if let sessionId = result.target.sessionId {
            await resumeHermesSession(
                HermesSessionSummary(
                    id: sessionId,
                    title: result.title,
                    updatedAt: result.updatedAt,
                    provider: nil,
                    model: nil,
                    folderId: nil,
                    folderTitle: nil,
                    projectId: result.target.projectId,
                    projectTitle: nil,
                    pinned: false,
                    storageBytes: 0
                )
            )
            if let messageId = result.target.messageId {
                statusMessage = "Opened \(result.title) near message \(messageId)"
            }
        }
    }

    private static func kindForSearchPath(_ path: String, fallback: String) -> String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if ext == "pdf" { return "pdf" }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp"].contains(ext) { return "image" }
        if ["md", "markdown"].contains(ext) { return "markdown" }
        if ["swift", "js", "jsx", "ts", "tsx", "py", "go", "rs", "java", "c", "cc", "cpp", "h", "hpp", "html", "css", "sh"].contains(ext) {
            return "code"
        }
        if fallback.contains("pdf") { return "pdf" }
        return "file"
    }

    var selectedFileIsDirty: Bool {
        guard let selectedFile else { return false }
        return editorText != selectedFile.content
    }

    var selectedFileCanEdit: Bool {
        guard let kind = selectedFile?.kind else { return false }
        return ["markdown", "code", "file"].contains(kind)
    }

    func startEditingSelectedFile() {
        guard selectedFileCanEdit else { return }
        editorText = selectedFile?.content ?? ""
        isEditingFile = true
        editorAutosaveError = ""
    }

    func finishEditingSelectedFile() {
        guard persistEditorText() else { return }
        isEditingFile = false
    }

    private func scheduleEditorAutosave() {
        editorAutosaveTask?.cancel()
        guard selectedFileIsDirty else { localWorkspace?.setEditingPath(nil); return }
        guard let path = selectedFile?.path else { return }
        let scope = localScope
        editorAutosaveError = ""
        localWorkspace?.setEditingPath(path)
        editorAutosaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, isEditingFile, selectedFile?.path == path, localScope == scope else { return }
            _ = persistEditorText()
        }
    }

    /// Flush the debounced local save synchronously before navigation/background/normal quit.
    /// No cache or server is required to save; upload is a separate debounced operation.
    @discardableResult
    func persistEditorText() -> Bool {
        editorAutosaveTask?.cancel()
        guard isEditingFile, let selectedFile, selectedFileCanEdit, selectedFileIsDirty else { return true }
        guard let localWorkspace else { editorAutosaveError = "로컬 저장소를 사용할 수 없습니다."; statusMessage = "자동 저장 실패 · \(editorAutosaveError)"; return false }
        do {
            try localWorkspace.write(path: selectedFile.path, data: Data(editorText.utf8), modifiedAt: editorModifiedAt)
            guard let entry = localWorkspace.entry(path: selectedFile.path) else { throw LocalWorkspaceError.missing }
            self.selectedFile = FileResponse(path: selectedFile.path, name: selectedFile.name, kind: selectedFile.kind,
                                             size: entry.size, modifiedAt: entry.modifiedAt, content: editorText)
            // Until the first edit we pin the displayed ancestor. Once locally saved, the dirty
            // journal protects it and the editor can sync without being closed.
            localWorkspace.setEditingPath(nil)
            localChangeSaved()
            editorAutosaveError = ""
            statusMessage = "자동 저장됨 · \(selectedFile.name)"
            return true
        } catch { editorAutosaveError = error.localizedDescription; statusMessage = "자동 저장 실패 · \(editorAutosaveError)"; return false }
    }

    func saveSelectedFile() async {
        _ = persistEditorText()
    }

    private func loadTree(root: String, path: String, showStatus: Bool = true) async {
        if localWorkspace != nil {
            reloadLocalWorkspace()
            if root == "code" { codePath = path } else { notesPath = path }
            if showStatus { statusMessage = "로컬 자료 목록" }
            return
        }
        guard let api else { return }
        if showStatus {
            isLoading = true
        }
        defer {
            if showStatus {
                isLoading = false
            }
        }
        do {
            let tree = try await api.tree(root: root, recursive: true)
            let rootName = workspaceRootFolderName(for: root)
            let selectedFolderPath = path.isEmpty ? rootName : "\(rootName)/\(path)"
            let resolvedPath = path.isEmpty || tree.children.contains(where: { $0.isDirectory && $0.path == selectedFolderPath })
                ? path
                : ""
            if root == "code" {
                codePath = resolvedPath
                code = tree.children
            } else {
                notesPath = resolvedPath
                notes = tree.children
            }
            clearSelectionIfMissingFromTree(root: root, children: tree.children)
            if showStatus {
                statusMessage = "Updated \(rootName) files"
            }
        } catch {
            if showStatus {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func workspacePathForNewItem(root: String, name: String) -> String {
        let base = workspaceRootFolderName(for: root)
        let current = currentPath(for: root)
        let nested = current.isEmpty ? name : "\(current)/\(name)"
        return "\(base)/\(nested)"
    }

    private func workspaceRootFolderName(for root: String) -> String {
        root == "code" ? "Code" : "Notes"
    }

    private func cleanNewItemName(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func defaultExtensionName(_ name: String, root: String) -> String {
        guard URL(fileURLWithPath: name).pathExtension.isEmpty else { return name }
        return root == "code" ? "\(name).swift" : "\(name).md"
    }

    private func defaultFileContent(for name: String) -> String {
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            let title = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            return "# \(title)\n"
        }
        return ""
    }

    private func siblingWorkspacePath(for path: String, newName: String) -> String {
        guard let slashIndex = path.lastIndex(of: "/") else { return newName }
        return "\(path[..<slashIndex])/\(newName)"
    }

    private func workspacePath(in root: String, folder: String, name: String) -> String {
        let base = workspaceRootFolderName(for: root)
        let cleanFolder = normalizeNestedFolder(folder)
        if cleanFolder.isEmpty {
            return "\(base)/\(name)"
        }
        return "\(base)/\(cleanFolder)/\(name)"
    }

    private func normalizeNestedFolder(_ folder: String) -> String {
        folder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }

    private func clearSelectionIfNeeded(paths: [String]) {
        guard let selectedPath = selectedResourcePath else { return }
        if paths.contains(where: { selectedPath == $0 || selectedPath.hasPrefix($0 + "/") }) {
            activeFileLoadID = nil
            activeFileLoadPath = nil
            activeFileLoadItem = nil
            selectedFile = nil
            selectedRawFile = nil
            loadingRawFile = nil
            rawFileLoadError = nil
            editorText = ""
            isEditingFile = false
        }
    }

    private func topLevelWorkspaceItems(_ items: [WorkspaceItem]) -> [WorkspaceItem] {
        let uniqueItems = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let paths = Set(uniqueItems.keys)
        return uniqueItems.values
            .filter { item in
                !paths.contains(where: { path in
                    path != item.path && item.path.hasPrefix(path + "/")
                })
            }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func clearSelectionIfMissingFromTree(root: String, children: [WorkspaceItem]) {
        guard let selectedPath = selectedResourcePath else { return }
        let rootName = workspaceRootFolderName(for: root)
        guard selectedPath.hasPrefix(rootName + "/") else { return }
        if !children.contains(where: { $0.path == selectedPath }) {
            activeFileLoadID = nil
            activeFileLoadPath = nil
            activeFileLoadItem = nil
            selectedFile = nil
            selectedRawFile = nil
            loadingRawFile = nil
            rawFileLoadError = nil
            editorText = ""
            isEditingFile = false
        }
    }

    func runSearch(query: String, scopePath: String) async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            searchResponse = try await api.search(query: query, scopePath: scopePath)
            statusMessage = "\(searchResponse?.resultCount ?? 0) results"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func runGlobalSearch(query: String, surface: String) async {
        guard let api else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            globalSearchResponse = try await api.globalSearch(query: query, surface: surface)
            statusMessage = "\(globalSearchResponse?.resultCount ?? 0) global results"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func prepareNewChat() {
        liveSessionId = nil
        activeHermesSessionTitle = "No session"
        activeActivityLineId = nil
        isChatTurnOpen = false
        chatLines = [ChatLine(role: "system", text: "New chat ready. Send a message to create a session.")]
        statusMessage = "New chat ready"
    }

    func startNewHermesSession() async {
        guard isWorkspaceConnected else {
            statusMessage = "AI 대화는 Settings → Connection에서 서버에 연결한 뒤 사용할 수 있습니다."
            return
        }
        guard let url = currentServerURL else {
            statusMessage = "Invalid server URL"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await liveClient.connect(baseURL: url, authToken: serverAuthToken) { [weak self] envelope in
                Task { @MainActor in
                    self?.handleLiveEnvelope(envelope)
                }
            }
            let selectedModel = selectedHermesModel
            let sessionId = try await liveClient.createSession(
                provider: selectedModel?.provider,
                model: selectedModel?.model,
                reasoningEffort: chatReasoningMode.effort,
                accessMode: chatAccessMode.rawValue,
                surface: activeChatSurface,
                folderId: selectedConversationFolderIdForNewSession,
                projectId: selectedProjectIdForNewSession
            )
            liveSessionId = sessionId
            activeHermesSessionTitle = "New session"
            activeActivityLineId = nil
            isChatTurnOpen = false
            if chatLines.allSatisfy({ $0.role == "system" }) {
                chatLines.removeAll()
            }
            statusMessage = "New live session connected"
            await refreshHermesMetadata()
            updateActiveSessionTitle()
        } catch {
            statusMessage = error.localizedDescription
            chatLines.append(ChatLine(role: "system", text: error.localizedDescription))
        }
    }

    func connectLiveChat() async {
        await startNewHermesSession()
    }

    func resumeHermesSession(_ session: HermesSessionSummary) async {
        guard let url = currentServerURL else {
            statusMessage = "Invalid server URL"
            return
        }
        guard let api else {
            statusMessage = "Invalid server URL"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let history = try await api.hermesSessionMessages(sessionId: session.id)
            chatLines = chatLinesFromHistory(history, fallbackTitle: session.title)
            activeActivityLineId = nil
            isChatTurnOpen = false
            try await liveClient.connect(baseURL: url, authToken: serverAuthToken) { [weak self] envelope in
                Task { @MainActor in
                    self?.handleLiveEnvelope(envelope)
                }
            }
            try await liveClient.resumeSession(sessionId: session.id)
            liveSessionId = session.id
            activeHermesSessionTitle = session.title
            if let provider = session.provider, let model = session.model {
                let sessionModelId = "\(provider):\(model)"
                if hermesModels.contains(where: { $0.id == sessionModelId }) {
                    selectedHermesModelId = sessionModelId
                }
            }
            statusMessage = "Resumed \(session.title)"
        } catch {
            statusMessage = error.localizedDescription
            chatLines.append(ChatLine(role: "system", text: error.localizedDescription))
        }
    }

    func sendChatMessage(_ text: String) async {
        guard isWorkspaceConnected else {
            statusMessage = "AI 대화는 Settings → Connection에서 서버에 연결한 뒤 사용할 수 있습니다."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if liveSessionId == nil {
            await startNewHermesSession()
        }
        guard let liveSessionId else { return }
        if activeHermesSessionTitle == "No session" || activeHermesSessionTitle == "New session" || activeHermesSessionTitle.hasPrefix("Session ") {
            activeHermesSessionTitle = localSessionTitle(from: trimmed)
        }
        chatLines.append(ChatLine(role: "user", text: trimmed))
        activeActivityLineId = nil
        isChatTurnOpen = true
        do {
            let selectedModel = selectedHermesModel
            let finalReply = try await liveClient.submit(
                sessionId: liveSessionId,
                message: trimmed,
                provider: selectedModel?.provider,
                model: selectedModel?.model,
                contextRequest: chatContextRequest(),
                surface: activeChatSurface,
                route: activeChatRoute
            )
            if let finalReply,
               !finalReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let assistantIndex = chatLines.lastIndex(where: { $0.role == "assistant" }) {
                    chatLines[assistantIndex].text = finalReply
                } else {
                    chatLines.append(ChatLine(role: "assistant", text: finalReply))
                }
            }
            statusMessage = "Message sent"
        } catch {
            statusMessage = error.localizedDescription
            chatLines.append(ChatLine(role: "system", text: error.localizedDescription))
        }
    }

    func renameHermesSession(_ session: HermesSessionSummary, title: String) async {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            statusMessage = "Session title is required"
            return
        }
        guard let api else { return }
        do {
            try await api.renameHermesSession(sessionId: session.id, title: cleaned)
            hermesSessions = hermesSessions.map {
                $0.id == session.id
                    ? HermesSessionSummary(
                        id: $0.id,
                        title: cleaned,
                        updatedAt: $0.updatedAt,
                        provider: $0.provider,
                        model: $0.model,
                        folderId: $0.folderId,
                        folderTitle: $0.folderTitle,
                        projectId: $0.projectId,
                        projectTitle: $0.projectTitle,
                        pinned: $0.pinned,
                        storageBytes: $0.storageBytes
                    )
                    : $0
            }
            if session.id == liveSessionId {
                activeHermesSessionTitle = cleaned
            }
            statusMessage = "Renamed \(cleaned)"
            await refreshHermesMetadata()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setHermesSessionPinned(_ session: HermesSessionSummary, pinned: Bool) async {
        guard let api else { return }
        do {
            try await api.setHermesSessionPinned(sessionId: session.id, pinned: pinned)
            hermesSessions = hermesSessions.map {
                guard $0.id == session.id else { return $0 }
                return HermesSessionSummary(
                    id: $0.id,
                    title: $0.title,
                    updatedAt: $0.updatedAt,
                    provider: $0.provider,
                    model: $0.model,
                    folderId: $0.folderId,
                    folderTitle: $0.folderTitle,
                    projectId: $0.projectId,
                    projectTitle: $0.projectTitle,
                    pinned: pinned,
                    storageBytes: $0.storageBytes
                )
            }
            statusMessage = pinned ? "Pinned \(session.title)" : "Unpinned \(session.title)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteHermesSession(_ session: HermesSessionSummary) async {
        guard let api else { return }
        if session.id == liveSessionId {
            statusMessage = "Cannot delete the active session"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            try await api.deleteHermesSession(sessionId: session.id)
            hermesSessions.removeAll { $0.id == session.id }
            chatHistoryStorage = try await api.chatHistoryStorage()
            statusMessage = "Deleted \(session.title)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteHermesSessions(_ sessions: [HermesSessionSummary]) async {
        guard let api else { return }
        let deletable = sessions.filter { $0.id != liveSessionId }
        guard !deletable.isEmpty else {
            statusMessage = "No deletable sessions selected"
            return
        }
        isLoading = true
        defer { isLoading = false }

        var deletedIds = Set<String>()
        var failureCount = 0
        for session in deletable {
            do {
                try await api.deleteHermesSession(sessionId: session.id)
                deletedIds.insert(session.id)
            } catch {
                failureCount += 1
            }
        }

        hermesSessions.removeAll { deletedIds.contains($0.id) }
        statusMessage = failureCount == 0
            ? "Deleted \(deletedIds.count) sessions"
            : "Deleted \(deletedIds.count), failed \(failureCount)"
        await refreshHermesMetadata()
    }

    var chatHistoryStorageText: String {
        ByteCountFormatter.string(fromByteCount: chatHistoryStorage.bytes, countStyle: .file)
    }

    func applyAccessModeToLiveSession() async {
        guard let liveSessionId else { return }
        do {
            try await liveClient.setAccessMode(sessionId: liveSessionId, accessMode: chatAccessMode.rawValue)
            statusMessage = "\(chatAccessMode.label) mode applied"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func applyReasoningModeToLiveSession() async {
        guard let liveSessionId else { return }
        do {
            try await liveClient.setReasoningMode(sessionId: liveSessionId, reasoningEffort: chatReasoningMode.effort)
            statusMessage = "\(chatReasoningMode.label) reasoning applied"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    var filteredHermesSessions: [HermesSessionSummary] {
        filterSessions(hermesSessions)
    }

    var filteredSessionsForSelectedHermesProject: [HermesSessionSummary] {
        filterSessions(sessionsForSelectedHermesProject)
    }

    private func filterSessions(_ sessions: [HermesSessionSummary]) -> [HermesSessionSummary] {
        let query = sessionManagerSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.lowercased().contains(query)
                || $0.id.lowercased().contains(query)
                || ($0.updatedAt ?? "").lowercased().contains(query)
                || ($0.folderTitle ?? "").lowercased().contains(query)
                || ($0.folderId ?? "").lowercased().contains(query)
                || ($0.projectTitle ?? "").lowercased().contains(query)
                || ($0.projectId ?? "").lowercased().contains(query)
        }
    }

    var hermesSessionProjects: [HermesSessionProject] {
        var projects = [
            HermesSessionProject(id: "__all__", title: "All sessions", sessionCount: hermesSessions.count)
        ]
        var seen = Set(["__all__"])
        for folder in conversationFolders {
            let count = hermesSessions.filter { $0.folderId == folder.id }.count
            projects.append(HermesSessionProject(id: folder.id, title: folder.name, sessionCount: count))
            seen.insert(folder.id)
        }
        for session in hermesSessions {
            if let folderId = session.folderId, seen.contains(folderId) { continue }
            let rawId = session.folderId ?? session.projectId ?? session.projectTitle
            guard let rawId, !rawId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let id = rawId
            guard seen.insert(id).inserted else { continue }
            let count = hermesSessions.filter { ($0.folderId ?? $0.projectId ?? $0.projectTitle) == id }.count
            projects.append(HermesSessionProject(id: id, title: shortProjectTitle(session.folderTitle ?? session.projectTitle ?? id), sessionCount: count))
        }
        return projects
    }

    var selectedHermesProjectTitle: String {
        hermesSessionProjects.first(where: { $0.id == selectedHermesProjectId })?.title ?? "All sessions"
    }

    var sessionsForSelectedHermesProject: [HermesSessionSummary] {
        guard selectedHermesProjectId != "__all__" else { return hermesSessions }
        return hermesSessions.filter { ($0.folderId ?? $0.projectId ?? $0.projectTitle) == selectedHermesProjectId }
    }

    var selectedConversationFolderIdForNewSession: String? {
        conversationFolders.contains { $0.id == selectedHermesProjectId } ? selectedHermesProjectId : nil
    }

    var selectedProjectIdForNewSession: String? {
        guard selectedHermesProjectId != "__all__",
              !conversationFolders.contains(where: { $0.id == selectedHermesProjectId }) else {
            return nil
        }
        return selectedHermesProjectId
    }

    private func shortProjectTitle(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return normalized.split(separator: "/").last.map(String.init) ?? value
    }

    private func localSessionTitle(from message: String) -> String {
        let collapsed = message
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?。！？"))
        guard !collapsed.isEmpty else { return "New chat" }
        let limit = 34
        if collapsed.count <= limit { return collapsed }
        let index = collapsed.index(collapsed.startIndex, offsetBy: limit)
        return "\(collapsed[..<index].trimmingCharacters(in: .whitespacesAndNewlines))..."
    }

    private func splitShellLikeArgs(_ value: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        for char in value {
            if escaping {
                current.append(char)
                escaping = false
                continue
            }
            if char == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                continue
            }
            if char.isWhitespace {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            args.append(current)
        }
        return args
    }

    private func parseEnvLines(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in value.split(whereSeparator: \.isNewline) {
            let raw = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, let equals = raw.firstIndex(of: "=") else { continue }
            let key = raw[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let val = raw[raw.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !val.isEmpty {
                result[String(key)] = String(val)
            }
        }
        return result
    }

    func respondToApproval(lineId: UUID, approved: Bool) async {
        guard let approvalId = chatLines.first(where: { $0.id == lineId })?.approvalId else {
            statusMessage = "Missing approval id"
            return
        }
        do {
            try await liveClient.respondToApproval(approvalId: approvalId, approved: approved)
            updateApprovalLine(lineId, state: approved ? .approved : .denied)
            statusMessage = approved ? "Approval sent" : "Denial sent"
        } catch {
            statusMessage = error.localizedDescription
            updateApprovalLine(lineId, state: .pending)
            chatLines.append(ChatLine(role: "system", text: error.localizedDescription))
        }
    }

    var chatContextLabel: String {
        switch chatContextScope {
        case .none:
            "No workspace context"
        case .currentFile:
            selectedResourcePath.map { "Current file: \($0)" } ?? "Current file: none selected"
        case .currentFolder:
            "Current folder: \(selectedFolderPath.isEmpty ? "workspace root" : selectedFolderPath)"
        case .workspace:
            "Workspace root"
        }
    }

    var selectedHermesModel: HermesModelOption? {
        hermesModels.first { $0.id == selectedHermesModelId }
    }

    var selectedHermesModelShortLabel: String {
        guard let selectedHermesModel else { return "Model" }
        return selectedHermesModel.shortLabel
    }

    var visibleHermesModels: [HermesModelOption] {
        hermesModels.filter { isModelVisible($0) }
    }

    var visibleHermesModelGroups: [HermesModelGroup] {
        groupedHermesModels(visibleHermesModels)
    }

    var allHermesModelGroups: [HermesModelGroup] {
        groupedHermesModels(hermesModels)
    }

    func isProviderVisible(_ providerId: String) -> Bool {
        !hiddenModelProviderIds.contains(providerId)
    }

    func isModelVisible(_ model: HermesModelOption) -> Bool {
        let providerId = model.provider ?? "default"
        return isProviderVisible(providerId) && !hiddenModelIds.contains(model.id)
    }

    func setProviderVisible(_ providerId: String, visible: Bool) {
        if visible {
            hiddenModelProviderIds.remove(providerId)
        } else {
            hiddenModelProviderIds.insert(providerId)
        }
        persistStringSet(hiddenModelProviderIds, key: modelVisibilityKey("codmes.hiddenModelProviderIds"))
        ensureVisibleSelectedModel()
    }

    func setModelVisible(_ model: HermesModelOption, visible: Bool) {
        if visible {
            hiddenModelIds.remove(model.id)
        } else {
            hiddenModelIds.insert(model.id)
        }
        persistStringSet(hiddenModelIds, key: modelVisibilityKey("codmes.hiddenModelIds"))
        ensureVisibleSelectedModel()
    }

    func resetModelVisibility() {
        hiddenModelProviderIds.removeAll()
        hiddenModelIds.removeAll()
        persistStringSet(hiddenModelProviderIds, key: modelVisibilityKey("codmes.hiddenModelProviderIds"))
        persistStringSet(hiddenModelIds, key: modelVisibilityKey("codmes.hiddenModelIds"))
        ensureVisibleSelectedModel()
    }

    func providerDisplayName(_ providerId: String) -> String {
        runtimeProviders.first { $0.id == providerId }?.name
            ?? providerId
                .split(separator: "-")
                .map { $0.capitalized }
                .joined(separator: " ")
    }

    private func groupedHermesModels(_ models: [HermesModelOption]) -> [HermesModelGroup] {
        var order: [String] = []
        var grouped: [String: [HermesModelOption]] = [:]
        for model in models {
            let providerId = model.provider ?? "default"
            if grouped[providerId] == nil {
                order.append(providerId)
                grouped[providerId] = []
            }
            grouped[providerId]?.append(model)
        }
        return order.map { providerId in
            HermesModelGroup(
                id: providerId,
                title: providerId == "default" ? "Default" : providerDisplayName(providerId),
                models: grouped[providerId] ?? []
            )
        }
    }

    private func ensureVisibleSelectedModel() {
        if selectedHermesModelId.isEmpty { return }
        if let selected = selectedHermesModel, isModelVisible(selected) { return }
        selectedHermesModelId = visibleHermesModels.first?.id ?? hermesModels.first?.id ?? ""
    }

    private static func loadStringSet(_ key: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: key),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(values)
    }

    private func persistStringSet(_ values: Set<String>, key: String) {
        if let data = try? JSONEncoder().encode(Array(values).sorted()) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func handleLiveEnvelope(_ envelope: LiveEnvelope) {
        switch envelope.kind {
        case "ready":
            statusMessage = "Live bridge ready"
        case "runtime.event", "hermes.event":
            appendRuntimeEvent(envelope)
        case "runtime.close", "hermes.close":
            chatLines.append(ChatLine(role: "system", text: "Live runtime connection closed."))
        case "error":
            chatLines.append(ChatLine(role: "system", text: envelope.error ?? "Live bridge error."))
        default:
            break
        }
    }

    private func appendRuntimeEvent(_ envelope: LiveEnvelope) {
        let type = envelope.type ?? "event"
        let text = envelope.text ?? ""
        if isAssistantDelta(type) {
            guard !text.isEmpty else { return }
            if chatLines.last?.role == "assistant" {
                chatLines[chatLines.count - 1].text += text
            } else {
                chatLines.append(ChatLine(role: "assistant", text: text))
            }
            return
        }

        if type == "message.done"
            || type == "response.done"
            || type == "content.done"
            || type == "message.completed"
            || type == "response.completed"
            || type == "message.complete"
            || type == "response.complete"
            || type == "turn.complete"
            || type == "turn.completed" {
            isChatTurnOpen = false
            finishActiveActivity()
            activeActivityLineId = nil
            Task {
                await refreshHermesMetadata()
                await refreshApprovals()
                await refreshAgentTasks()
                updateActiveSessionTitle()
            }
            return
        }

        if type.contains("thinking") || type.contains("reasoning") {
            if isChatTurnOpen && isMeaningfulActivityText(text) {
                appendActivity(type: type, text: text)
            }
            return
        }
        if type.contains("tool") {
            if isChatTurnOpen {
                appendActivity(type: type, text: text)
            }
            return
        }
        if type == "approval.request" {
            chatLines.append(ChatLine(role: "approval", text: text.isEmpty ? "Approval requested." : text, approvalState: .pending, approvalId: envelope.approvalId))
            Task {
                await refreshApprovals()
                await refreshAgentTasks()
            }
            return
        }
        if type.hasPrefix("task.") || type.contains("approval") {
            Task {
                await refreshApprovals()
                await refreshAgentTasks()
            }
            return
        }
    }

    private func chatLinesFromHistory(_ messages: [HermesSessionMessage], fallbackTitle: String) -> [ChatLine] {
        var lines: [ChatLine] = []
        for message in messages {
            let role = normalizedHistoryRole(message.role)
            guard let role else { continue }
            if role == "activity" {
                let label = message.toolName.map { "\($0): \(message.content)" } ?? message.content
                lines.append(ChatLine(role: "activity", text: "Activity · 1 tool", activityItems: [
                    ChatActivity(type: message.toolName ?? message.role, text: label)
                ]))
                continue
            }
            if role == "assistant", let reasoning = message.reasoning, !reasoning.isEmpty {
                lines.append(ChatLine(role: "activity", text: "Activity · thinking", activityItems: [
                    ChatActivity(type: "Reasoning", text: reasoning)
                ]))
            }
            let content = role == "user" ? displayedUserMessage(from: message.content) : message.content
            lines.append(ChatLine(role: role, text: content))
        }
        if !lines.isEmpty {
            return lines
        }
        return [ChatLine(role: "system", text: "No saved messages for \(fallbackTitle).")]
    }

    private func updateActiveSessionTitle() {
        guard let liveSessionId else {
            activeHermesSessionTitle = "No session"
            return
        }
        if let session = hermesSessions.first(where: { $0.id == liveSessionId }) {
            activeHermesSessionTitle = session.title
        } else if activeHermesSessionTitle == "No session" {
            activeHermesSessionTitle = "Current session"
        }
    }

    private func normalizedHistoryRole(_ role: String) -> String? {
        switch role.lowercased() {
        case "user":
            return "user"
        case "assistant":
            return "assistant"
        case "system":
            return "system"
        case "tool", "function":
            return "activity"
        default:
            return nil
        }
    }

    private func displayedUserMessage(from content: String) -> String {
        let marker = "[User message]"
        guard let range = content.range(of: marker) else {
            return content
        }
        return String(content[range.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateApprovalLine(_ id: UUID, state: ApprovalState) {
        guard let index = chatLines.firstIndex(where: { $0.id == id }) else { return }
        var updatedLine = chatLines[index]
        updatedLine.approvalState = state
        chatLines[index] = updatedLine
    }

    private func appendActivity(type: String, text: String) {
        let group = activityGroup(for: type)
        let item = ChatActivity(type: group, text: text.isEmpty ? group : text)
        if let activeActivityLineId,
           let index = chatLines.firstIndex(where: { $0.id == activeActivityLineId }) {
            var updatedLine = chatLines[index]
            if let itemIndex = updatedLine.activityItems.firstIndex(where: { $0.type == group }) {
                var updatedItems = updatedLine.activityItems
                updatedItems[itemIndex].text = mergeActivityText(
                    updatedItems[itemIndex].text,
                    text
                )
                updatedLine.activityItems = updatedItems
            } else {
                updatedLine.activityItems.append(item)
            }
            updatedLine.text = activitySummary(updatedLine.activityItems)
            updatedLine.isStreamingActivity = true
            chatLines[index] = updatedLine
        } else {
            let line = ChatLine(role: "activity", text: activitySummary([item]), activityItems: [item], isStreamingActivity: true)
            activeActivityLineId = line.id
            chatLines.append(line)
        }
    }

    private func finishActiveActivity() {
        guard let activeActivityLineId,
              let index = chatLines.firstIndex(where: { $0.id == activeActivityLineId }) else {
            return
        }
        var updatedLine = chatLines[index]
        updatedLine.isStreamingActivity = false
        chatLines[index] = updatedLine
    }

    private func activitySummary(_ items: [ChatActivity]) -> String {
        let toolCount = items.filter { $0.type == "Tool" }.count
        let thoughtCount = items.filter { $0.type == "Thinking" || $0.type == "Reasoning" }.count
        let parts = [
            thoughtCount > 0 ? "thinking" : nil,
            toolCount > 0 ? "\(toolCount) tools" : nil
        ].compactMap { $0 }
        return parts.isEmpty ? "Activity" : "Activity · " + parts.joined(separator: " · ")
    }

    private func activityGroup(for type: String) -> String {
        if type.contains("tool") {
            return "Tool"
        }
        if type.contains("reasoning") {
            return "Reasoning"
        }
        return "Thinking"
    }

    private func isMeaningfulActivityText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed == #"{"text":""}"# || trimmed == #"{"text": ""}"# {
            return false
        }
        return true
    }

    private func mergeActivityText(_ current: String, _ incoming: String) -> String {
        guard !incoming.isEmpty else { return current }
        guard !current.isEmpty else { return incoming }
        if current.last?.isWhitespace == true || incoming.first?.isWhitespace == true {
            return current + incoming
        }
        if incoming.first?.isPunctuation == true {
            return current + incoming
        }
        if current.last?.isASCIIAlphaNumeric == true && incoming.first?.isASCIIAlphaNumeric == true {
            return current + " " + incoming
        }
        return current + incoming
    }

    private func isAssistantDelta(_ type: String) -> Bool {
        type == "message.delta"
            || type == "assistant.delta"
            || type == "assistant.message.delta"
    }

    private func chatContextRequest() -> ContextRequest? {
        switch chatContextScope {
        case .none:
            return nil
        case .currentFile:
            guard let selectedResourcePath, let selectedResourceKind else { return nil }
            let scopeType = selectedResourceKind == "pdf" ? "pdf" : "current"
            return ContextRequest(scopeType: scopeType, scopePath: selectedResourcePath, activePath: selectedResourcePath)
        case .currentFolder:
            return ContextRequest(scopeType: "folder", scopePath: selectedFolderPath, activePath: selectedResourcePath)
        case .workspace:
            return ContextRequest(scopeType: "workspace", scopePath: nil, activePath: selectedResourcePath)
        }
    }

    private var selectedFolderPath: String {
        guard let path = selectedResourcePath else { return "" }
        guard let slashIndex = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slashIndex])
    }

    private var selectedResourcePath: String? {
        loadingRawFile?.path ?? selectedFile?.path ?? selectedRawFile?.path
    }

    private var selectedResourceKind: String? {
        loadingRawFile?.kind ?? selectedFile?.kind ?? selectedRawFile?.kind
    }

    private func nestedPath(root: String, workspacePath: String) -> String {
        let rootName = root == "code" ? "Code" : "Notes"
        if workspacePath == rootName { return "" }
        let prefix = rootName + "/"
        guard workspacePath.hasPrefix(prefix) else { return workspacePath }
        return String(workspacePath.dropFirst(prefix.count))
    }

    private func normalizedServerURL(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return text }
        if !text.contains("://") {
            text = "http://" + text
        }
        while text.count > "http://x".count && text.hasSuffix("/") {
            text.removeLast()
        }
        return text
    }

    private func describeConnectionError(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription) [URLError.\(urlError.code.rawValue)]"
        }
        if let apiError = error as? WorkspaceAPIError {
            return apiError.localizedDescription
        }
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }

    private func persistConnectionDiagnostics() {
        UserDefaults.standard.set(statusMessage, forKey: "workspace.lastStatusMessage")
        UserDefaults.standard.set(isWorkspaceConnected, forKey: "workspace.lastConnected")
        UserDefaults.standard.set(connectionStep, forKey: "workspace.lastConnectionStep")
        UserDefaults.standard.set(connectionDetail, forKey: "workspace.lastConnectionDetail")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "workspace.lastConnectionCheck")
    }

    private static func initialServerAuthToken() -> String {
        if let token = KeychainStore.readServerAuthToken(), !token.isEmpty {
            UserDefaults.standard.removeObject(forKey: "workspace.serverAuthToken")
            return token
        }
        let legacy = UserDefaults.standard.string(forKey: "workspace.serverAuthToken") ?? ""
        // One-time import only: never use a plaintext preference as an active credential.
        guard !legacy.isEmpty, KeychainStore.writeServerAuthToken(legacy) else { return "" }
        UserDefaults.standard.removeObject(forKey: "workspace.serverAuthToken")
        return legacy
    }

    private static func initialFileCacheLimitGB() -> Int {
        let stored = UserDefaults.standard.integer(forKey: "workspace.localFileCacheLimitGB")
        if stored > 0 { return min(stored, 50) }
#if os(macOS)
        return 20
#else
        return 6
#endif
    }

    private static func streamedPDFPageItem(source: WorkspaceItem, pageIndex: Int) -> WorkspaceItem {
        WorkspaceItem(
            name: "page-\(pageIndex + 1).pdf",
            path: "\(source.path)#codmes-stream-page-\(pageIndex + 1)",
            kind: "pdf",
            isDirectory: false,
            size: source.size,
            modifiedAt: source.modifiedAt
        )
    }
}

private actor WorkspaceFileDiskCache {
    private let fileManager = FileManager.default
    private let baseDirectory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        baseDirectory = base
            .appendingPathComponent("Codmes", isDirectory: true)
            .appendingPathComponent("WorkspaceFiles", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
    }

    func cachedURL(for item: WorkspaceItem, scope: String) -> URL? {
        let url = cacheURL(for: item, scope: scope)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    func storeDownloadedFile(_ temporaryURL: URL, for item: WorkspaceItem, limitBytes: Int64, scope: String) throws -> URL {
        try prepareDirectory(scope: scope)
        let destination = cacheURL(for: item, scope: scope)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: temporaryURL)
            touch(destination)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
            touch(destination)
        }
        trim(to: limitBytes, keeping: destination, scope: scope)
        return destination
    }

    func store(_ data: Data, for item: WorkspaceItem, limitBytes: Int64, scope: String) throws -> URL {
        try prepareDirectory(scope: scope)
        let destination = cacheURL(for: item, scope: scope)
        try data.write(to: destination, options: .atomic)
        touch(destination)
        trim(to: limitBytes, keeping: destination, scope: scope)
        return destination
    }

    func usageBytes(scope: String) -> Int64 {
        cacheEntries(scope: scope).reduce(0) { $0 + $1.size }
    }

    func trim(to limitBytes: Int64, keeping protectedURL: URL?, scope: String) {
        var entries = cacheEntries(scope: scope)
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return }
        entries.sort { $0.lastAccess < $1.lastAccess }
        for entry in entries where entry.url != protectedURL {
            guard total > limitBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    func clear(keeping protectedURL: URL?, scope: String) {
        for entry in cacheEntries(scope: scope) where entry.url != protectedURL {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    private func directory(scope: String) -> URL {
        let digest = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return baseDirectory.appendingPathComponent(digest, isDirectory: true)
    }

    private func cacheURL(for item: WorkspaceItem, scope: String) -> URL {
        let signature = "\(item.path)\n\(item.size):\(item.modifiedAt)"
        let digest = SHA256.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        return directory(scope: scope).appendingPathComponent(ext.isEmpty ? digest : "\(digest).\(ext)")
    }

    private func prepareDirectory(scope: String) throws {
        try fileManager.createDirectory(at: directory(scope: scope), withIntermediateDirectories: true)
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func cacheEntries(scope: String) -> [(url: URL, size: Int64, lastAccess: Date)] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory(scope: scope),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                return nil
            }
            return (
                url: url,
                size: Int64(values.fileSize ?? 0),
                lastAccess: values.contentModificationDate ?? .distantPast
            )
        }
    }
}

private extension Character {
    var isASCIIAlphaNumeric: Bool {
        guard let scalar = unicodeScalars.first, unicodeScalars.count == 1 else {
            return false
        }
        return (65...90).contains(Int(scalar.value))
            || (97...122).contains(Int(scalar.value))
            || (48...57).contains(Int(scalar.value))
    }
}
