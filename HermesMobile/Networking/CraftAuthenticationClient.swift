import Foundation

struct CraftHandshake: Equatable, Sendable {
    let clientID: String
    let protocolVersion: String
    let serverVersion: String?
    let registeredChannels: [String]
}

enum CraftConnectionError: Error, Equatable, LocalizedError {
    case invalidServerURL
    case insecureRemoteConnection
    case tokenRequired
    case authenticationFailed
    case incompatibleProtocol
    case timedOut
    case cannotResolveHost
    case tlsFailure
    case connectionFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Enter a valid Craft WebSocket URL."
        case .insecureRemoteConnection:
            return "Remote Craft servers require a secure wss:// connection."
        case .tokenRequired:
            return "Enter the Craft server token."
        case .authenticationFailed:
            return "The Craft server rejected this token."
        case .incompatibleProtocol:
            return "This Craft server uses an incompatible protocol version."
        case .timedOut:
            return "The Craft server did not respond in time."
        case .cannotResolveHost:
            return "The Craft server hostname could not be resolved."
        case .tlsFailure:
            return "The secure connection to the Craft server failed."
        case .connectionFailed:
            return "Could not connect to the Craft server."
        case .invalidResponse:
            return "The Craft server returned an invalid handshake response."
        }
    }
}

protocol CraftAuthenticating: Sendable {
    func authenticate(token: String) async throws -> CraftHandshake
}

struct CraftAuthenticationClient: CraftAuthenticating, @unchecked Sendable {
    static let protocolVersion = "1.0"

    let serverURL: URL
    var timeout: Duration = .seconds(10)
    var session: URLSession = .shared

    func authenticate(token: String) async throws -> CraftHandshake {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { throw CraftConnectionError.tokenRequired }

        let socket = session.webSocketTask(with: serverURL)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        do {
            return try await withThrowingTaskGroup(of: CraftHandshake.self) { group in
                group.addTask {
                    try await Self.performHandshake(socket: socket, token: trimmedToken)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    socket.cancel(with: .goingAway, reason: nil)
                    throw CraftConnectionError.timedOut
                }

                guard let result = try await group.next() else {
                    throw CraftConnectionError.invalidResponse
                }
                group.cancelAll()
                return result
            }
        } catch let error as CraftConnectionError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        } catch {
            throw CraftConnectionError.connectionFailed
        }
    }

    nonisolated static func normalizedServerURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CraftConnectionError.invalidServerURL }

        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else {
            let host = URLComponents(string: "ws://\(trimmed)")?.host?.lowercased()
            candidate = "\(isLoopback(host) ? "ws" : "wss")://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              let host = components.host?.lowercased(),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss" else {
            throw CraftConnectionError.invalidServerURL
        }
        guard scheme == "wss" || isLoopback(host) else {
            throw CraftConnectionError.insecureRemoteConnection
        }

        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw CraftConnectionError.invalidServerURL }
        return url
    }

    private nonisolated static func isLoopback(_ host: String?) -> Bool {
        guard let host else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func performHandshake(
        socket: URLSessionWebSocketTask,
        token: String
    ) async throws -> CraftHandshake {
        let requestID = UUID().uuidString
        let request = HandshakeRequest(
            id: requestID,
            type: "handshake",
            protocolVersion: protocolVersion,
            token: token
        )
        let requestData = try JSONEncoder().encode(request)
        try await socket.send(.data(requestData))

        let message = try await socket.receive()
        let responseData: Data
        switch message {
        case .data(let data): responseData = data
        case .string(let string): responseData = Data(string.utf8)
        @unknown default: throw CraftConnectionError.invalidResponse
        }

        let response = try JSONDecoder().decode(HandshakeResponse.self, from: responseData)
        guard response.id == requestID else { throw CraftConnectionError.invalidResponse }

        if response.type == "error" {
            switch response.error?.code {
            case "AUTH_FAILED": throw CraftConnectionError.authenticationFailed
            case "PROTOCOL_VERSION_UNSUPPORTED": throw CraftConnectionError.incompatibleProtocol
            default: throw CraftConnectionError.invalidResponse
            }
        }

        guard response.type == "handshake_ack",
              let clientID = response.clientId,
              !clientID.isEmpty,
              let version = response.protocolVersion,
              version.split(separator: ".").first == protocolVersion.split(separator: ".").first else {
            throw CraftConnectionError.invalidResponse
        }
        return CraftHandshake(
            clientID: clientID,
            protocolVersion: version,
            serverVersion: response.serverVersion,
            registeredChannels: response.registeredChannels ?? []
        )
    }

    private nonisolated static func map(_ error: URLError) -> CraftConnectionError {
        switch error.code {
        case .timedOut: return .timedOut
        case .cannotFindHost, .dnsLookupFailed: return .cannotResolveHost
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return .tlsFailure
        default: return .connectionFailed
        }
    }

    private struct HandshakeRequest: Encodable {
        let id: String
        let type: String
        let protocolVersion: String
        let token: String
    }

    private struct HandshakeResponse: Decodable {
        let id: String?
        let type: String?
        let protocolVersion: String?
        let clientId: String?
        let serverVersion: String?
        let registeredChannels: [String]?
        let error: ErrorPayload?
    }

    private struct ErrorPayload: Decodable {
        let code: String?
    }
}
