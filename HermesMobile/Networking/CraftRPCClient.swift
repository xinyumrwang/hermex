import Foundation

enum CraftRPCError: Error, LocalizedError, Equatable {
    case disconnected
    case invalidEnvelope
    case channelUnavailable(String)
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .disconnected:
            return "The Craft server connection was lost."
        case .invalidEnvelope:
            return "The Craft server returned an invalid response."
        case .channelUnavailable(let channel):
            return "This Craft server does not support \(channel)."
        case .server(_, let message):
            return message
        }
    }
}

struct CraftWorkspace: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var slug: String?
    var lastAccessedAt: Double?
}

struct CraftSession: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var workspaceId: String?
    var workspaceName: String?
    var name: String?
    var preview: String?
    var lastMessageAt: Double?
    var messages: [CraftMessage]?
    var isProcessing: Bool?
    var isFlagged: Bool?
    var hasUnread: Bool?
    var isArchived: Bool?
    var lastMessageRole: String?
    var permissionMode: String?
    var workingDirectory: String?
    var model: String?
    var llmConnection: String?
    var thinkingLevel: String?

    var title: String {
        let candidate = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate?.isEmpty == false ? candidate! : "New conversation"
    }
}

struct CraftMessage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var role: String
    var content: String
    var timestamp: Double?
    var toolName: String?
    var toolUseId: String?
    var toolInput: [String: JSONValue]?
    var toolResult: String?
    var toolStatus: String?
    var toolDuration: Double?
    var toolIntent: String?
    var toolDisplayName: String?
    var parentToolUseId: String?
    var attachments: [CraftStoredAttachment]?
    var isError: Bool?
    var isIntermediate: Bool?
    var hidden: Bool?

    enum CodingKeys: String, CodingKey {
        case id, role, type, content, timestamp, toolName, toolUseId, toolInput
        case toolResult, toolStatus, toolDuration, toolIntent, toolDisplayName
        case parentToolUseId, attachments, isError, isIntermediate, hidden
    }

    init(
        id: String,
        role: String,
        content: String,
        timestamp: Double? = nil,
        toolName: String? = nil,
        toolUseId: String? = nil,
        toolInput: [String: JSONValue]? = nil,
        toolResult: String? = nil,
        toolStatus: String? = nil,
        toolDuration: Double? = nil,
        toolIntent: String? = nil,
        toolDisplayName: String? = nil,
        parentToolUseId: String? = nil,
        attachments: [CraftStoredAttachment]? = nil,
        isError: Bool? = nil,
        isIntermediate: Bool? = nil,
        hidden: Bool? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolUseId = toolUseId
        self.toolInput = toolInput
        self.toolResult = toolResult
        self.toolStatus = toolStatus
        self.toolDuration = toolDuration
        self.toolIntent = toolIntent
        self.toolDisplayName = toolDisplayName
        self.parentToolUseId = parentToolUseId
        self.attachments = attachments
        self.isError = isError
        self.isIntermediate = isIntermediate
        self.hidden = hidden
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeLossyStringIfPresent(forKey: .id) ?? "craft-\(UUID().uuidString)"
        role = container.decodeLossyStringIfPresent(forKey: .role)
            ?? container.decodeLossyStringIfPresent(forKey: .type)
            ?? "unknown"
        content = container.decodeLossyStringIfPresent(forKey: .content) ?? ""
        timestamp = container.decodeLossyDoubleIfPresent(forKey: .timestamp)
        toolName = container.decodeLossyStringIfPresent(forKey: .toolName)
        toolUseId = container.decodeLossyStringIfPresent(forKey: .toolUseId)
        toolInput = try? container.decodeIfPresent([String: JSONValue].self, forKey: .toolInput)
        toolResult = container.decodeLossyStringIfPresent(forKey: .toolResult)
        toolStatus = container.decodeLossyStringIfPresent(forKey: .toolStatus)
        toolDuration = container.decodeLossyDoubleIfPresent(forKey: .toolDuration)
        toolIntent = container.decodeLossyStringIfPresent(forKey: .toolIntent)
        toolDisplayName = container.decodeLossyStringIfPresent(forKey: .toolDisplayName)
        parentToolUseId = container.decodeLossyStringIfPresent(forKey: .parentToolUseId)
        attachments = try? container.decodeIfPresent([CraftStoredAttachment].self, forKey: .attachments)
        isError = container.decodeLossyBoolIfPresent(forKey: .isError)
        isIntermediate = container.decodeLossyBoolIfPresent(forKey: .isIntermediate)
        hidden = container.decodeLossyBoolIfPresent(forKey: .hidden)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encodeIfPresent(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(toolUseId, forKey: .toolUseId)
        try container.encodeIfPresent(toolInput, forKey: .toolInput)
        try container.encodeIfPresent(toolResult, forKey: .toolResult)
        try container.encodeIfPresent(toolStatus, forKey: .toolStatus)
        try container.encodeIfPresent(toolDuration, forKey: .toolDuration)
        try container.encodeIfPresent(toolIntent, forKey: .toolIntent)
        try container.encodeIfPresent(toolDisplayName, forKey: .toolDisplayName)
        try container.encodeIfPresent(parentToolUseId, forKey: .parentToolUseId)
        try container.encodeIfPresent(attachments, forKey: .attachments)
        try container.encodeIfPresent(isError, forKey: .isError)
        try container.encodeIfPresent(isIntermediate, forKey: .isIntermediate)
        try container.encodeIfPresent(hidden, forKey: .hidden)
    }
}

