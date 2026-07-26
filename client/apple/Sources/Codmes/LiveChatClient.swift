import Foundation

enum LiveChatClientError: Error, LocalizedError, Sendable {
    case invalidURL
    case disconnected
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid live WebSocket URL."
        case .disconnected:
            "Live chat is disconnected."
        case let .serverError(message):
            message
        }
    }
}

struct LiveEnvelope: Codable, Sendable {
    let kind: String
    let id: String?
    let type: String?
    let sessionId: String?
    let approvalId: String?
    let text: String?
    let error: String?
    let result: LiveResult?
}

struct LiveResult: Codable, Sendable {
    let ok: Bool?
    let sessionId: String?
    let runtimeSessionId: String?
    let source: String?
}

struct LiveCommand<Params: Encodable>: Encodable {
    let id: String
    let command: String
    let params: Params
}

struct EmptyParams: Encodable {}

struct CreateSessionParams: Encodable {
    let provider: String?
    let model: String?
    let reasoningEffort: String?
    let accessMode: String?
    let surface: String?
    let folderId: String?
}

struct ResumeSessionParams: Encodable {
    let sessionId: String
}

struct PromptSubmitParams: Encodable {
    let sessionId: String
    let message: String
    let contextRequest: ContextRequest?
    let surface: String?
}

struct ApprovalRespondParams: Encodable {
    let approvalId: String
    let approved: Bool
}

struct AccessModeParams: Encodable {
    let sessionId: String
    let accessMode: String
}

struct ReasoningModeParams: Encodable {
    let sessionId: String
    let reasoningEffort: String
}

struct ContextRequest: Encodable {
    let scopeType: String
    let scopePath: String?
    let activePath: String?
}

actor LiveChatClient {
    private var task: URLSessionWebSocketTask?
    private var connectedURL: URL?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var continuations: [String: CheckedContinuation<LiveEnvelope, Error>] = [:]
    private var onEvent: (@Sendable (LiveEnvelope) -> Void)?

    func connect(baseURL: URL, authToken: String = "", onEvent: @escaping @Sendable (LiveEnvelope) -> Void) async throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw LiveChatClientError.invalidURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/api/live"
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        guard let url = components.url else { throw LiveChatClientError.invalidURL }
        self.onEvent = onEvent
        if task != nil, connectedURL == url {
            return
        }
        disconnect()
        let task = URLSession.shared.webSocketTask(with: url)
        self.task = task
        connectedURL = url
        task.resume()
        receiveLoop()
        _ = try await send(command: "connect", params: EmptyParams())
    }

    func createSession(provider: String? = nil, model: String? = nil, reasoningEffort: String? = nil, accessMode: String = "confirm", surface: String? = nil, folderId: String? = nil) async throws -> String {
        let response = try await send(
            command: "session.create",
            params: CreateSessionParams(provider: provider, model: model, reasoningEffort: reasoningEffort, accessMode: accessMode, surface: surface, folderId: folderId)
        )
        guard let sessionId = response.result?.sessionId else {
            throw LiveChatClientError.serverError("Runtime did not return a session id.")
        }
        return sessionId
    }

    func resumeSession(sessionId: String) async throws {
        _ = try await send(
            command: "session.resume",
            params: ResumeSessionParams(sessionId: sessionId)
        )
    }

    func submit(sessionId: String, message: String, contextRequest: ContextRequest? = nil, surface: String? = nil) async throws {
        _ = try await send(
            command: "prompt.submit",
            params: PromptSubmitParams(sessionId: sessionId, message: message, contextRequest: contextRequest, surface: surface)
        )
    }

    func respondToApproval(approvalId: String, approved: Bool) async throws {
        _ = try await send(
            command: "approval.inbox.respond",
            params: ApprovalRespondParams(approvalId: approvalId, approved: approved)
        )
    }

    func setAccessMode(sessionId: String, accessMode: String) async throws {
        _ = try await send(
            command: "config.accessMode",
            params: AccessModeParams(sessionId: sessionId, accessMode: accessMode)
        )
    }

    func setReasoningMode(sessionId: String, reasoningEffort: String) async throws {
        _ = try await send(
            command: "config.reasoning",
            params: ReasoningModeParams(sessionId: sessionId, reasoningEffort: reasoningEffort)
        )
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connectedURL = nil
        for continuation in continuations.values {
            continuation.resume(throwing: LiveChatClientError.disconnected)
        }
        continuations.removeAll()
    }

    private func send<Params: Encodable>(command: String, params: Params) async throws -> LiveEnvelope {
        guard let task else { throw LiveChatClientError.disconnected }
        let id = UUID().uuidString
        let data = try encoder.encode(LiveCommand(id: id, command: command, params: params))
        guard let text = String(data: data, encoding: .utf8) else {
            throw LiveChatClientError.serverError("Could not encode live command.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[id] = continuation
            task.send(.string(text)) { [weak self] error in
                if let error {
                    Task {
                        await self?.failContinuation(id: id, error: error)
                    }
                }
            }
        }
    }

    private func receiveLoop() {
        guard let task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            Task {
                await self.handleReceiveResult(result)
            }
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case let .failure(error):
            task = nil
            connectedURL = nil
            for continuation in continuations.values {
                continuation.resume(throwing: error)
            }
            continuations.removeAll()
        case let .success(message):
            handle(message)
            receiveLoop()
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case let .string(text):
            data = text.data(using: .utf8)
        case let .data(value):
            data = value
        @unknown default:
            data = nil
        }
        guard let data, let envelope = try? decoder.decode(LiveEnvelope.self, from: data) else { return }
        if envelope.kind == "result", let id = envelope.id {
            continuations.removeValue(forKey: id)?.resume(returning: envelope)
            return
        }
        if envelope.kind == "error", let id = envelope.id {
            continuations.removeValue(forKey: id)?.resume(throwing: LiveChatClientError.serverError(envelope.error ?? "Live command failed."))
            return
        }
        onEvent?(envelope)
    }

    private func failContinuation(id: String, error: Error) {
        continuations.removeValue(forKey: id)?.resume(throwing: error)
    }
}
