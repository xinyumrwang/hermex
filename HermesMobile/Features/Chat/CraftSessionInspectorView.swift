import Observation
import SwiftUI

@MainActor
@Observable
final class CraftSessionInspectorViewModel {
    let client: CraftRPCClient
    let sessionID: String
    private(set) var files: [CraftSessionFile] = []
    private(set) var connections: [CraftLLMConnection] = []
    var notes = ""
    var permissionMode: String
    var thinkingLevel: String
    var selectedConnection: String
    var selectedFileName = ""
    var selectedFileContent: String?
    var errorMessage: String?
    private(set) var isLoading = false

    init(client: CraftRPCClient, session: CraftSession) {
        self.client = client
        self.sessionID = session.id
        self.permissionMode = session.permissionMode ?? "ask"
        self.thinkingLevel = session.thinkingLevel ?? "medium"
        self.selectedConnection = session.llmConnection ?? ""
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            if await client.supports("sessions:getFiles") {
                files = try await client.request("sessions:getFiles", args: [.string(sessionID)])
            }
            if await client.supports("sessions:getNotes") {
                notes = try await client.request("sessions:getNotes", args: [.string(sessionID)])
            }
            if await client.supports("LLM_Connection:listWithStatus") {
                connections = try await client.request("LLM_Connection:listWithStatus")
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveNotes() async {
        do {
            let _: JSONValue = try await client.request(
                "sessions:setNotes",
                args: [.string(sessionID), .string(notes)]
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updatePermissionMode() async {
        await command(["type": .string("setPermissionMode"), "mode": .string(permissionMode)])
    }

    func updateThinkingLevel() async {
        await command(["type": .string("setThinkingLevel"), "level": .string(thinkingLevel)])
    }

    func updateConnection() async {
        guard !selectedConnection.isEmpty else { return }
        await command(["type": .string("setConnection"), "connectionSlug": .string(selectedConnection)])
    }

    func read(_ file: CraftSessionFile) async {
        guard file.type == "file" else { return }
        do {
            let content: String = try await client.request("file:read", args: [.string(file.path)])
            selectedFileName = file.name
            selectedFileContent = content
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func command(_ payload: [String: JSONValue]) async {
        do {
            let _: JSONValue = try await client.request(
                "sessions:command",
                args: [.string(sessionID), .object(payload)]
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CraftSessionInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CraftSessionInspectorViewModel

    init(client: CraftRPCClient, session: CraftSession) {
        _model = State(initialValue: CraftSessionInspectorViewModel(client: client, session: session))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Agent") {
                    Picker("Permission", selection: $model.permissionMode) {
                        Text("Safe").tag("safe")
                        Text("Ask").tag("ask")
                        Text("Allow all").tag("allow-all")
                    }
                    .onChange(of: model.permissionMode) { Task { await model.updatePermissionMode() } }

                    Picker("Thinking", selection: $model.thinkingLevel) {
                        ForEach(["off", "minimal", "low", "medium", "high", "max"], id: \.self) {
                            Text($0.capitalized).tag($0)
                        }
                    }
                    .onChange(of: model.thinkingLevel) { Task { await model.updateThinkingLevel() } }

                    if !model.connections.isEmpty {
                        Picker("Model connection", selection: $model.selectedConnection) {
                            Text("Workspace default").tag("")
                            ForEach(model.connections.filter(\.isAuthenticated)) {
                                Text($0.name).tag($0.slug)
                            }
                        }
                        .onChange(of: model.selectedConnection) { Task { await model.updateConnection() } }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $model.notes).frame(minHeight: 120)
                    Button("Save notes") { Task { await model.saveNotes() } }
                }

                Section("Session files") {
                    if model.files.isEmpty {
                        Text("No files").foregroundStyle(.secondary)
                    } else {
                        ForEach(flattenedFiles) { item in
                            Button {
                                Task { await model.read(item.file) }
                            } label: {
                                HStack {
                                    Image(systemName: item.file.type == "directory" ? "folder" : "doc.text")
                                    Text(item.file.name)
                                    Spacer()
                                }
                                .padding(.leading, CGFloat(item.depth * 14))
                            }
                            .disabled(item.file.type == "directory")
                        }
                    }
                }

                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .overlay { if model.isLoading { ProgressView() } }
            .navigationTitle("Conversation settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.load() }
            .sheet(isPresented: Binding(
                get: { model.selectedFileContent != nil },
                set: { if !$0 { model.selectedFileContent = nil } }
            )) {
                NavigationStack {
                    ScrollView {
                        Text(model.selectedFileContent ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle(model.selectedFileName)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.selectedFileContent = nil }
                        }
                    }
                }
            }
        }
    }

    private var flattenedFiles: [CraftFileRow] {
        func flatten(_ files: [CraftSessionFile], depth: Int) -> [CraftFileRow] {
            files.flatMap { file in
                [CraftFileRow(file: file, depth: depth)] + flatten(file.children ?? [], depth: depth + 1)
            }
        }
        return flatten(model.files, depth: 0)
    }
}

private struct CraftFileRow: Identifiable {
    let file: CraftSessionFile
    let depth: Int
    var id: String { file.path }
}
