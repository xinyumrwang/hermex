import XCTest
@testable import HermesMobile

@MainActor
final class CraftAuthenticationTests: XCTestCase {
    func testNormalizerDefaultsLoopbackToPlainWebSocket() throws {
        XCTAssertEqual(
            try CraftAuthenticationClient.normalizedServerURL(from: "127.0.0.1:9100").absoluteString,
            "ws://127.0.0.1:9100"
        )
        XCTAssertEqual(
            try CraftAuthenticationClient.normalizedServerURL(from: "ws://LOCALHOST:9100/path?q=1").absoluteString,
            "ws://localhost:9100"
        )
    }

    func testNormalizerRequiresTLSForRemoteCraftServer() throws {
        XCTAssertThrowsError(
            try CraftAuthenticationClient.normalizedServerURL(from: "ws://craft.example.test:9100")
        ) { error in
            XCTAssertEqual(error as? CraftConnectionError, .insecureRemoteConnection)
        }
        XCTAssertEqual(
            try CraftAuthenticationClient.normalizedServerURL(from: "craft.example.test:9100").absoluteString,
            "wss://craft.example.test:9100"
        )
    }

    func testConfigureCraftPersistsScopedTokenOnlyAfterHandshake() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())
        let craft = MockCraftAuthenticator(result: .success(Self.handshake))
        let manager = makeManager(keychain: keychain, registry: registry, craft: craft)

        await manager.configureCraft(serverURLString: "127.0.0.1:9100", token: "  secret-token  ")

        let server = try XCTUnwrap(URL(string: "ws://127.0.0.1:9100"))
        XCTAssertEqual(manager.state, .loggedIn(server: server))
        XCTAssertEqual(manager.activeServerKind, .craft)
        XCTAssertEqual(registry.activeServer?.kind, .craft)
        XCTAssertEqual(keychain.savedValues[.serverURL], server.absoluteString)
        XCTAssertEqual(keychain.scopedValue(.craftToken, scope: server.absoluteString), "secret-token")
        XCTAssertEqual(craft.tokens, ["secret-token"])
    }

    func testRejectedCraftTokenLeavesNoConfigurationOrCredential() async {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())
        let craft = MockCraftAuthenticator(result: .failure(CraftConnectionError.authenticationFailed))
        let manager = makeManager(keychain: keychain, registry: registry, craft: craft)

        await manager.configureCraft(serverURLString: "127.0.0.1:9100", token: "wrong")

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertTrue(registry.servers.isEmpty)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertNil(keychain.scopedValue(.craftToken, scope: "ws://127.0.0.1:9100"))
        XCTAssertEqual(manager.lastErrorMessage, CraftConnectionError.authenticationFailed.localizedDescription)
    }

    func testCraftTokensStayIsolatedAndRemovalClearsOnlyTargetServer() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())
        let craft = MockCraftAuthenticator(result: .success(Self.handshake))
        let manager = makeManager(keychain: keychain, registry: registry, craft: craft)

        await manager.configureCraft(serverURLString: "127.0.0.1:9100", token: "alpha")
        await manager.configureCraft(serverURLString: "localhost:9200", token: "beta")
        let alpha = try XCTUnwrap(manager.servers.first { $0.id == "ws://127.0.0.1:9100" })

        await manager.removeServer(alpha)

        XCTAssertNil(keychain.scopedValue(.craftToken, scope: "ws://127.0.0.1:9100"))
        XCTAssertEqual(keychain.scopedValue(.craftToken, scope: "ws://localhost:9200"), "beta")
        XCTAssertEqual(manager.activeServerID, "ws://localhost:9200")
    }

    func testCraftSignOutDoesNotCallHermesLogoutAndDeletesToken() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())
        let craft = MockCraftAuthenticator(result: .success(Self.handshake))
        let hermes = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: true))
        let manager = makeManager(keychain: keychain, registry: registry, craft: craft, hermes: hermes)

        await manager.configureCraft(serverURLString: "localhost:9100", token: "secret")
        await manager.signOut()

        XCTAssertEqual(hermes.logoutCallCount, 0)
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.scopedValue(.craftToken, scope: "ws://localhost:9100"))
    }

    func testCraftTokenCanOnlyBeLoadedForItsCraftServer() async throws {
        let keychain = InMemoryKeychainStore()
        let registry = ServerRegistry(keychain: keychain, identityDefaults: .ephemeral())
        let craft = MockCraftAuthenticator(result: .success(Self.handshake))
        let manager = makeManager(keychain: keychain, registry: registry, craft: craft)

        await manager.configureCraft(serverURLString: "localhost:9100", token: "secret")

        XCTAssertEqual(manager.craftToken(for: URL(string: "ws://localhost:9100")!), "secret")
        XCTAssertNil(manager.craftToken(for: URL(string: "ws://localhost:9200")!))
        XCTAssertNil(manager.craftToken(for: URL(string: "https://localhost:9100")!))
    }

    func testCraftSessionEventDecodesStatusAndUserMessageShapesTolerantly() throws {
        let decoder = JSONDecoder()
        let status = try decoder.decode(
            CraftSessionEvent.self,
            from: Data(#"{"type":"status","sessionId":"s1","message":"Thinking","future":true}"#.utf8)
        )
        XCTAssertEqual(status.statusText, "Thinking")

        let user = try decoder.decode(
            CraftSessionEvent.self,
            from: Data(#"{"type":"user_message","sessionId":"s1","message":{"id":"m1","role":"user","content":"Hello","timestamp":1}}"#.utf8)
        )
        XCTAssertEqual(user.message?.content, "Hello")

        let permission = try decoder.decode(
            CraftSessionEvent.self,
            from: Data(#"{"type":"permission_request","sessionId":"s1","request":{"requestId":"p1","toolName":"bash","command":"git status","description":"Run a command"}}"#.utf8)
        )
        XCTAssertEqual(permission.request?.command, "git status")
    }

    func testCraftConnectionDecodesMixedModelVocabulary() throws {
        let connection = try JSONDecoder().decode(
            CraftLLMConnection.self,
            from: Data(#"{"slug":"pi-api-key","name":"OpenAI","providerType":"pi","authType":"api_key","models":["gpt-5",{"id":"gpt-5-mini","name":"Mini"}],"isAuthenticated":true,"isDefault":false,"future":"ok"}"#.utf8)
        )

        XCTAssertEqual(connection.slug, "pi-api-key")
        XCTAssertEqual(connection.models?.count, 2)
        XCTAssertTrue(connection.isAuthenticated)
    }

    func testCraftMessageAdaptsRichTranscriptDataWithoutChangingPresentationModels() throws {
        let message = try JSONDecoder().decode(
            CraftMessage.self,
            from: Data(#"""
            {
                "id":"m1",
                "type":"tool",
                "content":"tool output",
                "timestamp":1000,
                "toolName":"bash",
                "toolUseId":"tool-1",
                "toolInput":{"command":"git status"},
                "toolResult":"clean",
                "toolStatus":"completed",
                "toolDuration":1500,
                "toolIntent":"Inspect the repository",
                "toolDisplayName":"Shell",
                "attachments":[{
                    "id":"a1",
                    "type":"image",
                    "name":"screen.png",
                    "mimeType":"image/png",
                    "size":42,
                    "storedPath":"/workspace/.craft/attachments/screen.png",
                    "thumbnailBase64":"dGh1bWI="
                }],
                "future":"ignored"
            }
            """#.utf8)
        )

        XCTAssertEqual(message.role, "tool")
        XCTAssertEqual(message.toolUseId, "tool-1")
        XCTAssertEqual(message.toolInput?["command"], .string("git status"))
        XCTAssertEqual(message.toolDuration, 1500)
        XCTAssertEqual(message.attachments?.first?.messageAttachment.name, "screen.png")
        XCTAssertEqual(message.attachments?.first?.messageAttachment.mime, "image/png")
        XCTAssertEqual(message.attachments?.first?.messageAttachment.isImage, true)
    }

    func testCraftMessageToleratesMissingAndLossyCoreFields() throws {
        let message = try JSONDecoder().decode(
            CraftMessage.self,
            from: Data(#"{"id":7,"role":false,"content":99,"timestamp":"1234"}"#.utf8)
        )

        XCTAssertEqual(message.id, "7")
        XCTAssertEqual(message.role, "false")
        XCTAssertEqual(message.content, "99")
        XCTAssertEqual(message.timestamp, 1234)
    }

    func testCraftOutgoingAttachmentBuildsTheVerifiedRPCShape() throws {
        let text = CraftOutgoingAttachment(
            name: "notes.md",
            mimeType: "text/markdown",
            data: Data("hello".utf8)
        )
        let image = CraftOutgoingAttachment(
            name: "screen.png",
            mimeType: "image/png",
            data: Data([0, 1, 2])
        )

        XCTAssertEqual(text.type, "text")
        XCTAssertEqual(text.rpcObject["text"], .string("hello"))
        XCTAssertNil(text.rpcObject["base64"])
        XCTAssertEqual(image.type, "image")
        XCTAssertEqual(image.rpcObject["base64"], .string("AAEC"))
        XCTAssertEqual(image.rpcObject["size"], .number(3))
    }

    func testLiveCraftCoreWorkflowWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serverURLString = environment["HERMEX_CRAFT_TEST_URL"],
              let serverURL = URL(string: serverURLString),
              let token = environment["HERMEX_CRAFT_TEST_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("Set HERMEX_CRAFT_TEST_URL and HERMEX_CRAFT_TEST_TOKEN to run the live Craft workflow.")
        }

        let client = CraftRPCClient(serverURL: serverURL, token: token)
        try await client.connect()
        let workspaces: [CraftWorkspace] = try await client.request("server:getWorkspaces")
        let workspace = try XCTUnwrap(workspaces.first)
        let _: JSONValue = try await client.request("window:switchWorkspace", args: [.string(workspace.id)])

        var createdSession: CraftSession?
        do {
            let session: CraftSession = try await client.request(
                "sessions:create",
                args: [.string(workspace.id), .object(["name": .string("Hermex simulator smoke")])]
            )
            createdSession = session

            let listed: [CraftSession] = try await client.request("sessions:get")
            XCTAssertTrue(listed.contains { $0.id == session.id })

            let _: JSONValue = try await client.request(
                "sessions:command",
                args: [.string(session.id), .object(["type": .string("setPermissionMode"), "mode": .string("ask")])]
            )
            let _: JSONValue = try await client.request(
                "sessions:command",
                args: [.string(session.id), .object(["type": .string("setThinkingLevel"), "level": .string("medium")])]
            )

            let acknowledgement: CraftSendAcknowledgement = try await client.request(
                "sessions:sendMessage",
                args: [.string(session.id), .string("Hermex simulator RPC smoke test")]
            )
            XCTAssertTrue(acknowledgement.accepted)
            let loaded: CraftSession? = try await client.request(
                "sessions:getMessages",
                args: [.string(session.id)]
            )
            XCTAssertTrue(loaded?.messages?.contains { $0.content == "Hermex simulator RPC smoke test" } == true)

            let _: JSONValue = try await client.request(
                "sessions:setNotes",
                args: [.string(session.id), .string("simulator verified")]
            )
            let notes: String = try await client.request("sessions:getNotes", args: [.string(session.id)])
            XCTAssertEqual(notes, "simulator verified")
            let _: [CraftSessionFile] = try await client.request("sessions:getFiles", args: [.string(session.id)])
            let _: [CraftLLMConnection] = try await client.request("LLM_Connection:listWithStatus")
            let _: [String] = try await client.request("tasks:list", args: [.string(workspace.id)])
            let _: JSONValue = try await client.request("sessions:cancel", args: [.string(session.id), .bool(true)])
            let _: JSONValue = try await client.request(
                "sessions:command",
                args: [.string(session.id), .object(["type": .string("archive")])]
            )
            let _: JSONValue = try await client.request(
                "sessions:command",
                args: [.string(session.id), .object(["type": .string("unarchive")])]
            )
        } catch {
            if let createdSession {
                let _: JSONValue? = try? await client.request("sessions:delete", args: [.string(createdSession.id)])
            }
            throw error
        }

        if let createdSession {
            let _: JSONValue = try await client.request("sessions:delete", args: [.string(createdSession.id)])
        }
        await client.disconnect()
    }

    private func makeManager(
        keychain: InMemoryKeychainStore,
        registry: ServerRegistry,
        craft: MockCraftAuthenticator,
        hermes: MockAuthAPIClient = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: false, loggedIn: true)
        )
    ) -> AuthManager {
        AuthManager(
            keychain: keychain,
            clientFactory: { _ in hermes },
            craftClientFactory: { _ in craft },
            headerStore: CustomHeaderStore(headers: []),
            serverRegistry: registry
        )
    }

    private static let handshake = CraftHandshake(
        clientID: "client-1",
        protocolVersion: "1.0",
        serverVersion: "0.1.0",
        registeredChannels: ["rpc"]
    )
}

private final class MockCraftAuthenticator: CraftAuthenticating, @unchecked Sendable {
    let result: Result<CraftHandshake, Error>
    private(set) var tokens: [String] = []

    init(result: Result<CraftHandshake, Error>) {
        self.result = result
    }

    func authenticate(token: String) async throws -> CraftHandshake {
        tokens.append(token)
        return try result.get()
    }
}
