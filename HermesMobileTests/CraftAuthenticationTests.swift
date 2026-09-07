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
