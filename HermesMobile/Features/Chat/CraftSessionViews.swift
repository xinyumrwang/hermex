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

    @discardableResult
    func createSession() async -> CraftSession? {
        guard canCreateSession else {
            errorMessage = CraftRPCError.channelUnavailable("sessions:create").localizedDescription
            return nil
        }
        guard let workspace = selectedWorkspace else {
            errorMessage = "Create or select a workspace first."
            return nil
        }
        do {
            let session: CraftSession = try await client.request(
                "sessions:create",
                args: [.string(workspace.id), .object([:])]
            )
            sessions.insert(session, at: 0)
            errorMessage = nil
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func archive(_ session: CraftSession) async {
        guard canArchiveSession else {
            errorMessage = CraftRPCError.channelUnavailable("sessions:command").localizedDescription
            return
        }
        do {
            let _: JSONValue = try await client.request(
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
    private(set) var isRespondingToPermission = false
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
            let _: CraftSendAcknowledgement = try await client.sendMessage(
                sessionID: sessionID,
                text: text
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
        isRespondingToPermission = true
        defer { isRespondingToPermission = false }
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
            if delivered {
                pendingPermission = nil
            } else {
                errorMessage = "The permission request is no longer active."
            }
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
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex
    @State private var viewModel: CraftHomeViewModel?
    @State private var isShowingAddServer = false
    @State private var isShowingConnections = false
    @State private var isShowingTasks = false
    @State private var isShowingSkills = false
    @State private var isCreatingWorkspace = false
    @State private var newlyCreatedSession: CraftSession?
    @State private var unavailableFeature: CraftUnavailableFeature?
    @State private var searchText = ""
    @State private var isSearching = false
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
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: Binding(
                get: { newlyCreatedSession != nil },
                set: { if !$0 { newlyCreatedSession = nil } }
            )) {
                if let session = newlyCreatedSession, let viewModel {
                    CraftChatView(client: viewModel.client, session: session)
                }
            }
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
            .sheet(isPresented: $isShowingSkills) {
                if let viewModel, let workspaceID = viewModel.selectedWorkspaceID {
                    NavigationStack {
                        SkillsView(
                            provider: CraftSkillsProvider(client: viewModel.client, workspaceID: workspaceID),
                            onAPIError: { viewModel.errorMessage = $0.localizedDescription }
                        )
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { isShowingSkills = false }
                            }
                        }
                    }
                }
            }
            .sheet(item: $unavailableFeature) { feature in
                NavigationStack {
                    ContentUnavailableView {
                        Label(feature.title, systemImage: feature.systemImage)
                    } description: {
                        Text("This Craft server does not provide the API required by this Hermex feature.")
                    }
                    .navigationTitle(feature.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { unavailableFeature = nil }
                        }
                    }
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
            ZStack(alignment: .bottomTrailing) {
                List {
                    hermexHeader(model)
                        .sessionsTopChromeListRow()

                    if !isSearching {
                        hermexUtilities(model)
                            .padding(.top, 10)
                            .sessionsScreenListRow()
                    }

                    Section("Sessions") {
                        if filteredSessions(model).isEmpty {
                            ContentUnavailableView(
                                searchText.isEmpty ? "No Sessions" : "No Results",
                                systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                                description: Text(searchText.isEmpty
                                    ? "Start a new chat in this workspace."
                                    : "No sessions match your search.")
                            )
                        } else {
                            ForEach(filteredSessions(model)) { session in
                                NavigationLink {
                                    CraftChatView(client: model.client, session: session)
                                } label: {
                                    SessionRowView(session: hermesSessionSummary(session))
                                }
                                .buttonStyle(.plain)
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
                    .sessionsScreenListRow()

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .sessionsScreenListRow()
                    }

                    Color.clear
                        .frame(height: 104)
                        .sessionsScreenListRow()
                        .accessibilityHidden(true)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                .background(Color(.systemBackground))
                .refreshable { await model.start() }

                if !isSearching {
                    newSessionButton(model)
                        .padding(.trailing, 24)
                        .padding(.bottom, 22)
                }
            }
        }
    }

    private func hermexHeader(_ model: CraftHomeViewModel) -> some View {
        HStack(spacing: 16) {
            HermesHeaderLogo(selectedColor: HeaderLogoColor.color(for: headerLogoColorHex))
                .frame(width: isSearching ? 0 : 160, alignment: .leading)
                .opacity(isSearching ? 0 : 1)
                .clipped()

            HStack(spacing: 4) {
                Button {
                    isSearching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search sessions")

                if isSearching {
                    TextField("Search sessions", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        searchText = ""
                        isSearching = false
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                } else {
                    Menu {
                        Button("Model connections", systemImage: "cpu") { isShowingConnections = true }
                        Button("Add Server…", systemImage: "plus") { isShowingAddServer = true }
                        Button("Create workspace", systemImage: "square.grid.2x2") { isCreatingWorkspace = true }
                            .disabled(!model.canCreateWorkspace)
                        Divider()
                        Button("Remove server", systemImage: "trash", role: .destructive) {
                            Task { await authManager.signOut() }
                        }
                    } label: {
                        Text("C")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.black)
                            .frame(width: 36, height: 36)
                            .background(HeaderLogoColor.color(for: headerLogoColorHex), in: Circle())
                    }
                    .frame(width: 44, height: 44)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .sessionsChromeGlass(isInteractive: true, in: Capsule())
            .clipShape(Capsule())
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
    }

    private func hermexUtilities(_ model: CraftHomeViewModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SidebarNavButton(title: "Tasks", assetImage: "LucideCalendarClock") {
                isShowingTasks = true
            }
            SidebarNavButton(title: "Kanban", assetImage: "LucideColumns3") {
                unavailableFeature = .kanban
            }
            SidebarNavButton(title: "Skills", assetImage: "LucideHammer") {
                isShowingSkills = true
            }
            SidebarNavButton(title: "Memory", assetImage: "LucideBrain") {
                unavailableFeature = .memory
            }
            SidebarNavButton(title: "Usage", assetImage: "LucideChartColumnIncreasing") {
                unavailableFeature = .usage
            }
            SidebarNavButton(title: "Active Profile", assetImage: "LucideUserRoundCog") {
                unavailableFeature = .profiles
            }
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
                HStack(spacing: 18) {
                    SidebarUtilityIcon(assetImage: "LucideFolder")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Projects").font(.body.weight(.semibold))
                        Text(model.selectedWorkspace?.name ?? "Select workspace")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }

    private func newSessionButton(_ model: CraftHomeViewModel) -> some View {
        Button {
            Task { newlyCreatedSession = await model.createSession() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil").font(.title3.weight(.semibold))
                Text("Chat").font(.headline.weight(.semibold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 22)
            .frame(height: 58)
            .background(HeaderLogoColor.color(for: headerLogoColorHex), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(SessionListFloatingChatButtonStyle())
        .disabled(model.selectedWorkspace == nil || !model.canCreateSession)
    }

    private func filteredSessions(_ model: CraftHomeViewModel) -> [CraftSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.sessions }
        return model.sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || ($0.preview?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func hermesSessionSummary(_ session: CraftSession) -> SessionSummary {
        SessionSummary(
            sessionId: session.id,
            title: session.title,
            workspace: session.workspaceName,
            model: session.model,
            messageCount: session.messages?.count,
            lastMessageAt: normalizedTimestamp(session.lastMessageAt),
            pinned: session.isFlagged,
            archived: session.isArchived,
            isStreaming: session.isProcessing,
            sourceLabel: "Craft"
        )
    }

    private func normalizedTimestamp(_ value: Double?) -> Double? {
        guard let value else { return nil }
        return value > 10_000_000_000 ? value / 1_000 : value
    }
}

private enum CraftUnavailableFeature: String, Identifiable {
    case kanban, memory, usage, profiles

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .kanban: "rectangle.3.group"
        case .memory: "brain"
        case .usage: "chart.bar"
        case .profiles: "person.crop.circle.badge.gearshape"
        }
    }
}

struct CraftChatView: View {
    @State private var viewModel: CraftChatViewModel
    @FocusState private var composerFocused: Bool
    @State private var isShowingInspector = false
    @AppStorage(HeaderLogoColor.storageKey) private var headerLogoColorHex = HeaderLogoColor.defaultHex

    init(client: CraftRPCClient, session: CraftSession) {
        _viewModel = State(initialValue: CraftChatViewModel(client: client, session: session))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.messages) { message in
                        CraftTranscriptRow(message: message)
                            .id(message.id)
                    }
                    if !viewModel.streamingText.isEmpty {
                        MessageBubbleView(
                            message: ChatMessage(
                                role: "assistant",
                                content: viewModel.streamingText,
                                timestamp: Date().timeIntervalSince1970,
                                messageId: "craft-stream"
                            ),
                            transcriptMediaCacheNamespace: "craft:\(viewModel.sessionID)",
                            isStreaming: true
                        )
                            .id("craft-stream")
                    }
                    if let status = viewModel.statusMessage {
                        Label(status, systemImage: "gearshape.2")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .chatTimelineAccessorySurface(fallbackMaterial: .thinMaterial, in: Capsule())
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
        .safeAreaInset(edge: .bottom) {
            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .navigationTitle(viewModel.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingInspector = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Conversation settings")
                .accessibilityIdentifier("craft-conversation-settings")
            }
        }
        .task { await viewModel.start() }
        .onDisappear { viewModel.stopObserving() }
        .sheet(isPresented: $isShowingInspector) {
            CraftSessionInspectorView(client: viewModel.client, session: viewModel.session)
        }
        .overlay {
            if let prompt = permissionPrompt {
                ApprovalRequestOverlay(
                    prompt: prompt,
                    isResponding: viewModel.isRespondingToPermission,
                    errorMessage: viewModel.errorMessage,
                    onChoice: respondToPermission,
                    onSkipAll: {},
                    showsSkipAll: false
                )
                .zIndex(10)
            }
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
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Craft", text: $viewModel.draft, axis: .vertical)
                .lineLimit(1...8)
                .padding(.leading, 16)
                .padding(.vertical, 12)
                .focused($composerFocused)
                .onSubmit { Task { await viewModel.send() } }

            Button {
                if viewModel.isSending, trimmedDraft.isEmpty {
                    Task { await viewModel.cancel() }
                } else {
                    Task { await viewModel.send() }
                }
            } label: {
                Image(systemName: viewModel.isSending && trimmedDraft.isEmpty ? "stop.fill" : "arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(actionButtonColor, in: Circle())
                    .foregroundStyle(actionButtonForeground)
            }
            .buttonStyle(.chatTactile(.icon))
            .padding(5)
            .disabled(actionButtonDisabled)
            .accessibilityLabel(viewModel.isSending && trimmedDraft.isEmpty ? "Stop response" : "Send")
        }
        .adaptiveGlass(
            .regular,
            isInteractive: true,
            fallbackMaterial: .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChatComposerMetrics.cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
    }

    private var trimmedDraft: String {
        viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var actionButtonDisabled: Bool {
        if viewModel.isSending, trimmedDraft.isEmpty { return !viewModel.canCancel }
        return !viewModel.canSend || trimmedDraft.isEmpty
    }

    private var actionButtonColor: Color {
        actionButtonDisabled ? Color.secondary.opacity(0.16) : HeaderLogoColor.color(for: headerLogoColorHex)
    }

    private var actionButtonForeground: Color {
        actionButtonDisabled ? .secondary : .black
    }

    private var permissionPrompt: ApprovalPromptState? {
        guard let request = viewModel.pendingPermission else { return nil }
        return ApprovalPromptState(
            sessionID: viewModel.sessionID,
            pending: PendingApproval(
                approvalId: request.requestId,
                command: request.command,
                description: request.description
            ),
            pendingCount: 1
        )
    }

    private func respondToPermission(_ choice: ApprovalChoice) {
        Task {
            switch choice {
            case .deny:
                await viewModel.respondToPermission(allowed: false)
            case .always:
                await viewModel.respondToPermission(allowed: true, alwaysAllow: true)
            case .once, .session:
                await viewModel.respondToPermission(allowed: true)
            }
        }
    }
}

private struct CraftTranscriptRow: View {
    let message: CraftMessage

    @ViewBuilder
    var body: some View {
        if message.role == "tool", let entry = toolEntry {
            ToolCallLogRowView(entry: entry)
        } else {
            MessageBubbleView(
                message: ChatMessage(
                    role: message.role,
                    content: message.content,
                    timestamp: normalizedTimestamp,
                    messageId: message.id,
                    name: message.toolDisplayName ?? message.toolName,
                    toolUseId: message.toolUseId,
                    attachments: message.attachments?.map(\.messageAttachment)
                ),
                transcriptMediaCacheNamespace: "craft"
            )
        }
    }

    private var normalizedTimestamp: Double? {
        guard let value = message.timestamp else { return nil }
        return value > 10_000_000_000 ? value / 1_000 : value
    }

    private var toolEntry: ToolCallLogEntry? {
        let result = message.toolResult ?? message.content
        let normalizedStatus = message.toolStatus?.lowercased()
        let completedStatuses = ["completed", "complete", "success", "error", "failed", "cancelled", "canceled", "interrupted"]
        let isError = message.isError == true || ["error", "failed"].contains(normalizedStatus)
        let call = ToolCall(
            id: message.toolUseId ?? message.id,
            name: message.toolDisplayName ?? message.toolName,
            preview: message.toolIntent ?? result,
            args: message.toolInput ?? (result.isEmpty ? nil : ["result": .string(result)]),
            duration: message.toolDuration.map { $0 / 1_000 },
            isError: isError,
            isCompleted: normalizedStatus.map { completedStatuses.contains($0) } ?? true,
            startedAt: normalizedTimestamp ?? Date().timeIntervalSince1970
        )
        return ToolCallSummaryFormatter.entries(for: [call], isLive: false).first
    }
}
