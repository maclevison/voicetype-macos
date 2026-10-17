import Foundation

/// An OpenKnowledge project: a root folder whose `index.md` says `type: indice`.
public struct OKProject: Codable, Equatable, Sendable, Identifiable {
    public var slug: String
    public var title: String
    public var description: String
    public var id: String { slug }

    public init(slug: String, title: String, description: String) {
        self.slug = slug
        self.title = title
        self.description = description
    }
}

/// A knowledge doc already in the vault, as the model and the conflict
/// checks see it.
public struct OKDocEntry: Codable, Equatable, Sendable {
    /// Vault-relative, `/`-separated (`p5/decisoes/x.md`).
    public var path: String
    public var type: OKKnowledgeType
    public var title: String
    public var description: String
    /// `OKPath.contentHash` of the file's bytes.
    public var hash: String

    public init(path: String, type: OKKnowledgeType, title: String, description: String, hash: String) {
        self.path = path
        self.type = type
        self.title = title
        self.description = description
        self.hash = hash
    }
}

/// Reads what the vault already holds: its projects and each project's docs.
public enum OKVaultCatalog {
    /// Root folders with an `index.md` of `type: indice` and a valid slug,
    /// sorted by slug. Hidden (`.ok/`) and `_`-prefixed (`_inbox/`) folders
    /// are never projects. A missing `title` falls back to the slug. A
    /// repeated key is ambiguous and reads as missing (`OKFrontmatter.scalar`),
    /// so an index with `type` twice is not a project.
    public static func projects(in vault: URL, fileManager: FileManager = .default) throws -> [OKProject] {
        try children(of: vault, fileManager: fileManager)
            .filter { !$0.lastPathComponent.hasPrefix("_") && isDirectory($0) && OKSlug.isValid($0.lastPathComponent) }
            .compactMap { folder -> OKProject? in
                let index = folder.appendingPathComponent("index.md")
                guard isRegularFile(index), let md = try? String(contentsOf: index, encoding: .utf8),
                      OKFrontmatter.scalar("type", in: md) == "indice" else { return nil }
                let slug = folder.lastPathComponent
                return OKProject(slug: slug,
                                 title: nonEmpty(OKFrontmatter.scalar("title", in: md)) ?? slug,
                                 description: OKFrontmatter.scalar("description", in: md) ?? "")
            }
            .sorted { $0.slug < $1.slug }
    }

    /// The `.md` files directly inside the project's seven type folders
    /// (no subfolders, no hidden files), sorted by path. A missing or
    /// repeated `title` falls back to the file name without extension.
    public static func docs(project: String, in vault: URL, fileManager: FileManager = .default) throws -> [OKDocEntry] {
        var docs: [OKDocEntry] = []
        for type in OKKnowledgeType.allCases {
            let folder = vault.appendingPathComponent(project).appendingPathComponent(type.folder)
            guard isDirectory(folder) else { continue }
            for file in try children(of: folder, fileManager: fileManager)
            where file.pathExtension == "md" && isRegularFile(file) {
                let data = try Data(contentsOf: file)
                let md = String(decoding: data, as: UTF8.self)
                let name = file.lastPathComponent
                docs.append(OKDocEntry(path: "\(project)/\(type.folder)/\(name)",
                                       type: type,
                                       title: nonEmpty(OKFrontmatter.scalar("title", in: md)) ?? file.deletingPathExtension().lastPathComponent,
                                       description: OKFrontmatter.scalar("description", in: md) ?? "",
                                       hash: OKPath.contentHash(data)))
            }
        }
        return docs.sorted { $0.path < $1.path }
    }

    /// SHA-256 over the sorted `path\thash` lines: changes whenever a doc is
    /// added, removed or edited, and ignores input order and titles.
    public static func fingerprint(_ docs: [OKDocEntry]) -> String {
        let lines = docs.map { "\($0.path)\t\($0.hash)\n" }.sorted().joined()
        return OKPath.contentHash(Data(lines.utf8))
    }

    // MARK: - Helpers

    /// Non-hidden entries of `directory`.
    private static func children(of directory: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

/// The vault's own templates (`.ok/templates/<type>.md`), read at run time.
public enum OKTemplate {
    /// The template with every `template:` block dropped, `{{date}}` as
    /// `yyyy-MM-dd` in `timeZone` and `{{user}}` as `user`. The other
    /// `TODO`s stay for the model to fill. Missing template →
    /// `CocoaError(.fileReadNoSuchFile)`.
    public static func load(_ type: OKKnowledgeType, vault: URL, date: Date, user: String, timeZone: TimeZone = .current) throws -> String {
        let url = vault.appendingPathComponent(".ok/templates/\(type.templateName).md")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        let day = MeetingNoteRenderer.formatter("yyyy-MM-dd", timeZone).string(from: date)
        return OKFrontmatter.removing("template", in: try String(contentsOf: url, encoding: .utf8))
            .replacingOccurrences(of: "{{date}}", with: day)
            .replacingOccurrences(of: "{{user}}", with: user)
    }
}
