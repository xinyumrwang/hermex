import Observation
import SwiftUI

@MainActor
@Observable
final class CraftHomeViewModel {
    let client: CraftRPCClient

    private(set) var workspaces: [CraftWorkspace] = []
    private(set) var sessions: [CraftSession] = []
    private(set) var selectedWorkspaceID: String?
    private(set) var isLoading = false
    private(set) var isConnected = false
    private(set) var canCreateWorkspace = false
    private(set) var canCreateSession = false
    private(set) var canArchiveSession = false
    var errorMessage: String?

    init(client: CraftRPCClient) {
        self.client = client
    }

    var selectedWorkspace: CraftWorkspace? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    func start() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await client.connect(workspaceID: selectedWorkspaceID)
            isConnected = true
            await refreshCapabilities()
            try await reloadWorkspaces()
        } catch {
            isConnected = false
            errorMessage = error.localizedDescription
        }
    }

    func recoverAfterForeground() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            try await client.reconnect(workspaceID: selectedWorkspaceID)
            isConnected = true
            errorMessage = nil
            await refreshCapabilities()
            try await reloadWorkspaces()
        } catch {
            isConnected = false
            errorMessage = error.localizedDescription
        }
    }

    func reloadWorkspaces() async throws {
        let loaded: [CraftWorkspace] = try await client.request("server:getWorkspaces")
        workspaces = loaded

        guard !loaded.isEmpty else {
            selectedWorkspaceID = nil
            sessions = []
            return
        }

        let workspace = loaded.first(where: { $0.id == selectedWorkspaceID }) ?? loaded[0]
        try await selectWorkspace(workspace)
    }

    func selectWorkspace(_ workspace: CraftWorkspace) async throws {
        let _: JSONValue = try await client.request(
            "window:switchWorkspace",
            args: [.string(workspace.id)]
        )
        selectedWorkspaceID = workspace.id
        let loaded: [CraftSession] = try await client.request("sessions:get")
        sessions = loaded
            .filter { $0.workspaceId == nil || $0.workspaceId == workspace.id }
            .filter { $0.isArchived != true }
            .sorted { ($0.lastMessageAt ?? 0) > ($1.lastMessageAt ?? 0) }
    }

    func chooseWorkspace(_ workspace: CraftWorkspace) async {
        do {
            try await selectWorkspace(workspace)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createWorkspace(named name: String) async {
        guard canCreateWorkspace else {
            errorMessage = CraftRPCError.channelUnavailable("server:createWorkspace").localizedDescription
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let workspace: CraftWorkspace = try await client.request(
                "server:createWorkspace",
                args: [.string(trimmed)]
            )
            workspaces.append(workspace)
            try await selectWorkspace(workspace)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createSession() async {
        guard canCreateSession else {
            errorMessage = CraftRPCError.channelUnavailable("sessions:create").localizedDescription
            return
        }
        guard let workspace = selectedWorkspace else {
            errorMessage = "Create or select a workspace first."
            return
        }
        do {
            let session: CraftSession = try await client.request(
                "sessions:create",
                args: [.string(workspace.id), .object([:])]
            )
            sessions.insert(session, at: 0)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archive(_ session: CraftSession) async {
        guard canArchiveSession else {
            errorMessage = CraftRPCError.channelUnavailable("sessions:command").localizedDescription
            return
        }
        do {
            let _: Bool = try await client.request(
                "sessions:command",
                args: [.string(session.id), .object(["type": .string("archive")])]
            )
            sessions.removeAll { $0.id == session.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshCapabilities() async {
        canCreateWorkspace = await client.supports("server:createWorkspace")
        canCreateSession = await client.supports("sessions:create")
        canArchiveSession = await client.supports("sessions:command")
    }
}

@MainActor
@Observable
final class CraftChatViewModel {
    let client: CraftRPCClient
    let sessionID: String
    private(set) var session: CraftSession
    private(set) var messages: [CraftMessage] = []
    private(set) var streamingText = ""
    private(set) var statusMessage: String?
    private(set) var isSending = false
    private(set) var canSend = false
    private(set) var canCancel = false
    private(set) var pendingPermission: CraftPermissionRequest?
    var draft = ""
    var errorMessage: String?

    private var eventTask: Task<Void, Never>?

    init(client: CraftRPCClient, session: CraftSession) {
        self.client = client
        self.sessionID = session.id
        self.session = session
        self.messages = session.messages?.filter { $0.hidden != true } ?? []
    }

    func start() async {
        canSend = await client.supports("sessions:sendMessage")
        canCancel = await client.supports("sessions:cancel")
        if eventTask == nil {
            let events = client.events
            eventTask = Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event)
                }
            }
        }
        await reload()
    }

    func stopObserving() {
        eventTask?.cancel()
        eventTask = nil
    }

    func reload() async {
        do {
            let loaded: CraftSession? = try await client.request(
                "sessions:getMessages",
                args: [.string(sessionID)]
            )
            guard let loaded else {
                errorMessage = "This Craft conversation no longer exists."
                return
            }
            session = loaded
            messages = loaded.messages?.filter { $0.hidden != true } ?? []
            isSending = loaded.isProcessing == true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send() async {
        guard canSend else {
            errorMessage = CraftRPCError.channelUnavailable("sessions:sendMessage").localizedDescription
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        draft = ""
        errorMessage = nil
        isSending = true
        streamingText = ""
        messages.append(
            CraftMessage(
                id: "local-\(UUID().uuidString)",
                role: "user",
                content: text,
                timestamp: Date().timeIntervalSince1970 * 1_000
            )
        )

        do {
            let _: CraftSendAcknowledgement = try await client.request(
                "sessions:sendMessage",
                args: [.string(sessionID), .string(text)]
            )
            await reloadPersistedMessagesWithoutChangingProcessing()
        } catch {
            isSending = false
            errorMessage = error.localizedDescription
        }
    }

    func cancel() async {
        guard canCancel else {
            errorMessage = CraftRPCError.channelUnavailable("sessions:cancel").localizedDescription
            return
        }
        do {
            let _: JSONValue = try await client.request(
                "sessions:cancel",
                args: [.string(sessionID), .bool(false)]
            )
            isSending = false
            statusMessage = "Stopped"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respondToPermission(allowed: Bool, alwaysAllow: Bool = false) async {
        guard let request = pendingPermission else { return }
        pendingPermission = nil
        do {
            let delivered: Bool = try await client.request(
                "sessions:respondToPermission",
                args: [
                    .string(sessionID),
                    .string(request.requestId),
                    .bool(allowed),
                    .bool(alwaysAllow),
                ]
            )
            if !delivered { errorMessage = "The permission request is no longer active." }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissPermission() {
        pendingPermission = nil
    }

    private func handle(_ event: CraftSessionEvent) async {
        if event.type == "connection_lost" {
            isSending = false
            errorMessage = CraftRPCError.disconnected.localizedDescription
            return
        }
        guard event.sessionId == sessionID else { return }

        switch event.type {
        case "text_delta":
            streamingText += event.delta ?? ""
            statusMessage = nil
            isSending = true
        case "text_complete":
            let text = event.text ?? streamingText
            if !text.isEmpty {
                messages.append(
                    CraftMessage(
                        id: event.messageId ?? "stream-\(UUID().uuidString)",
                        role: "assistant",
                        content: text,
                        timestamp: Date().timeIntervalSince1970 * 1_000,
                        isIntermediate: event.isIntermediate
                    )
                )
            }
            streamingText = ""
        case "tool_start":
            statusMessage = event.toolName.map { "Running \($0)…" }
            isSending = true
        case "tool_result":
            statusMessage = event.isError == true ? "Tool failed" : nil
        case "status", "info":
            statusMessage = event.statusText ?? event.text
        case "permission_request":
            pendingPermission = event.request
        case "error", "typed_error":
            errorMessage = event.error ?? "Craft stopped with an error."
            isSending = false
        case "interrupted":
            isSending = false
            streamingText = ""
            statusMessage = "Stopped"
            await reload()
        case "complete":
            isSending = false
            streamingText = ""
            statusMessage = nil
            await reload()
        case "user_message":
            await reloadPersistedMessagesWithoutChangingProcessing()
        case "name_changed", "title_generated":
            if let name = event.name ?? event.title { session.name = name }
        default:
            break
        }
    }

    private func reloadPersistedMessagesWithoutChangingProcessing() async {
        let wasSending = isSending
        do {
            let loaded: CraftSession? = try await client.request(
                "sessions:getMessages",
                args: [.string(sessionID)]
            )
            if let loaded {
                session = loaded
                messages = loaded.messages?.filter { $0.hidden != true } ?? messages
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = wasSending
    }
}

struct CraftHomeView: View {
    @Bindable var authManager: AuthManager
    let server: URL
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: CraftHomeViewModel?
    @State private var isShowingAddServer = false
    @State private var isShowingConnections = false
    @State private var isShowingTasks = false
    @State private var isCreatingWorkspace = false
    @State private var workspaceName = ""

    var body: some View {
        NavigationStack {
            Group {
                if let viewModel {
                    sessionContent(viewModel)
                } else {
                    ContentUnavailableView(
                        "Craft credential unavailable",
                        systemImage: "key.slash",
                        description: Text("Remove this server and connect again.")
                    )
                }
            }
            .navigationTitle("Craft")
            .toolbar { toolbar }
            .sheet(isPresented: $isShowingAddServer) {
                AddServerView(authManager: authManager)
            }
            .sheet(isPresented: $isShowingConnections) {
                if let viewModel {
                    CraftConnectionSettingsView(client: viewModel.client)
                }
            }
            .sheet(isPresented: $isShowingTasks) {
                if let viewModel, let workspaceID = viewModel.selectedWorkspaceID {
                    CraftTasksView(client: viewModel.client, workspaceID: workspaceID)
                }
            }
            .alert("New workspace", isPresented: $isCreatingWorkspace) {
                TextField("Workspace name", text: $workspaceName)
                Button("Cancel", role: .cancel) { workspaceName = "" }
                Button("Create") {
                    let name = workspaceName
                    workspaceName = ""
                    Task { await viewModel?.createWorkspace(named: name) }
                }
            } message: {
                Text("Craft stores conversations and agent configuration inside a workspace.")
            }
            .task {
                guard viewModel == nil,
                      let token = authManager.craftToken(for: server) else { return }
                let model = CraftHomeViewModel(client: CraftRPCClient(serverURL: server, token: token))
                viewModel = model
                await model.start()
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                guard oldPhase != .active, newPhase == .active else { return }
                Task { await viewModel?.recoverAfterForeground() }
            }
        }
    }

    @ViewBuilder
    private func sessionContent(_ model: CraftHomeViewModel) -> some View {
        if model.isLoading, model.workspaces.isEmpty {
            ProgressView("Connecting to Craft…")
        } else if model.workspaces.isEmpty {
            ContentUnavailableView {
                Label("No Craft workspace", systemImage: "square.grid.2x2")
            } description: {
                Text(model.errorMessage ?? "Create a workspace before starting your first conversation.")
            } actions: {
                Button("Create workspace") { isCreatingWorkspace = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canCreateWorkspace)
            }
        } else {
            List {
                connectionSection(model)

                if model.sessions.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No conversations",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Start a conversation in this Craft workspace.")
                        )
                        Button("New conversation", systemImage: "square.and.pencil") {
                            Task { await model.createSession() }
                        }
                        .disabled(!model.canCreateSession)
                    }
                } else {
                    Section("Conversations") {
                        ForEach(model.sessions) { session in
                            NavigationLink {
                                CraftChatView(client: model.client, session: session)
                            } label: {
                                CraftSessionRow(session: session)
                            }
                            .swipeActions(edge: .trailing) {
                                Button("Archive", systemImage: "archivebox") {
                                    Task { await model.archive(session) }
                                }
                                .tint(.orange)
                                .disabled(!model.canArchiveSession)
                            }
                        }
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .refreshable { await model.start() }
        }
    }

    private func connectionSection(_ model: CraftHomeViewModel) -> some View {
        Section {
            Label(
                model.isConnected ? "Connected" : "Disconnected",
                systemImage: model.isConnected ? "checkmark.shield.fill" : "wifi.exclamationmark"
            )
            .foregroundStyle(model.isConnected ? .green : .orange)

            Menu {
                ForEach(model.workspaces) { workspace in
                    Button {
                        Task { await model.chooseWorkspace(workspace) }
                    } label: {
                        if workspace.id == model.selectedWorkspaceID {
                            Label(workspace.name, systemImage: "checkmark")
                        } else {
                            Text(workspace.name)
                        }
                    }
                }
                Divider()
                Button("New workspace", systemImage: "plus") { isCreatingWorkspace = true }
                    .disabled(!model.canCreateWorkspace)
            } label: {
                LabeledContent("Workspace", value: model.selectedWorkspace?.name ?? "Select")
            }
        } header: {
            Text(verbatim: server.absoluteString)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("New conversation", systemImage: "square.and.pencil") {
                Task { await viewModel?.createSession() }
            }
            .disabled(viewModel?.selectedWorkspace == nil || viewModel?.canCreateSession != true)
        }
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button("Add server", systemImage: "plus") { isShowingAddServer = true }
                Button("Model connections", systemImage: "cpu") { isShowingConnections = true }
                    .disabled(viewModel == nil)
                Button("Tasks", systemImage: "point.3.connected.trianglepath.dotted") { isShowingTasks = true }
                    .disabled(viewModel?.selectedWorkspaceID == nil)
                Button("Create workspace", systemImage: "square.grid.2x2") { isCreatingWorkspace = true }
                    .disabled(viewModel?.canCreateWorkspace != true)
                Divider()
                Button("Remove server", systemImage: "trash", role: .destructive) {
                    Task { await authManager.signOut() }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct CraftSessionRow: View {
    let session: CraftSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.isProcessing == true ? "bolt.fill" : "bubble.left")
                .foregroundStyle(session.isProcessing == true ? .yellow : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.headline).lineLimit(1)
                if let preview = session.preview, !preview.isEmpty {
                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if session.hasUnread == true {
                Circle().fill(.yellow).frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }
}

struct CraftChatView: View {
    @State private var viewModel: CraftChatViewModel
    @FocusState private var composerFocused: Bool
    @State private var isShowingInspector = false

    init(client: CraftRPCClient, session: CraftSession) {
        _viewModel = State(initialValue: CraftChatViewModel(client: client, session: session))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        CraftMessageRow(message: message)
                            .id(message.id)
                    }
                    if !viewModel.streamingText.isEmpty {
                        CraftStreamingMessage(text: viewModel.streamingText)
                            .id("craft-stream")
                    }
                    if let status = viewModel.statusMessage {
                        Label(status, systemImage: "gearshape.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .id("craft-status")
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.messages.count) {
                if let last = viewModel.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: viewModel.streamingText) { proxy.scrollTo("craft-stream", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle(viewModel.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Conversation settings", systemImage: "slider.horizontal.3") {
                    isShowingInspector = true
                }
            }
        }
        .task { await viewModel.start() }
        .onDisappear { viewModel.stopObserving() }
        .sheet(isPresented: $isShowingInspector) {
            CraftSessionInspectorView(client: viewModel.client, session: viewModel.session)
        }
        .alert(
            "Permission requested",
            isPresented: Binding(
                get: { viewModel.pendingPermission != nil },
                set: { if !$0 { viewModel.dismissPermission() } }
            ),
            presenting: viewModel.pendingPermission
        ) { _ in
            Button("Deny", role: .destructive) {
                Task { await viewModel.respondToPermission(allowed: false) }
            }
            Button("Always allow") {
                Task { await viewModel.respondToPermission(allowed: true, alwaysAllow: true) }
            }
            Button("Allow") {
                Task { await viewModel.respondToPermission(allowed: true) }
            }
        } message: { request in
            Text(request.command ?? request.description)
        }
        .alert("Craft", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message Craft", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .onSubmit { Task { await viewModel.send() } }

            if viewModel.isSending {
                Button {
                    Task { await viewModel.cancel() }
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!viewModel.canCancel)
                .accessibilityLabel("Stop Craft response")
            } else {
                Button {
                    Task { await viewModel.send() }
                } label: {
                    Image(systemName: "arrow.up")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !viewModel.canSend
                        || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel("Send message to Craft")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private struct CraftMessageRow: View {
    let message: CraftMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 48) }
            VStack(alignment: .leading, spacing: 5) {
                if message.role == "assistant" {
                    MarkdownRenderer(content: message.content)
                } else if message.role == "tool" {
                    Label(message.toolName ?? "Tool", systemImage: "wrench.and.screwdriver")
                        .font(.caption.bold())
                    Text(message.toolResult ?? message.content)
                        .font(.caption.monospaced())
                        .lineLimit(8)
                } else {
                    Text(message.content).textSelection(.enabled)
                }
            }
            .padding(12)
            .background(message.role == "user" ? Color.accentColor : Color.secondary.opacity(0.14))
            .foregroundStyle(message.role == "user" ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if message.role != "user" { Spacer(minLength: 28) }
        }
    }
}

private struct CraftStreamingMessage: View {
    let text: String

    var body: some View {
        HStack {
            MarkdownRenderer(content: text, isStreaming: true)
                .padding(12)
                .background(Color.secondary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 28)
        }
    }
}
