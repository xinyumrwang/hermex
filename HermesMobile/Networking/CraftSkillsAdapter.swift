import Foundation

struct CraftSkillMetadata: Decodable, Equatable, Sendable {
    var name: String?
    var description: String?
    var globs: [String]?
    var requiredSources: [String]?
}

struct CraftLoadedSkill: Decodable, Equatable, Identifiable, Sendable {
    var id: String { slug }
    let slug: String
    var metadata: CraftSkillMetadata
    var content: String
    var path: String
    var source: String

    var summary: SkillSummary {
        SkillSummary(
            name: metadata.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? slug,
            category: source.capitalized,
            description: metadata.description,
            path: path,
            disabled: nil,
            tags: metadata.requiredSources,
            relatedSkills: nil
        )
    }
}

struct CraftSkillFile: Decodable, Equatable, Sendable {
    var name: String
    var type: String
    var size: Int?
    var children: [CraftSkillFile]?

    func flattenedFiles(prefix: String = "") -> [String] {
        let relativePath = prefix.isEmpty ? name : "\(prefix)/\(name)"
        if type == "directory" {
            return (children ?? []).flatMap { $0.flattenedFiles(prefix: relativePath) }
        }
        return [relativePath]
    }
}

struct CraftSkillsProvider: SkillsProviding {
    let client: CraftRPCClient
    let workspaceID: String

    func loadSkills() async throws -> [SkillSummary] {
        try await loadedSkills().map(\.summary)
    }

    func loadSkillContent(name: String, file: String?) async throws -> SkillDetailResponse {
        let skills = try await loadedSkills()
        guard let skill = skills.first(where: {
            $0.slug == name || $0.metadata.name?.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw CraftRPCError.server(code: "SKILL_NOT_FOUND", message: "Craft could not find this skill.")
        }

        let files: [CraftSkillFile] = try await client.request(
            "skills:getFiles",
            args: [.string(workspaceID), .string(skill.slug)]
        )
        let linkedFiles = files
            .flatMap { $0.flattenedFiles() }
            .filter { $0.caseInsensitiveCompare("SKILL.md") != .orderedSame }
            .sorted()

        guard let file else {
            return SkillDetailResponse(
                name: skill.metadata.name ?? skill.slug,
                content: skill.content,
                linkedFiles: linkedFiles.isEmpty ? nil : linkedFiles
            )
        }

        guard linkedFiles.contains(file), !file.split(separator: "/").contains("..") else {
            throw CraftRPCError.server(code: "INVALID_SKILL_FILE", message: "Craft rejected this skill file path.")
        }
        let filePath = URL(fileURLWithPath: skill.path).appending(path: file).path
        let content: String = try await client.request("file:read", args: [.string(filePath)])
        return SkillDetailResponse(name: file, content: content, linkedFiles: nil)
    }

    func setSkill(name: String, enabled: Bool) async throws {
        throw CraftRPCError.channelUnavailable("skills:toggle")
    }

    private func loadedSkills() async throws -> [CraftLoadedSkill] {
        try await client.request("skills:get", args: [.string(workspaceID)])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
