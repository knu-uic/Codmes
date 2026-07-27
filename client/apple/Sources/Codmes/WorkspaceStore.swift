import CryptoKit
import Foundation

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var serverURLText = UserDefaults.standard.string(forKey: "workspace.serverURL") ?? "http://127.0.0.1:8787"
    @Published var serverAuthToken = WorkspaceStore.initialServerAuthToken()
    @Published var workspace: WorkspaceInfo?
    @Published var notes: [WorkspaceItem] = []
    @Published var code: [WorkspaceItem] = []
    @Published var notesPath = ""
    @Published var codePath = ""
    @Published var selectedFile: FileResponse?
    @Published var selectedRawFile: RawFilePreview?
    @Published var loadingRawFile: WorkspaceItem?
    @Published var rawFileLoadError: String?
    @Published var selectedPDFFocus: PDFDocumentFocus?
    @Published var editorText = ""
    @Published var isEditingFile = false
    @Published var searchResponse: SearchResponse?
    @Published var globalSearchResponse: GlobalSearchResponse?
    @Published var chatLines: [ChatLine] = [
        ChatLine(role: "system", text: "Connect to the Workspace Server, then start a live session.")
    ]
    @Published var liveSessionId: String?
    @Published var hermesModels: [HermesModelOption] = []
    @Published var hermesSessions: [HermesSessionSummary] = []
    @Published var activeHermesSessionTitle = "No session"
    @Published var selectedHermesModelId = ""
    @Published var chatAccessMode: ChatAccessMode = .confirm
    @Published var chatReasoningMode: ChatReasoningMode = .balanced
    @Published var chatContextScope: ChatContextScope = .currentFile
    @Published var activeChatSurface = "chat"
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
    @Published var workspaceSurfaces: [WorkspaceSurface] = []
    @Published var surfaceSetupMessage = ""
    @Published var mcpServers: [MCPServerConfig] = []
    @Published var mcpSetupMessage = ""
    @Published var searchConfig: SearchConfigResponse?
    @Published var searchSetupMessage = ""
    @Published var hiddenModelProviderIds = WorkspaceStore.loadStringSet("codmes.hiddenModelProviderIds")
    @Published var hiddenModelIds = WorkspaceStore.loadStringSet("codmes.hiddenModelIds")
    @Published var localFileCacheLimitGB = WorkspaceStore.initialFileCacheLimitGB()
    @Published var localFileCacheUsageBytes: Int64 = 0

    private let liveClient = LiveChatClient()
    private var activeActivityLineId: UUID?
    private var isChatTurnOpen = false
    private var activeFileLoadID: UUID?
    private var rawFileCache: [String: (signature: String, preview: RawFilePreview)] = [:]
    private let fileDiskCache = WorkspaceFileDiskCache()
    private let chunkedUploadThresholdBytes: Int64 = 8 * 1024 * 1024
    private let uploadChunkSize = 1024 * 1024

    var api: WorkspaceAPI? {
        guard let url = currentServerURL else { return nil }
        return WorkspaceAPI(baseURL: url, authToken: serverAuthToken)
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
            documentJobs = []
            return
        }
        do {
            documentJobs = try await api.documentJobs()
        } catch {
            if !isWorkspaceConnected {
                documentJobs = []
            }
        }
    }

    func monitorDocumentJobs() async {
        while !Task.isCancelled {
            await refreshDocumentJobs()
            let interval: UInt64 = activeDocumentJobs.isEmpty ? 2_000_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    func setLocalFileCacheLimitGB(_ value: Int) {
        localFileCacheLimitGB = min(max(value, 1), 50)
        UserDefaults.standard.set(localFileCacheLimitGB, forKey: "workspace.localFileCacheLimitGB")
        Task {
            await fileDiskCache.trim(to: localFileCacheLimitBytes, keeping: selectedRawFile?.url)
            await refreshLocalFileCacheUsage()
        }
    }

    func refreshLocalFileCacheUsage() async {
        localFileCacheUsageBytes = await fileDiskCache.usageBytes()
    }

    func clearLocalFileCache() async {
        await fileDiskCache.clear(keeping: selectedRawFile?.url)
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
        let previous = UserDefaults.standard.string(forKey: "workspace.serverURL") ?? ""
        let cleaned = normalizedServerURL(serverURLText)
        serverURLText = cleaned
        UserDefaults.standard.set(cleaned, forKey: "workspace.serverURL")
        if !previous.isEmpty, previous != cleaned {
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
        isLoading = true
        defer { isLoading = false }
        do {
            connectionStep = "Checking /api/health"
            connectionDetail = "Trying \(effectiveServerURLText)/api/health"
            let health = try await api.health()
            connectionDetail = "Health OK: \(health.service) at \(serverURLText)"
            connectionStep = "Loading /api/workspace"
            workspace = try await api.workspace()
            connectionStep = "Loading Notes tree"
            let notesTree = try await api.tree(root: "notes", recursive: true)
            connectionStep = "Loading Code tree"
            let codeTree = try await api.tree(root: "code", recursive: true)
            notes = notesTree.children
            code = codeTree.children
            connectionStep = "Loading surfaces"
            await refreshSurfaces()
            connectionStep = "Loading MCP servers"
            await refreshMCPServers()
            await refreshSearchConfig()
            connectionStep = "Loading runtime metadata"
            await refreshHermesMetadata()
            connectionStep = "Loading pending approvals"
            await refreshApprovals()
            connectionStep = "Loading agent tasks"
            await refreshAgentTasks()
            await refreshDocumentJobs()
            statusMessage = "Connected"
            isWorkspaceConnected = true
            connectionStep = "Ready"
            persistConnectionDiagnostics()
        } catch {
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

    func refreshSurfaces() async {
        guard let api else { return }
        do {
            workspaceSurfaces = try await api.surfaces()
            surfaceSetupMessage = ""
        } catch {
            surfaceSetupMessage = error.localizedDescription
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

    func saveMCPServer(name: String, command: String, argsText: String, envText: String, scopePath: String, enabled: Bool, editingExisting: Bool) async {
        guard let api else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else {
            mcpSetupMessage = "MCP name is required."
            return
        }
        guard !cleanedCommand.isEmpty else {
            mcpSetupMessage = "MCP command is required."
            return
        }
        do {
            let updatesExistingServer = editingExisting || mcpServers.contains(where: { $0.name == cleanedName })
            let body = MCPServerUpdateBody(
                name: updatesExistingServer ? nil : cleanedName,
                command: cleanedCommand,
                args: splitShellLikeArgs(argsText),
                enabled: enabled,
                env: parseEnvLines(envText),
                scopePath: scopePath.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func setSurfaceEnabled(_ surface: WorkspaceSurface, enabled: Bool) async {
        guard let api else { return }
        do {
            _ = try await api.updateSurface(
                id: surface.id,
                body: SurfaceUpdateBody(
                    title: nil,
                    kind: nil,
                    icon: nil,
                    description: nil,
                    prompt: nil,
                    root: nil,
                    pluginId: nil,
                    enabled: enabled,
                    removable: nil,
                    order: nil,
                    remove: nil
                )
            )
            await refreshSurfaces()
        } catch {
            surfaceSetupMessage = error.localizedDescription
        }
    }

    func addPluginSurface(id: String, title: String, prompt: String) async {
        guard let api else { return }
        let trimmedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            surfaceSetupMessage = "Surface id is required."
            return
        }
        do {
            _ = try await api.updateSurface(
                id: trimmedId,
                body: SurfaceUpdateBody(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? trimmedId : title,
                    kind: "plugin",
                    icon: "square.grid.2x2",
                    description: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    root: nil,
                    pluginId: trimmedId,
                    enabled: true,
                    removable: true,
                    order: nil,
                    remove: nil
                )
            )
            await refreshSurfaces()
        } catch {
            surfaceSetupMessage = error.localizedDescription
        }
    }

    func removeSurface(_ surface: WorkspaceSurface) async {
        guard let api else { return }
        do {
            _ = try await api.updateSurface(
                id: surface.id,
                body: SurfaceUpdateBody(
                    title: nil,
                    kind: nil,
                    icon: nil,
                    description: nil,
                    prompt: nil,
                    root: nil,
                    pluginId: nil,
                    enabled: nil,
                    removable: nil,
                    order: nil,
                    remove: true
                )
            )
            await refreshSurfaces()
        } catch {
            surfaceSetupMessage = error.localizedDescription
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
            runtimeModelSetupMessage = "Default model updated."
            await refreshRuntimeProviders()
            await refreshHermesMetadata()
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
            runtimeModelSetupMessage = "Default model updated."
            await refreshRuntimeProviders()
            await refreshHermesMetadata()
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
        guard !workspaceSurfaces.isEmpty else { return true }
        return workspaceSurfaces.first { $0.id == surfaceId }?.isEnabled ?? true
    }

    var enabledPluginSurfaces: [WorkspaceSurface] {
        workspaceSurfaces.filter { surface in
            surface.kind == "plugin" && surface.isEnabled
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

    func createFolder(root: String, name: String) async {
        guard let api else { return }
        let cleaned = cleanNewItemName(name)
        guard !cleaned.isEmpty else {
            statusMessage = "Folder name is required"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let path = workspacePathForNewItem(root: root, name: cleaned)
            try await api.createFolder(path: path)
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = "Created folder \(cleaned)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func createFile(root: String, name: String) async {
        guard let api else { return }
        let cleaned = cleanNewItemName(name)
        guard !cleaned.isEmpty else {
            statusMessage = "File name is required"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let finalName = defaultExtensionName(cleaned, root: root)
            let path = workspacePathForNewItem(root: root, name: finalName)
            try await api.createFile(path: path, content: defaultFileContent(for: finalName))
            await loadTree(root: root, path: currentPath(for: root))
            if let item = items(for: root).first(where: { $0.path == path }) {
                await loadFile(item)
            }
            statusMessage = "Created file \(finalName)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func renameItem(root: String, item: WorkspaceItem, newName: String) async {
        guard let api else { return }
        let cleaned = cleanNewItemName(newName)
        guard !cleaned.isEmpty else {
            statusMessage = "Name is required"
            return
        }
        guard cleaned != item.name else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let destination = siblingWorkspacePath(for: item.path, newName: cleaned)
            try await api.movePath(from: item.path, to: destination)
            clearSelectionIfNeeded(paths: [item.path])
            await loadTree(root: root, path: currentPath(for: root))
            if !item.isDirectory, let renamed = items(for: root).first(where: { $0.path == destination }) {
                await loadFile(renamed)
            }
            statusMessage = "Renamed \(item.name) to \(cleaned)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func moveItem(root: String, item: WorkspaceItem, destinationFolder: String) async {
        guard let api else { return }
        let destination = workspacePath(in: root, folder: destinationFolder, name: item.name)
        guard destination != item.path else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await api.movePath(from: item.path, to: destination)
            clearSelectionIfNeeded(paths: [item.path])
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = "Moved \(item.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func copyItem(root: String, item: WorkspaceItem, destinationFolder: String) async {
        await copyItems(root: root, items: [item], destinationFolder: destinationFolder)
    }

    func copyItems(root: String, items: [WorkspaceItem], destinationFolder: String) async {
        guard let api else { return }
        let items = topLevelWorkspaceItems(items)
        guard !items.isEmpty else { return }
        let destinations = items.map { workspacePath(in: root, folder: destinationFolder, name: $0.name) }
        guard Set(destinations).count == destinations.count else {
            statusMessage = "Selected items contain duplicate names."
            return
        }
        let existingPaths = Set(self.items(for: root).map(\.path))
        guard !zip(items, destinations).contains(where: { pair in
            pair.1 == pair.0.path || existingPaths.contains(pair.1)
        }) else {
            statusMessage = "Choose a different destination"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            for (item, destination) in zip(items, destinations) {
                try await api.copyPath(from: item.path, to: destination)
            }
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = items.count == 1 ? "Copied \(items[0].name)" : "Copied \(items.count) items"
        } catch {
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = error.localizedDescription
        }
    }

    func moveTreeItem(root: String, sourcePath: String, into folder: WorkspaceItem?) async {
        await moveTreeItems(root: root, sourcePaths: [sourcePath], into: folder)
    }

    func moveTreeItems(root: String, sourcePaths: [String], into folder: WorkspaceItem?) async {
        guard let api else { return }
        let sourcePathSet = Set(sourcePaths)
        let draggedItems = topLevelWorkspaceItems(items(for: root).filter { sourcePathSet.contains($0.path) })
        guard !draggedItems.isEmpty else {
            statusMessage = "The dragged item no longer exists."
            return
        }
        if let folder {
            guard folder.isDirectory else { return }
            guard !draggedItems.contains(where: {
                folder.path == $0.path || folder.path.hasPrefix($0.path + "/")
            }) else {
                statusMessage = "A folder cannot be moved into itself."
                return
            }
        }
        let destinationFolder = folder.map { nestedPath(root: root, workspacePath: $0.path) } ?? ""
        let destinations = draggedItems.map { workspacePath(in: root, folder: destinationFolder, name: $0.name) }
        guard Set(destinations).count == destinations.count else {
            statusMessage = "Selected items contain duplicate names."
            return
        }
        let sourcePaths = Set(draggedItems.map(\.path))
        let existingPaths = Set(items(for: root).map(\.path)).subtracting(sourcePaths)
        guard !destinations.contains(where: existingPaths.contains) else {
            statusMessage = "An item with the same name already exists in that folder."
            return
        }
        let moves = Array(zip(draggedItems, destinations).filter { $0.0.path != $0.1 })
        guard !moves.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            for (item, destination) in moves {
                try await api.movePath(from: item.path, to: destination)
            }
            clearSelectionIfNeeded(paths: draggedItems.map(\.path))
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = draggedItems.count == 1
                ? "Moved \(draggedItems[0].name)"
                : "Moved \(draggedItems.count) items"
        } catch {
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = error.localizedDescription
        }
    }

    func uploadLocalFile(root: String, fileURL: URL) async {
        guard let api else { return }
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
            if totalBytes >= chunkedUploadThresholdBytes {
                try await uploadChunked(api: api, uploadItemId: uploadId, sourceURL: fileURL, destination: destination, totalBytes: totalBytes)
            } else {
                let data = try Data(contentsOf: fileURL)
                updateUploadItem(uploadId, status: .uploading, progress: 0.15, bytesSent: 0, message: "Uploading")
                try await api.uploadFile(path: destination, data: data)
                updateUploadItem(uploadId, status: .completed, progress: 1, bytesSent: totalBytes, message: "Uploaded")
            }
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
        guard let api else { return }
        let didAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { fileURL.stopAccessingSecurityScopedResource() }
        }
        let baseName = (fileURL.lastPathComponent as NSString).deletingPathExtension
        let pdfName = "\(baseName.isEmpty ? "document" : baseName).pdf"
        let destination = workspacePathForNewItem(root: root, name: pdfName)
        let uploadId = UUID()
        addUploadItem(id: uploadId, root: root, fileURL: fileURL, destination: destination)
        do {
            updateUploadItem(uploadId, status: .reading, progress: 0.1, message: "Reading editable Codmes PDF")
            let packageData = try Data(contentsOf: fileURL)
            let totalBytes = Int64(packageData.count)
            updateUploadItem(uploadId, status: .uploading, progress: 0.45, bytesSent: totalBytes, totalBytes: totalBytes, message: "Restoring PDF and annotations")
            let response = try await api.importCodmesPDFPackage(path: destination, packageData: packageData)
            updateUploadItem(uploadId, status: .completed, progress: 1, bytesSent: totalBytes, totalBytes: totalBytes, message: response.renamed ? "Imported as \(response.path)" : "Imported")
            await loadTree(root: root, path: currentPath(for: root))
            if let item = items(for: root).first(where: { $0.path == response.path }) {
                await loadFile(item)
            }
            statusMessage = response.renamed
                ? "Restored editable PDF as \(response.path)"
                : "Restored editable PDF with Codmes annotations"
        } catch {
            updateUploadItem(uploadId, status: .failed, message: uploadErrorMessage(error))
            statusMessage = error.localizedDescription
        }
    }

    private func importLegacyCodmesPDF(root: String, fileURLs: [URL]) async {
        guard let api else { return }
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
        let destination = workspacePathForNewItem(root: root, name: pdfURL.lastPathComponent)
        let uploadId = UUID()
        addUploadItem(id: uploadId, root: root, fileURL: pdfURL, destination: destination)
        do {
            updateUploadItem(uploadId, status: .reading, progress: 0.1, message: "Reading Codmes package")
            let pdfData = try Data(contentsOf: pdfURL)
            let stateData = try stateURL.map { try Data(contentsOf: $0) }
            updateUploadItem(uploadId, status: .uploading, progress: 0.45, bytesSent: Int64(pdfData.count), totalBytes: Int64(pdfData.count), message: "Importing")
            let response = try await api.importCodmesPDF(path: destination, pdfData: pdfData, codmesData: stateData)
            updateUploadItem(uploadId, status: .completed, progress: 1, bytesSent: Int64(pdfData.count), totalBytes: Int64(pdfData.count), message: response.renamed ? "Imported as \(response.path)" : "Imported")
            await loadTree(root: root, path: currentPath(for: root))
            if let item = items(for: root).first(where: { $0.path == response.path }) {
                await loadFile(item)
            }
            statusMessage = response.annotationsImported ? "Imported PDF with Codmes state" : "Imported PDF"
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
        guard let api else { return }
        let items = topLevelWorkspaceItems(items)
        guard !items.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            for item in items {
                try await api.deletePath(path: item.path)
            }
            clearSelectionIfNeeded(paths: items.map(\.path))
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = items.count == 1 ? "Deleted \(items[0].name)" : "Deleted \(items.count) items"
        } catch {
            await loadTree(root: root, path: currentPath(for: root))
            statusMessage = error.localizedDescription
        }
    }

    func loadFile(_ item: WorkspaceItem) async {
        guard !item.isDirectory, let api else { return }

        let loadID = UUID()
        activeFileLoadID = loadID
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

        defer {
            if activeFileLoadID == loadID {
                isLoading = false
            }
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
                } else if let cached = await fileDiskCache.cachedURL(for: item) {
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
                            await cache.cachedURL(for: Self.streamedPDFPageItem(source: item, pageIndex: pageIndex))
                        },
                        pageCacheWriter: { temporaryURL, pageIndex in
                            try await cache.storeDownloadedFile(
                                temporaryURL,
                                for: Self.streamedPDFPageItem(source: item, pageIndex: pageIndex),
                                limitBytes: limitBytes
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
                if let cached = await fileDiskCache.cachedURL(for: item) {
                    url = cached
                } else {
                    let downloaded = try await api.downloadRawFile(path: item.path, name: item.name)
                    url = try await fileDiskCache.storeDownloadedFile(
                        downloaded,
                        for: item,
                        limitBytes: localFileCacheLimitBytes
                    )
                }
                guard activeFileLoadID == loadID else { return }
                selectedRawFile = RawFilePreview(path: item.path, name: item.name, kind: item.kind, url: url)
                selectedFile = nil
                editorText = ""
            } else {
                let file: FileResponse
                if let cachedURL = await fileDiskCache.cachedURL(for: item),
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
                        limitBytes: localFileCacheLimitBytes
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
        if result.kind == "pdf" {
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
            if kind == "pdf" {
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
                    folderId: nil,
                    folderTitle: nil,
                    projectId: result.target.projectId,
                    projectTitle: nil,
                    pinned: false
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
    }

    func cancelEditingSelectedFile() {
        editorText = selectedFile?.content ?? ""
        isEditingFile = false
    }

    func saveSelectedFile() async {
        guard let api, let selectedFile, selectedFileCanEdit else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await api.writeFile(path: selectedFile.path, content: editorText)
            let updatedFile = FileResponse(
                path: selectedFile.path,
                name: selectedFile.name,
                kind: selectedFile.kind,
                size: response.size,
                modifiedAt: response.modifiedAt,
                content: editorText
            )
            _ = try await fileDiskCache.store(
                Data(editorText.utf8),
                for: WorkspaceItem(
                    name: updatedFile.name,
                    path: updatedFile.path,
                    kind: updatedFile.kind,
                    isDirectory: false,
                    size: updatedFile.size,
                    modifiedAt: updatedFile.modifiedAt
                ),
                limitBytes: localFileCacheLimitBytes
            )
            self.selectedFile = updatedFile
            isEditingFile = false
            statusMessage = "Saved \(updatedFile.name)"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func loadTree(root: String, path: String, showStatus: Bool = true) async {
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
            statusMessage = "Resumed \(session.title)"
        } catch {
            statusMessage = error.localizedDescription
            chatLines.append(ChatLine(role: "system", text: error.localizedDescription))
        }
    }

    func sendChatMessage(_ text: String) async {
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
            try await liveClient.submit(
                sessionId: liveSessionId,
                message: trimmed,
                contextRequest: chatContextRequest(),
                surface: activeChatSurface
            )
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
                        folderId: $0.folderId,
                        folderTitle: $0.folderTitle,
                        projectId: $0.projectId,
                        projectTitle: $0.projectTitle,
                        pinned: $0.pinned
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
                    folderId: $0.folderId,
                    folderTitle: $0.folderTitle,
                    projectId: $0.projectId,
                    projectTitle: $0.projectTitle,
                    pinned: pinned
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
        guard let liveSessionId else {
            statusMessage = "No live session"
            return
        }
        updateApprovalLine(lineId, state: approved ? .approved : .denied)
        do {
            try await liveClient.respondToApproval(sessionId: liveSessionId, approved: approved)
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
        persistStringSet(hiddenModelProviderIds, key: "codmes.hiddenModelProviderIds")
        ensureVisibleSelectedModel()
    }

    func setModelVisible(_ model: HermesModelOption, visible: Bool) {
        if visible {
            hiddenModelIds.remove(model.id)
        } else {
            hiddenModelIds.insert(model.id)
        }
        persistStringSet(hiddenModelIds, key: "codmes.hiddenModelIds")
        ensureVisibleSelectedModel()
    }

    func resetModelVisibility() {
        hiddenModelProviderIds.removeAll()
        hiddenModelIds.removeAll()
        persistStringSet(hiddenModelProviderIds, key: "codmes.hiddenModelProviderIds")
        persistStringSet(hiddenModelIds, key: "codmes.hiddenModelIds")
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
            chatLines.append(ChatLine(role: "approval", text: text.isEmpty ? "Approval requested." : text, approvalState: .pending))
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
            return token
        }
        let legacy = UserDefaults.standard.string(forKey: "workspace.serverAuthToken") ?? ""
        if !legacy.isEmpty, KeychainStore.writeServerAuthToken(legacy) {
            UserDefaults.standard.removeObject(forKey: "workspace.serverAuthToken")
        }
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
    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base
            .appendingPathComponent("Codmes", isDirectory: true)
            .appendingPathComponent("WorkspaceFiles", isDirectory: true)
    }

    func cachedURL(for item: WorkspaceItem) -> URL? {
        let url = cacheURL(for: item)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        touch(url)
        return url
    }

    func storeDownloadedFile(_ temporaryURL: URL, for item: WorkspaceItem, limitBytes: Int64) throws -> URL {
        try prepareDirectory()
        let destination = cacheURL(for: item)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: temporaryURL)
            touch(destination)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
            touch(destination)
        }
        trim(to: limitBytes, keeping: destination)
        return destination
    }

    func store(_ data: Data, for item: WorkspaceItem, limitBytes: Int64) throws -> URL {
        try prepareDirectory()
        let destination = cacheURL(for: item)
        try data.write(to: destination, options: .atomic)
        touch(destination)
        trim(to: limitBytes, keeping: destination)
        return destination
    }

    func usageBytes() -> Int64 {
        cacheEntries().reduce(0) { $0 + $1.size }
    }

    func trim(to limitBytes: Int64, keeping protectedURL: URL?) {
        var entries = cacheEntries()
        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return }
        entries.sort { $0.lastAccess < $1.lastAccess }
        for entry in entries where entry.url != protectedURL {
            guard total > limitBytes else { break }
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    func clear(keeping protectedURL: URL?) {
        for entry in cacheEntries() where entry.url != protectedURL {
            try? fileManager.removeItem(at: entry.url)
        }
    }

    private func cacheURL(for item: WorkspaceItem) -> URL {
        let signature = "\(item.path)\n\(item.size):\(item.modifiedAt)"
        let digest = SHA256.hash(data: Data(signature.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = URL(fileURLWithPath: item.name).pathExtension.lowercased()
        return directory.appendingPathComponent(ext.isEmpty ? digest : "\(digest).\(ext)")
    }

    private func prepareDirectory() throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func touch(_ url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func cacheEntries() -> [(url: URL, size: Int64, lastAccess: Date)] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
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
