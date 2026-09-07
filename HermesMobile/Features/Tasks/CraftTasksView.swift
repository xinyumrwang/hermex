import Observation
import SwiftUI

@MainActor
@Observable
final class CraftTasksViewModel {
    let client: CraftRPCClient
    let workspaceID: String
    private(set) var slugs: [String] = []
    private(set) var details: [String: CraftTaskDetail] = [:]
    private(set) var runs: [String: CraftTaskRun] = [:]
    private(set) var isLoading = false
    var errorMessage: String?

    init(client: CraftRPCClient, workspaceID: String) {
        self.client = client
        self.workspaceID = workspaceID
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            slugs = try await client.request("tasks:list", args: [.string(workspaceID)])
            for slug in slugs {
                let detail: CraftTaskDetail = try await client.request(
                    "tasks:get",
                    args: [.string(workspaceID), .string(slug)]
                )
                details[slug] = detail
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func run(_ slug: String) async {
        do {
            let run: CraftTaskRun = try await client.request(
                "tasks:run",
                args: [.string(workspaceID), .object(["slug": .string(slug)])]
            )
            runs[slug] = run
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func changeRun(_ slug: String, action: String) async {
        guard let run = runs[slug] else { return }
        do {
            let _: JSONValue = try await client.request(
                "tasks:\(action)",
                args: [.string(workspaceID), .string(slug), .string(run.runId)]
            )
            var updated = run
            updated.status = action == "pause" ? "paused" : action == "resume" ? "running" : "stopped"
            runs[slug] = updated
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CraftTasksView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: CraftTasksViewModel

    init(client: CraftRPCClient, workspaceID: String) {
        _model = State(initialValue: CraftTasksViewModel(client: client, workspaceID: workspaceID))
    }

    var body: some View {
        NavigationStack {
            List {
                if model.slugs.isEmpty, !model.isLoading {
                    ContentUnavailableView(
                        "No Craft tasks",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text("Tasks created in this workspace will appear here.")
                    )
                }
                ForEach(model.slugs, id: \.self) { slug in
                    Section {
                        if let detail = model.details[slug] {
                            Label(
                                detail.validation.valid ? "Valid task" : "Needs attention",
                                systemImage: detail.validation.valid ? "checkmark.circle" : "exclamationmark.triangle"
                            )
                            .foregroundStyle(detail.validation.valid ? .green : .orange)
                            ForEach(detail.validation.errors, id: \.path) { issue in
                                Text(issue.message).font(.caption).foregroundStyle(.red)
                            }
                        }
                        if let run = model.runs[slug] {
                            LabeledContent("Status", value: run.status)
                            ProgressView(value: completedFraction(run))
                            HStack {
                                if run.status == "running" {
                                    Button("Pause") { Task { await model.changeRun(slug, action: "pause") } }
                                } else if run.status == "paused" {
                                    Button("Resume") { Task { await model.changeRun(slug, action: "resume") } }
                                }
                                Button("Stop", role: .destructive) {
                                    Task { await model.changeRun(slug, action: "stop") }
                                }
                            }
                        } else {
                            Button("Run task", systemImage: "play.fill") { Task { await model.run(slug) } }
                                .disabled(model.details[slug]?.validation.valid == false)
                        }
                    } header: {
                        Text(verbatim: slug)
                    }
                }
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .overlay { if model.isLoading { ProgressView() } }
            .refreshable { await model.load() }
            .navigationTitle("Craft tasks")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await model.load() }
        }
    }

    private func completedFraction(_ run: CraftTaskRun) -> Double {
        guard !run.nodes.isEmpty else { return 0 }
        let completed = run.nodes.filter { ["done", "failed", "cancelled", "skipped"].contains($0.state) }.count
        return Double(completed) / Double(run.nodes.count)
    }
}
