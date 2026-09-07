import Observation
import SwiftUI

@MainActor
@Observable
final class CraftConnectionSettingsViewModel {
    let client: CraftRPCClient
    private(set) var connections: [CraftLLMConnection] = []
    private(set) var isLoading = false
    private(set) var canConfigure = false
    var errorMessage: String?

    init(client: CraftRPCClient) {
        self.client = client
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        canConfigure = await client.supports("settings:setupLlmConnection")
        do {
            let loaded: [CraftLLMConnection] = try await client.request("LLM_Connection:listWithStatus")
            connections = loaded
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func configure(provider: CraftConnectionProvider, credential: String, baseURL: String) async -> Bool {
        guard canConfigure else {
            errorMessage = CraftRPCError.channelUnavailable("settings:setupLlmConnection").localizedDescription
            return false
        }

        let secret = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        var setup: [String: JSONValue] = ["slug": .string(provider.slug)]
        if !secret.isEmpty { setup["credential"] = .string(secret) }
        if let piProvider = provider.piProvider { setup["piAuthProvider"] = .string(piProvider) }

        if provider == .localOpenAI {
            let endpoint = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: endpoint), let host = url.host else {
                errorMessage = "Enter a valid model endpoint URL."
                return false
            }
            let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
            guard isLoopback || url.scheme == "https" else {
                errorMessage = "Remote model endpoints must use HTTPS."
                return false
            }
            setup["baseUrl"] = .string(endpoint)
            setup["customEndpoint"] = .object(["api": .string("openai-completions")])
        } else if secret.isEmpty {
            errorMessage = "Enter the provider API key."
            return false
        }

        do {
            let result: CraftOperationResult = try await client.request(
                "settings:setupLlmConnection",
                args: [.object(setup)]
            )
            guard result.success else {
                errorMessage = result.error ?? "Craft could not save this connection."
                return false
            }
            let defaultResult: CraftOperationResult = try await client.request(
                "LLM_Connection:setDefault",
                args: [.string(provider.slug)]
            )
            guard defaultResult.success else {
                errorMessage = defaultResult.error ?? "Craft could not select this connection."
                return false
            }
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func makeDefault(_ connection: CraftLLMConnection) async {
        do {
            let result: CraftOperationResult = try await client.request(
                "LLM_Connection:setDefault",
                args: [.string(connection.slug)]
            )
            if result.success {
                await load()
            } else {
                errorMessage = result.error ?? "Craft could not select this connection."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func test(_ connection: CraftLLMConnection) async {
        do {
            let result: CraftOperationResult = try await client.request(
                "LLM_Connection:test",
                args: [.string(connection.slug)]
            )
            errorMessage = result.success ? nil : (result.error ?? "Connection test failed.")
            if result.success { await load() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

enum CraftConnectionProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAI
    case localOpenAI

    var id: String { rawValue }
    var title: String {
        switch self {
        case .anthropic: "Anthropic API"
        case .openAI: "OpenAI API"
        case .localOpenAI: "OpenAI-compatible endpoint"
        }
    }
    var slug: String { self == .anthropic ? "anthropic-api" : "pi-api-key" }
    var piProvider: String? { self == .openAI || self == .localOpenAI ? "openai" : nil }
}

struct CraftConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CraftConnectionSettingsViewModel
    @State private var isAdding = false

    init(client: CraftRPCClient) {
        _model = State(initialValue: CraftConnectionSettingsViewModel(client: client))
    }

    var body: some View {
        NavigationStack {
            List {
                if model.connections.isEmpty, !model.isLoading {
                    ContentUnavailableView(
                        "No model connection",
                        systemImage: "cpu",
                        description: Text("Add a provider before asking Craft to run an agent.")
                    )
                }
                ForEach(model.connections) { connection in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(connection.name).font(.headline)
                            if connection.isDefault == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                        Text(verbatim: connection.defaultModel ?? connection.providerType)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Label(
                            connection.isAuthenticated ? "Ready" : "Needs authentication",
                            systemImage: connection.isAuthenticated ? "checkmark.shield" : "key.slash"
                        )
                        .font(.caption)
                        .foregroundStyle(connection.isAuthenticated ? .green : .orange)
                    }
                    .contextMenu {
                        Button("Use as default") { Task { await model.makeDefault(connection) } }
                        Button("Test connection") { Task { await model.test(connection) } }
                    }
                }
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .overlay { if model.isLoading { ProgressView() } }
            .navigationTitle("Model connections")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add", systemImage: "plus") { isAdding = true }
                        .disabled(!model.canConfigure)
                }
            }
            .task { await model.load() }
            .sheet(isPresented: $isAdding) {
                CraftAddConnectionView(model: model)
            }
        }
    }
}

private struct CraftAddConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    let model: CraftConnectionSettingsViewModel
    @State private var provider = CraftConnectionProvider.anthropic
    @State private var credential = ""
    @State private var baseURL = "http://127.0.0.1:11434/v1"
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $provider) {
                    ForEach(CraftConnectionProvider.allCases) { Text($0.title).tag($0) }
                }
                if provider == .localOpenAI {
                    TextField("Endpoint URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    SecureField("API key (optional for local server)", text: $credential)
                } else {
                    SecureField("API key", text: $credential)
                        .textInputAutocapitalization(.never)
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Add model connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            if await model.configure(provider: provider, credential: credential, baseURL: baseURL) {
                                dismiss()
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }
}