struct CraftSendAcknowledgement: Codable, Equatable, Sendable {
    let accepted: Bool
    let messageId: String
}

struct CraftOperationResult: Codable, Equatable, Sendable {
    let success: Bool
    var error: String?
}

struct CraftLLMConnection: Decodable, Identifiable, Equatable, Sendable {
    var id: String { slug }
    let slug: String
    var name: String
    var providerType: String
    var authType: String
    var models: [JSONValue]?
    var defaultModel: String?
    var isAuthenticated: Bool
    var isDefault: Bool?
    var authError: String?
}

struct CraftSessionFile: Codable, Identifiable, Equatable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let type: String
    var size: Int?
    var children: [CraftSessionFile]?
}

struct CraftPermissionRequest: Codable, Identifiable, Equatable, Sendable {
    var id: String { requestId }
    let requestId: String
    var toolName: String
    var command: String?
    var description: String
    var type: String?
    var appName: String?
    var reason: String?
    var impact: String?
}

struct CraftTaskValidationIssue: Codable, Equatable, Sendable {
    var path: String
    var message: String
    var severity: String
    var suggestion: String?
}

struct CraftTaskValidation: Codable, Equatable, Sendable {
    var valid: Bool
    var errors: [CraftTaskValidationIssue]
    var warnings: [CraftTaskValidationIssue]
}

struct CraftTaskNodeState: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var state: String
    var sessionId: String?
    var attempt: Int
}

struct CraftTaskRun: Codable, Equatable, Sendable {
    var slug: String
    var runId: String
    var taskId: String
    var status: String
    var orchestratorSessionId: String?
    var nodes: [CraftTaskNodeState]
    var tokensUsed: Int
}

struct CraftTaskDetail: Codable, Equatable, Sendable {
    var slug: String
    var validation: CraftTaskValidation
    var spec: JSONValue?
    var run: CraftTaskRun?
}

struct CraftSessionEvent: Decodable, Equatable, Sendable {
    var type: String
    var sessionId: String?
    var delta: String?
    var text: String?
    var message: CraftMessage?
    var error: String?
    var toolName: String?
    var toolUseId: String?
    var result: String?
    var isError: Bool?
    var isIntermediate: Bool?
    var messageId: String?
    var name: String?
    var title: String?
    var statusText: String?
    var request: CraftPermissionRequest?

    init(type: String) {
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case type, sessionId, delta, text, message, error, toolName, toolUseId
        case result, isError, isIntermediate, messageId, name, title, request
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        sessionId = try? container.decode(String.self, forKey: .sessionId)
        delta = try? container.decode(String.self, forKey: .delta)
        text = try? container.decode(String.self, forKey: .text)
        error = try? container.decode(String.self, forKey: .error)
        toolName = try? container.decode(String.self, forKey: .toolName)
        toolUseId = try? container.decode(String.self, forKey: .toolUseId)
        result = try? container.decode(String.self, forKey: .result)
        isError = try? container.decode(Bool.self, forKey: .isError)
        isIntermediate = try? container.decode(Bool.self, forKey: .isIntermediate)
        messageId = try? container.decode(String.self, forKey: .messageId)
        name = try? container.decode(String.self, forKey: .name)
        title = try? container.decode(String.self, forKey: .title)
        request = try? container.decode(CraftPermissionRequest.self, forKey: .request)

        message = try? container.decode(CraftMessage.self, forKey: .message)
        statusText = try? container.decode(String.self, forKey: .message)

        if error == nil,
           let errorValue = try? container.decode(JSONValue.self, forKey: .error),
           case .object(let object) = errorValue {
            if case .string(let message)? = object["message"] {
                error = message
            } else if case .string(let title)? = object["title"] {
                error = title
            }
        }
    }
}

