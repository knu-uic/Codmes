import Foundation

enum WorkspaceAPIError: Error, LocalizedError {
    case invalidURL
    case badStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid workspace server URL."
        case let .badStatus(status, body):
            if status == 401 {
                "Workspace server rejected the request. Check the server token in Settings."
            } else {
                "Workspace server returned \(status): \(body)"
            }
        }
    }
}

struct WorkspaceAPI {
    var baseURL: URL
    var authToken: String = ""
    var session: URLSession = .shared

    func workspace() async throws -> WorkspaceInfo {
        try await get("/api/workspace")
    }

    func health() async throws -> HealthResponse {
        try await get("/api/health")
    }

    func documentJobs() async throws -> [DocumentJob] {
        let response: DocumentJobsResponse = try await get("/api/document-jobs")
        return response.jobs
    }

    func tree(root: String, path: String = "", recursive: Bool = false) async throws -> TreeResponse {
        var components = try components("/api/tree")
        components.queryItems = [
            URLQueryItem(name: "root", value: root),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "recursive", value: recursive ? "true" : "false")
        ]
        return try await request(components)
    }

    func file(path: String) async throws -> FileResponse {
        var components = try components("/api/file")
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return try await request(components)
    }

    func rawURL(path: String) throws -> URL {
        var components = try components("/api/raw")
        components.queryItems = authQueryItems([URLQueryItem(name: "path", value: path)])
        guard let url = components.url else { throw WorkspaceAPIError.invalidURL }
        return url
    }

    func pdfThumbnailURL(
        path: String,
        page: Int,
        crop: NormalizedBoundingBox? = nil,
        highlightQuery: String? = nil,
        scale: Double? = nil
    ) throws -> URL {
        var components = try components("/api/pdf-thumbnail")
        var queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "renderVersion", value: "9")
        ]
        if let crop {
            queryItems.append(contentsOf: [
                URLQueryItem(name: "x", value: String(crop.x)),
                URLQueryItem(name: "y", value: String(crop.y)),
                URLQueryItem(name: "width", value: String(crop.width)),
                URLQueryItem(name: "height", value: String(crop.height))
            ])
        }
        if let highlightQuery, !highlightQuery.isEmpty {
            queryItems.append(URLQueryItem(name: "highlight", value: highlightQuery))
        }
        if let scale {
            queryItems.append(URLQueryItem(name: "scale", value: String(scale)))
        }
        components.queryItems = authQueryItems(queryItems)
        guard let url = components.url else { throw WorkspaceAPIError.invalidURL }
        return url
    }

    func pdfMetadata(path: String) async throws -> PDFMetadataResponse {
        var components = try components("/api/pdf/metadata")
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return try await request(components)
    }

    func downloadPDFSkeleton(path: String, name: String) async throws -> URL {
        var components = try components("/api/pdf/skeleton")
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components.url else { throw WorkspaceAPIError.invalidURL }
        return try await downloadFile(url: url, name: "skeleton-\(name)")
    }

    func downloadPDFPage(path: String, page: Int, name: String) async throws -> URL {
        var components = try components("/api/pdf/page")
        components.queryItems = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "page", value: String(page))
        ]
        guard let url = components.url else { throw WorkspaceAPIError.invalidURL }
        return try await downloadFile(url: url, name: "page-\(page)-\(name)")
    }

    func downloadRawFile(path: String, name: String) async throws -> URL {
        let url = try rawURL(path: path)
        return try await downloadFile(url: url, name: name)
    }

    private func downloadFile(url: URL, name: String) async throws -> URL {
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "accept")
        applyAuth(to: &request)
        let (downloadURL, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? String(contentsOf: downloadURL, encoding: .utf8)) ?? ""
            throw WorkspaceAPIError.badStatus(status, body)
        }
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CodmesRawPreviews", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let fileURL = temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + name)
        try fileManager.moveItem(at: downloadURL, to: fileURL)
        return fileURL
    }

    func writeFile(path: String, content: String) async throws -> FileWriteResponse {
        var components = try components("/api/file")
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        let body = ["content": content]
        return try await request(components, method: "PUT", body: body)
    }

    func createFile(path: String, content: String = "") async throws {
        let body = [
            "path": path,
            "content": content
        ]
        let _: EmptyResponse = try await post("/api/file", body: body)
    }

    func createFolder(path: String) async throws {
        let body = ["path": path]
        let _: EmptyResponse = try await post("/api/folder", body: body)
    }

    func movePath(from: String, to: String) async throws {
        let body = [
            "from": from,
            "to": to
        ]
        let _: EmptyResponse = try await request(try components("/api/file/move"), method: "PATCH", body: body)
    }

    func copyPath(from: String, to: String) async throws {
        let body = [
            "from": from,
            "to": to
        ]
        let _: EmptyResponse = try await post("/api/file/copy", body: body)
    }

    func uploadFile(path: String, data: Data) async throws {
        let body = [
            "path": path,
            "dataBase64": data.base64EncodedString()
        ]
        let _: EmptyResponse = try await post("/api/file/upload", body: body)
    }

    func replaceBinaryFile(path: String, data: Data) async throws {
        let body = [
            "path": path,
            "dataBase64": data.base64EncodedString()
        ]
        let components = try components("/api/file/binary")
        let _: EmptyResponse = try await request(components, method: "PUT", body: body)
    }

    func importCodmesPDF(path: String, pdfData: Data, codmesData: Data?) async throws -> CodmesPDFImportResponse {
        try await post("/api/file/import-codmes-pdf", body: CodmesPDFImportBody(
            path: path,
            pdfDataBase64: pdfData.base64EncodedString(),
            codmesDataBase64: codmesData?.base64EncodedString()
        ))
    }

    func exportCodmesPDFPackage(name: String, pdfData: Data, codmesData: Data) async throws -> CodmesPDFExportResponse {
        try await post("/api/file/export-codmes-pdf", body: CodmesPDFExportBody(
            name: name,
            pdfDataBase64: pdfData.base64EncodedString(),
            codmesDataBase64: codmesData.base64EncodedString()
        ))
    }

    func importCodmesPDFPackage(path: String, packageData: Data) async throws -> CodmesPDFImportResponse {
        try await post("/api/file/import-codmes-pdf-package", body: CodmesPDFPackageImportBody(
            path: path,
            packageDataBase64: packageData.base64EncodedString()
        ))
    }

    func startChunkedUpload(path: String, size: Int64) async throws -> UploadStartResponse {
        try await post("/api/file/upload/start", body: ChunkedUploadStartBody(path: path, size: size))
    }

    func uploadChunk(uploadId: String, offset: Int64, data: Data) async throws -> UploadChunkResponse {
        try await post("/api/file/upload/chunk", body: ChunkedUploadChunkBody(
            uploadId: uploadId,
            offset: offset,
            dataBase64: data.base64EncodedString()
        ))
    }

    func completeChunkedUpload(uploadId: String) async throws {
        let _: EmptyResponse = try await post("/api/file/upload/complete", body: ChunkedUploadIDBody(uploadId: uploadId))
    }

    func cancelChunkedUpload(uploadId: String) async throws {
        let _: EmptyResponse = try await post("/api/file/upload/cancel", body: ChunkedUploadIDBody(uploadId: uploadId))
    }

    func deletePath(path: String) async throws {
        var components = try components("/api/file")
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        let _: EmptyResponse = try await request(components, method: "DELETE")
    }

    func fileAnnotations(path: String) async throws -> PDFAnnotationDocument {
        var components = try components("/api/file/annotations")
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return try await request(components)
    }

    func saveFileAnnotations(path: String, annotations: PDFAnnotationDocument) async throws -> PDFAnnotationDocument {
        var components = try components("/api/file/annotations")
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return try await request(components, method: "PUT", body: annotations)
    }

    func renderMarkdown(markdown: String) async throws -> String {
        let response: RenderedMarkdownResponse = try await post("/api/render/markdown", body: ["markdown": markdown])
        return response.html
    }

    func renderCode(code: String, language: String?) async throws -> String {
        var body = ["code": code]
        if let language, !language.isEmpty {
            body["language"] = language
        }
        let response: RenderedMarkdownResponse = try await post("/api/render/code", body: body)
        return response.html
    }

    func search(query: String, scopePath: String) async throws -> SearchResponse {
        let body = [
            "query": query,
            "scopePath": scopePath
        ]
        return try await post("/api/search", body: body)
    }

    func globalSearch(
        query: String,
        surface: String,
        cursor: String? = nil,
        limit: Int = 100
    ) async throws -> GlobalSearchResponse {
        var components = try components("/api/global-search")
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "surface", value: surface),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))
        ]
        if let cursor, !cursor.isEmpty {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components.queryItems = queryItems
        return try await request(components)
    }

    func agentTasks(type: String? = "code", limit: Int = 50) async throws -> [AgentTaskSummary] {
        var components = try components("/api/agent/tasks")
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let type, !type.isEmpty {
            queryItems.insert(URLQueryItem(name: "type", value: type), at: 0)
        }
        components.queryItems = queryItems
        let response: AgentTasksResponse = try await request(components)
        return response.tasks
    }

    func agentTask(id: String) async throws -> CodeTaskRecord {
        var components = try components("/api/agent/tasks/\(id)")
        components.percentEncodedPath = "/api/agent/tasks/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
        return try await request(components)
    }

    func approvals(status: String = "pending", limit: Int = 50) async throws -> [WorkspaceApproval] {
        var components = try components("/api/agent/approvals")
        components.queryItems = [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        let response: WorkspaceApprovalsResponse = try await request(components)
        return response.approvals
    }

    func resumeAgentTask(id: String) async throws -> AgentTaskActionResponse {
        var components = try components("/api/agent/tasks/\(id)/resume")
        components.percentEncodedPath = "/api/agent/tasks/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/resume"
        return try await request(components, method: "POST", body: EmptyBody())
    }

    func cancelAgentTask(id: String, reason: String? = nil) async throws -> AgentTaskActionResponse {
        var components = try components("/api/agent/tasks/\(id)/cancel")
        components.percentEncodedPath = "/api/agent/tasks/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/cancel"

        struct CancelBody: Encodable {
            let reason: String?
        }

        return try await request(components, method: "POST", body: CancelBody(reason: reason))
    }

    func respondToApproval(id: String, approved: Bool, runChecksAfterApply: Bool = false, checksApproved: Bool = false, reason: String? = nil) async throws -> WorkspaceApprovalRespondResponse {
        var components = try components("/api/agent/approvals/\(id)/respond")
        components.percentEncodedPath = "/api/agent/approvals/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/respond"
        
        struct RespondBody: Encodable {
            let approved: Bool
            let runChecksAfterApply: Bool
            let checksApproved: Bool
            let reason: String?
        }
        
        return try await request(components, method: "POST", body: RespondBody(
            approved: approved,
            runChecksAfterApply: runChecksAfterApply,
            checksApproved: checksApproved,
            reason: reason
        ))
    }

    func createCodeTask(scopePath: String, instruction: String) async throws -> CodeTaskResponse {
        try await post("/api/agent/code-task", body: CodeTaskCreateBody(
            scopePath: scopePath,
            instruction: instruction,
            maxFiles: 160,
            maxSearchResults: 10
        ))
    }

    func applyCodePatch(taskId: String, proposalId: String, runChecksAfterApply: Bool = false) async throws -> CodePatchApplyResponse {
        var components = try components("/api/agent/code-task/\(taskId)/patches/\(proposalId)/apply")
        components.percentEncodedPath = "/api/agent/code-task/\(taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskId)/patches/\(proposalId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proposalId)/apply"
        return try await request(components, method: "POST", body: PatchApplyBody(
            approved: true,
            runChecksAfterApply: runChecksAfterApply,
            checksApproved: runChecksAfterApply
        ))
    }

    func rejectCodePatch(taskId: String, proposalId: String, reason: String = "Rejected in Apple client.") async throws -> CodePatchRejectResponse {
        var components = try components("/api/agent/code-task/\(taskId)/patches/\(proposalId)/reject")
        components.percentEncodedPath = "/api/agent/code-task/\(taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskId)/patches/\(proposalId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? proposalId)/reject"
        return try await request(components, method: "POST", body: RejectPatchBody(reason: reason))
    }

    func runCodeChecks(taskId: String) async throws -> CodeChecksResponse {
        var components = try components("/api/agent/code-task/\(taskId)/checks")
        components.percentEncodedPath = "/api/agent/code-task/\(taskId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskId)/checks"
        return try await request(components, method: "POST", body: ApprovedBody(approved: true))
    }

    func hermesModelOptions() async throws -> [HermesModelOption] {
        let data = try await dataRequest(try components("/api/models"))
        let object = try JSONSerialization.jsonObject(with: data)
        return extractHermesModels(from: object)
    }

    func runtimeProviders() async throws -> [RuntimeProviderOption] {
        let response: RuntimeProvidersResponse = try await get("/api/providers")
        return response.providers
    }

    func runtimeProviderModels(providerId: String) async throws -> RuntimeProviderModelsResponse {
        var components = try components("/api/providers/\(providerId)/models")
        components.percentEncodedPath = "/api/providers/\(providerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerId)/models"
        return try await request(components)
    }

    func updateRuntimeProviderAuth(providerId: String, values: [String: String]) async throws {
        var components = try components("/api/auth/\(providerId)")
        components.percentEncodedPath = "/api/auth/\(providerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerId)"
        let _: EmptyResponse = try await request(components, method: "POST", body: ["values": values])
    }

    func runtimeProviderAuth(providerId: String) async throws -> RuntimeProviderAuthResponse {
        var components = try components("/api/auth/\(providerId)")
        components.percentEncodedPath = "/api/auth/\(providerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerId)"
        return try await request(components)
    }

    func selectRuntimeProviderCredential(providerId: String, credentialId: String) async throws {
        var components = try components("/api/auth/\(providerId)/select")
        components.percentEncodedPath = "/api/auth/\(providerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerId)/select"
        let _: EmptyResponse = try await request(components, method: "POST", body: ["credentialId": credentialId])
    }

    func deleteRuntimeProviderCredential(providerId: String, credentialId: String) async throws {
        var components = try components("/api/auth/\(providerId)/credentials/\(credentialId)")
        components.percentEncodedPath = "/api/auth/\(providerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerId)/credentials/\(credentialId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? credentialId)"
        let _: EmptyResponse = try await request(components, method: "DELETE")
    }

    func deleteRuntimeProviderAuth(providerId: String) async throws {
        var components = try components("/api/auth/\(providerId)")
        components.percentEncodedPath = "/api/auth/\(providerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerId)"
        let _: EmptyResponse = try await request(components, method: "DELETE")
    }

    func startOpenAICodexLogin() async throws -> RuntimeOAuthLoginSession {
        try await post("/api/auth/openai-codex/login/start", body: EmptyBody())
    }

    func runtimeOAuthLogin(providerId: String, sessionId: String) async throws -> RuntimeOAuthLoginSession {
        var components = try components("/api/auth/\(providerId)/login/\(sessionId)")
        components.percentEncodedPath = "/api/auth/\(providerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerId)/login/\(sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)"
        return try await request(components)
    }

    func cancelRuntimeOAuthLogin(providerId: String, sessionId: String) async throws {
        var components = try components("/api/auth/\(providerId)/login/\(sessionId)/cancel")
        components.percentEncodedPath = "/api/auth/\(providerId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? providerId)/login/\(sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)/cancel"
        let _: EmptyResponse = try await request(components, method: "POST")
    }

    func runtimeDefaultModel() async throws -> RuntimeDefaultModel? {
        let response: RuntimeDefaultModelResponse = try await get("/api/model/default")
        return response.defaultModel
    }

    func setRuntimeDefaultModel(provider: String, model: String, baseUrl: String? = nil) async throws {
        var body = ["provider": provider, "model": model]
        if let baseUrl, !baseUrl.isEmpty { body["baseUrl"] = baseUrl }
        let _: EmptyResponse = try await post("/api/model/default", body: body)
    }

    func conversationFolders() async throws -> [ConversationFolder] {
        try await get("/api/conversation-folders")
    }

    func createConversationFolder(name: String) async throws -> ConversationFolder {
        try await post("/api/conversation-folders", body: ["name": name])
    }

    func deleteConversationFolder(folderId: String) async throws {
        var components = try components("/api/conversation-folders/\(folderId)")
        components.percentEncodedPath = "/api/conversation-folders/\(folderId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? folderId)"
        let _: EmptyResponse = try await request(components, method: "DELETE")
    }

    func moveSessionToFolder(sessionId: String, folderId: String?) async throws {
        var components = try components("/api/sessions/\(sessionId)/move-to-folder")
        components.percentEncodedPath = "/api/sessions/\(sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)/move-to-folder"
        let body: [String: String] = ["folderId": folderId ?? ""]
        let _: EmptyResponse = try await request(components, method: "POST", body: body)
    }

    func surfaces() async throws -> [WorkspaceSurface] {
        let response: WorkspaceSurfacesResponse = try await get("/api/surfaces")
        return response.surfaces
    }

    func updateSurface(id: String, body: SurfaceUpdateBody) async throws -> WorkspaceSurface {
        var components = try components("/api/surfaces/\(id)")
        components.percentEncodedPath = "/api/surfaces/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
        return try await request(components, method: "POST", body: body)
    }

    func mcpServers() async throws -> [MCPServerConfig] {
        let response: MCPServersResponse = try await get("/api/mcp")
        return response.servers
    }

    func searchConfig() async throws -> SearchConfigResponse {
        try await get("/api/search/config")
    }

    func updateSearchConfig(body: SearchConfigUpdateBody) async throws -> SearchConfigResponse {
        try await post("/api/search/config", body: body)
    }

    func addMCPServer(body: MCPServerUpdateBody) async throws -> MCPServerConfig {
        struct Response: Decodable {
            let server: MCPServerConfig
        }
        let response: Response = try await post("/api/mcp", body: body)
        return response.server
    }

    func updateMCPServer(name: String, body: MCPServerUpdateBody) async throws -> MCPServerConfig {
        struct Response: Decodable {
            let server: MCPServerConfig
        }
        var components = try components("/api/mcp/\(name)")
        components.percentEncodedPath = "/api/mcp/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)"
        let response: Response = try await request(components, method: "POST", body: body)
        return response.server
    }

    func setMCPServerEnabled(name: String, enabled: Bool) async throws -> MCPServerConfig {
        struct Response: Decodable {
            let server: MCPServerConfig
        }
        let action = enabled ? "enable" : "disable"
        var components = try components("/api/mcp/\(name)/\(action)")
        components.percentEncodedPath = "/api/mcp/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)/\(action)"
        let response: Response = try await request(components, method: "POST", body: EmptyBody())
        return response.server
    }

    func deleteMCPServer(name: String) async throws {
        var components = try components("/api/mcp/\(name)")
        components.percentEncodedPath = "/api/mcp/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)"
        let _: EmptyResponse = try await request(components, method: "DELETE")
    }

    func hermesSessions() async throws -> [HermesSessionSummary] {
        let data = try await dataRequest(try components("/api/sessions"))
        let object = try JSONSerialization.jsonObject(with: data)
        return extractHermesSessions(from: object)
    }

    func hermesSessionMessages(sessionId: String) async throws -> [HermesSessionMessage] {
        var components = try components("/api/sessions/\(sessionId)/messages")
        components.percentEncodedPath = "/api/sessions/\(sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)/messages"
        let response: HermesSessionMessagesResponse = try await request(components)
        return response.messages
    }

    func deleteHermesSession(sessionId: String) async throws {
        var components = try components("/api/sessions/\(sessionId)")
        components.percentEncodedPath = "/api/sessions/\(sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)"
        let _: EmptyResponse = try await request(components, method: "DELETE")
    }

    func renameHermesSession(sessionId: String, title: String) async throws {
        var components = try components("/api/sessions/\(sessionId)/rename")
        components.percentEncodedPath = "/api/sessions/\(sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId)/rename"
        let _: EmptyResponse = try await request(components, method: "POST", body: ["title": title])
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await request(try components(path))
    }

    private func post<T: Decodable, Body: Encodable>(_ path: String, body: Body) async throws -> T {
        try await request(try components(path), method: "POST", body: body)
    }

    private func components(_ path: String) throws -> URLComponents {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WorkspaceAPIError.invalidURL
        }
        components.path = path
        return components
    }

    private func request<T: Decodable>(_ components: URLComponents, method: String = "GET", body: (some Encodable)? = Optional<String>.none) async throws -> T {
        let data = try await dataRequest(components, method: method, body: body)
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func dataRequest(_ components: URLComponents, method: String = "GET", body: (some Encodable)? = Optional<String>.none) async throws -> Data {
        guard let url = components.url else { throw WorkspaceAPIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "accept")
        applyAuth(to: &request)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw WorkspaceAPIError.badStatus(status, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func applyAuth(to request: inout URLRequest) {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
    }

    private func authQueryItems(_ items: [URLQueryItem]) -> [URLQueryItem] {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return items }
        return items + [URLQueryItem(name: "token", value: token)]
    }
}

struct EmptyResponse: Codable {}

struct CodmesPDFImportResponse: Codable {
    let ok: Bool
    let path: String
    let requestedPath: String
    let renamed: Bool
    let annotationsImported: Bool
}

struct CodmesPDFExportResponse: Codable {
    let ok: Bool
    let fileName: String
    let dataBase64: String
}

private struct CodmesPDFImportBody: Encodable {
    let path: String
    let pdfDataBase64: String
    let codmesDataBase64: String?
}

private struct CodmesPDFExportBody: Encodable {
    let name: String
    let pdfDataBase64: String
    let codmesDataBase64: String
}

private struct CodmesPDFPackageImportBody: Encodable {
    let path: String
    let packageDataBase64: String
}

private struct ChunkedUploadStartBody: Encodable {
    let path: String
    let size: Int64
}

private struct ChunkedUploadChunkBody: Encodable {
    let uploadId: String
    let offset: Int64
    let dataBase64: String
}

private struct ChunkedUploadIDBody: Encodable {
    let uploadId: String
}

private struct CodeTaskCreateBody: Encodable {
    let scopePath: String
    let instruction: String
    let maxFiles: Int
    let maxSearchResults: Int
}

private struct ApprovedBody: Encodable {
    let approved: Bool
}

private struct EmptyBody: Encodable {}

private struct PatchApplyBody: Encodable {
    let approved: Bool
    let runChecksAfterApply: Bool
    let checksApproved: Bool
}

private struct RejectPatchBody: Encodable {
    let reason: String
}

struct AnyEncodable: Encodable {
    let encodeBody: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        encodeBody = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}

private func extractHermesModels(from object: Any) -> [HermesModelOption] {
    var models: [HermesModelOption] = []
    collectHermesModels(from: object, provider: nil, into: &models)
    var seen = Set<String>()
    return models.filter {
        !$0.id.isEmpty
            && $0.id != "<null>"
            && !$0.model.isEmpty
            && $0.model != "<null>"
            && seen.insert($0.id).inserted
    }
}

private func collectHermesModels(from object: Any, provider: String?, into models: inout [HermesModelOption]) {
    if let value = stringValue(object) {
        models.append(HermesModelOption(label: provider.map { "\($0) / \(value)" } ?? value, provider: provider, model: value))
        return
    }
    if let array = object as? [Any] {
        for item in array {
            collectHermesModels(from: item, provider: provider, into: &models)
        }
        return
    }
    guard let dict = object as? [String: Any] else { return }
    let nextProvider = stringValue(dict["provider"])
        ?? stringValue(dict["provider_id"])
        ?? stringValue(dict["providerId"])
        ?? stringValue(dict["name"]).flatMap { dict["models"] != nil ? $0 : nil }
        ?? provider
    if let model = stringValue(dict["model"])
        ?? stringValue(dict["model_id"])
        ?? stringValue(dict["modelId"])
        ?? stringValue(dict["id"]).flatMap({ dict["models"] == nil ? $0 : nil }) {
        let label = stringValue(dict["label"])
            ?? stringValue(dict["display_name"])
            ?? stringValue(dict["displayName"])
            ?? stringValue(dict["name"]).flatMap { $0 == nextProvider ? nil : $0 }
            ?? nextProvider.map { "\($0) / \(model)" }
            ?? model
        models.append(HermesModelOption(label: label, provider: nextProvider, model: model))
    }
    for key in ["models", "options", "model_options", "modelOptions", "items", "providers"] {
        if let nested = dict[key] {
            collectHermesModels(from: nested, provider: nextProvider, into: &models)
        }
    }
}

private func extractHermesSessions(from object: Any) -> [HermesSessionSummary] {
    var sessions: [HermesSessionSummary] = []
    collectHermesSessions(from: object, into: &sessions)
    var seen = Set<String>()
    return sessions.filter {
        !$0.id.isEmpty
            && $0.id != "<null>"
            && seen.insert($0.id).inserted
    }
}

private func collectHermesSessions(from object: Any, into sessions: inout [HermesSessionSummary]) {
    if let array = object as? [Any] {
        for item in array {
            collectHermesSessions(from: item, into: &sessions)
        }
        return
    }
    guard let dict = object as? [String: Any] else { return }
    if let id = stringValue(dict["id"])
        ?? stringValue(dict["session_id"])
        ?? stringValue(dict["sessionId"])
        ?? stringValue(dict["stored_session_id"])
        ?? stringValue(dict["storedSessionId"]) {
        if boolValue(dict["archived"]) == true {
            return
        }
        let preview = stringValue(dict["preview"])
        let messageCount = intValue(dict["message_count"]) ?? intValue(dict["messageCount"]) ?? 0
        let explicitTitle = stringValue(dict["display_name"])
            ?? stringValue(dict["displayName"])
            ?? stringValue(dict["title"])
            ?? stringValue(dict["name"])
            ?? stringValue(dict["summary"])
        let title = explicitTitle
            ?? preview
            ?? fallbackSessionTitle(model: stringValue(dict["model"]), id: id)
        let updatedAt = stringValue(dict["updated_at"])
            ?? stringValue(dict["updatedAt"])
            ?? stringValue(dict["modified_at"])
            ?? stringValue(dict["modifiedAt"])
            ?? stringValue(dict["last_active"])
            ?? stringValue(dict["lastActive"])
        let projectObject = dict["project"] as? [String: Any]
        let workspaceObject = dict["workspace"] as? [String: Any]
        let projectIdCandidates: [Any?] = [
            dict["project_id"], dict["projectId"], dict["workspace_id"], dict["workspaceId"],
            projectObject?["id"], workspaceObject?["id"]
        ]
        let projectTitleCandidates: [Any?] = [
            dict["project_title"], dict["projectTitle"], dict["workspace_title"], dict["workspaceTitle"],
            dict["cwd"], dict["git_repo_root"], dict["gitRepoRoot"],
            projectObject?["title"], projectObject?["name"], workspaceObject?["title"], workspaceObject?["name"]
        ]
        let projectId = projectIdCandidates.compactMap { stringValue($0) }.first
        let projectTitle = projectTitleCandidates.compactMap { stringValue($0) }.first
        let folderId = stringValue(dict["folder_id"]) ?? stringValue(dict["folderId"])
        let folderTitle = stringValue(dict["folder_title"]) ?? stringValue(dict["folderTitle"])
        if messageCount > 0 || preview != nil || explicitTitle != nil {
            sessions.append(HermesSessionSummary(id: id, title: title, updatedAt: updatedAt, folderId: folderId, folderTitle: folderTitle, projectId: projectId, projectTitle: projectTitle))
        }
    }
    for key in ["sessions", "items", "data", "results"] {
        if let nested = dict[key] {
            collectHermesSessions(from: nested, into: &sessions)
        }
    }
}

private func stringValue(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }

    if let value = value as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "<null>" ? nil : trimmed
    }

    if let value = value as? NSNumber {
        return value.stringValue
    }

    return nil
}

private func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = stringValue(value) { return Int(value) }
    return nil
}

private func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = stringValue(value) {
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
    return nil
}

private func fallbackSessionTitle(model: String?, id: String) -> String {
    if let model {
        return "Chat with \(model)"
    }
    if let date = generatedSessionDate(id) {
        return "Chat \(date)"
    }
    return "Untitled chat"
}

private func generatedSessionDate(_ id: String) -> String? {
    let pattern = #"^(\d{4})(\d{2})(\d{2})_(\d{2})(\d{2})(\d{2})_"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
          match.numberOfRanges >= 7 else {
        return nil
    }
    let parts = (1..<7).compactMap { index -> String? in
        guard let range = Range(match.range(at: index), in: id) else { return nil }
        return String(id[range])
    }
    guard parts.count == 6 else { return nil }
    return "\(parts[0])-\(parts[1])-\(parts[2]) \(parts[3]):\(parts[4])"
}