/// A persistent, typed boundary for Craft's WebSocket RPC protocol. The token
/// stays in memory only for the life of this server-bound client; persistence
/// remains owned by the URL-scoped Keychain entry in `AuthManager`.
actor CraftRPCClient {
    static let protocolVersion = "1.0"

    nonisolated let events: AsyncStream<CraftSessionEvent>

    private let serverURL: URL
    private let token: String
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<CraftSessionEvent>.Continuation
    private var pending: [String: PendingRequest] = [:]
    private var registeredChannels: Set<String> = []
    private var clientID: String?
    private var lastSequence = 0

    private struct PendingRequest {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    init(serverURL: URL, token: String, session: URLSession = .shared) {
        self.serverURL = serverURL
        self.token = token
        self.session = session
        var continuation: AsyncStream<CraftSessionEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    deinit {
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        eventContinuation.finish()
    }

    func connect(workspaceID: String? = nil) async throws {
        guard socket == nil else { return }

        let socket = session.webSocketTask(with: serverURL)
        socket.resume()

        do {
            let requestID = UUID().uuidString
            let handshake = CraftWireEnvelope(
                id: requestID,
                type: "handshake",
                protocolVersion: Self.protocolVersion,
                workspaceId: workspaceID,
                token: token,
                reconnectClientId: clientID,
                lastSeq: clientID == nil ? nil : lastSequence
            )
            try await socket.send(.data(try JSONEncoder().encode(handshake)))

            let response = try await withThrowingTaskGroup(of: CraftWireEnvelope.self) { group in
                group.addTask {
                    try await Self.receiveEnvelope(from: socket)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(10))
                    throw CraftConnectionError.timedOut
                }
                guard let first = try await group.next() else {
                    throw CraftRPCError.invalidEnvelope
                }
                group.cancelAll()
                return first
            }

            if let error = response.error {
                throw CraftRPCError.server(code: error.code, message: error.message)
            }
            guard response.id == requestID,
                  response.type == "handshake_ack",
                  let clientID = response.clientId,
                  !clientID.isEmpty else {
                throw CraftRPCError.invalidEnvelope
            }

            self.socket = socket
            self.clientID = clientID
            registeredChannels = Set(response.registeredChannels ?? [])
            if response.reconnected != true || response.stale == true {
                lastSequence = 0
            }
            receiveTask = Task { [weak self] in
                await self?.receiveLoop(socket: socket)
            }
        } catch {
            socket.cancel(with: .goingAway, reason: nil)
            throw error
        }
    }

    func reconnect(workspaceID: String?) async throws {
        closeSocket(finishEvents: false)
        try await connect(workspaceID: workspaceID)
    }

    func disconnect() {
        clientID = nil
        lastSequence = 0
        closeSocket(finishEvents: false)
    }

    func supports(_ channel: String) -> Bool {
        registeredChannels.isEmpty || registeredChannels.contains(channel)
    }

    func request<Result: Decodable>(
        _ channel: String,
        args: [JSONValue] = [],
        as resultType: Result.Type = Result.self
    ) async throws -> Result {
        if socket == nil {
            try await connect()
        }
        guard registeredChannels.isEmpty || registeredChannels.contains(channel) else {
            throw CraftRPCError.channelUnavailable(channel)
        }

        let requestID = UUID().uuidString
        let envelope = CraftWireEnvelope(
            id: requestID,
            type: "request",
            channel: channel,
            args: args
        )
        let value = try await waitForResponse(to: envelope)
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Result.self, from: data)
    }

    func sendMessage(
        sessionID: String,
        text: String,
        attachments: [CraftOutgoingAttachment] = []
    ) async throws -> CraftSendAcknowledgement {
        var processed: [JSONValue] = []
        var stored: [JSONValue] = []
        processed.reserveCapacity(attachments.count)
        stored.reserveCapacity(attachments.count)

        for attachment in attachments {
            let storedAttachment: CraftStoredAttachment = try await request(
                "file:storeAttachment",
                args: [.string(sessionID), attachment.rpcValue]
            )
            var processedAttachment = attachment.rpcObject
            processedAttachment["storedPath"] = .string(storedAttachment.storedPath)
            if let markdownPath = storedAttachment.markdownPath {
                processedAttachment["markdownPath"] = .string(markdownPath)
            }
            if let resizedBase64 = storedAttachment.resizedBase64 {
                processedAttachment["base64"] = .string(resizedBase64)
            }
            processed.append(.object(processedAttachment))
            stored.append(storedAttachment.rpcValue)
        }

        return try await request(
            "sessions:sendMessage",
            args: [
                .string(sessionID),
                .string(text),
                .array(processed),
                .array(stored),
            ]
        )
    }

    private func waitForResponse(to envelope: CraftWireEnvelope) async throws -> JSONValue {
        let requestID = envelope.id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.failPending(
                        id: requestID,
                        error: CraftRPCError.server(code: "REQUEST_TIMEOUT", message: "The Craft request timed out.")
                    )
                }
                pending[requestID] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                Task { [weak self] in
                    await self?.send(envelope, requestID: requestID)
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failPending(id: requestID, error: CancellationError())
            }
        }
    }

    private func send(_ envelope: CraftWireEnvelope, requestID: String) async {
        do {
            guard let socket else { throw CraftRPCError.disconnected }
            try await socket.send(.data(try JSONEncoder().encode(envelope)))
        } catch {
            failPending(id: requestID, error: error)
        }
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let envelope = try await Self.receiveEnvelope(from: socket)
                handle(envelope)
            }
        } catch {
            guard !Task.isCancelled else { return }
            closeSocket(finishEvents: false)
            failAllPending(with: CraftRPCError.disconnected)
            eventContinuation.yield(CraftSessionEvent(type: "connection_lost"))
        }
    }

    private func handle(_ envelope: CraftWireEnvelope) {
        switch envelope.type {
        case "response":
            guard let request = pending.removeValue(forKey: envelope.id) else { return }
            request.timeoutTask.cancel()
            if let error = envelope.error {
                request.continuation.resume(
                    throwing: CraftRPCError.server(code: error.code, message: error.message)
                )
            } else {
                request.continuation.resume(returning: envelope.result ?? .null)
            }
        case "event":
            if let sequence = envelope.seq {
                lastSequence = max(lastSequence, sequence)
                acknowledge(sequence)
            }
            guard envelope.channel == "session:event",
                  let value = envelope.args?.first,
                  let event = try? Self.decode(CraftSessionEvent.self, from: value) else { return }
            eventContinuation.yield(event)
        case "error":
            if let error = envelope.error {
                failAllPending(with: CraftRPCError.server(code: error.code, message: error.message))
            }
        default:
            break
        }
    }

    private func acknowledge(_ sequence: Int) {
        guard let socket else { return }
        let envelope = CraftWireEnvelope(
            id: UUID().uuidString,
            type: "sequence_ack",
            lastSeq: sequence
        )
        Task {
            try? await socket.send(.data(try JSONEncoder().encode(envelope)))
        }
    }

    private func failPending(id: String, error: Error) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func closeSocket(finishEvents: Bool) {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failAllPending(with: CraftRPCError.disconnected)
        if finishEvents {
            eventContinuation.finish()
        }
    }

    private nonisolated static func receiveEnvelope(
        from socket: URLSessionWebSocketTask
    ) async throws -> CraftWireEnvelope {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let payload): data = payload
        case .string(let payload): data = Data(payload.utf8)
        @unknown default: throw CraftRPCError.invalidEnvelope
        }
        return try JSONDecoder().decode(CraftWireEnvelope.self, from: data)
    }

    private nonisolated static func decode<T: Decodable>(
        _ type: T.Type,
        from value: JSONValue
    ) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}

private struct CraftWireEnvelope: Codable, Sendable {
    let id: String
    let type: String
    var channel: String?
    var args: [JSONValue]?
    var result: JSONValue?
    var error: CraftWireError?
    var protocolVersion: String?
    var workspaceId: String?
    var token: String?
    var clientId: String?
    var registeredChannels: [String]?
    var seq: Int?
    var lastSeq: Int?
    var reconnectClientId: String?
    var reconnected: Bool?
    var stale: Bool?

    init(
        id: String,
        type: String,
        channel: String? = nil,
        args: [JSONValue]? = nil,
        protocolVersion: String? = nil,
        workspaceId: String? = nil,
        token: String? = nil,
        reconnectClientId: String? = nil,
        lastSeq: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.channel = channel
        self.args = args
        self.protocolVersion = protocolVersion
        self.workspaceId = workspaceId
        self.token = token
        self.reconnectClientId = reconnectClientId
        self.lastSeq = lastSeq
    }
}

private struct CraftWireError: Codable, Sendable {
    let code: String
    let message: String
}

extension JSONValue {
    static func craftValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
