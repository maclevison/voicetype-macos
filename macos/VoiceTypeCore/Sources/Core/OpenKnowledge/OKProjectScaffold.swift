import Foundation

/// A file the app wants in the vault: `path` is vault-relative, `content` the
/// whole file. Written later by `OKVaultWriter.commit`, never here.
public struct OKFileWrite: Equatable, Sendable {
    public var path: String
    public var content: String

    public init(path: String, content: String) {
        self.path = path
        self.content = content
    }
}

/// A new OpenKnowledge project (same layout as the `novo-projeto` skill, plus
/// `reunioes/`), its line in the vault README and the links that approved
/// docs add to the project's `index.md`. Pure text in, text out.
public enum OKProjectScaffold {
    static let projectsHeading = "## Projetos"
    static let knowledgeHeading = "## Conhecimento registrado"
    static let indexPlaceholder = "_Links aparecem aqui conforme docs são criados._"

    /// `<project>/<folder>/.ok/frontmatter.yml` for the seven type folders,
    /// `reunioes` and `reunioes/transcricoes`.
    public static func folderMetadata(project: String) -> [OKFileWrite] {
        let meetings = OKMeetingPaths.meetingsFolder
        let transcripts = "\(meetings)/\(OKMeetingPaths.transcriptsFolder)"
        return OKKnowledgeType.allCases.map {
            folderFile(project: project, folder: $0.folder, title: $0.folderTitle(project: project),
                       description: $0.folderDescription(project: project), tags: $0.folderTags(project: project))
        } + [
            folderFile(project: project, folder: meetings, title: "Reuniões — \(project)",
                       description: "Registros de reuniões do \(project), gravados pelo VoiceType.", tags: ["reuniao", project]),
            folderFile(project: project, folder: transcripts, title: "Transcrições — \(project)",
                       description: "Transcrições brutas das reuniões do \(project) (fonte não confiável).", tags: ["transcricao", project]),
        ]
    }

    /// `<project>/index.md` (`type: indice`), as in step 3 of `novo-projeto`,
    /// with the user's description as the opening paragraph.
    public static func index(project: String, description: String) -> OKFileWrite {
        let title = "\(project) — visão geral"
        let about = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = frontmatter([
            ("title", MeetingNoteRenderer.yamlString(title)),
            ("description", MeetingNoteRenderer.yamlString("Índice do conhecimento do projeto \(project).")),
            ("type", "indice"),
            ("project", project),
            ("tags", "[indice, \(project)]"),
        ]) + "# \(title)\n\n" + (about.isEmpty ? "" : "\(about)\n\n") + "\(knowledgeHeading)\n\n\(indexPlaceholder)\n"
        return OKFileWrite(path: "\(project)/index.md", content: content)
    }

    /// `readme` with `- [<project> — <description>](./<project>/index.md)`
    /// after the last `- ` item of `## Projetos` (the section is appended when
    /// missing). A README already linking the project comes back unchanged.
    public static func readmeAddingProject(_ readme: String, project: String, description: String) -> String {
        let target = "./\(project)/index.md"
        var lines = contentLines(readme)
        guard !lines.contains(where: { $0.contains("](\(target))") }) else { return readme }
        let item = "- [\(OKMeetingRenderer.linkText("\(project) — \(description)"))](\(target))"
        if let section = lines.firstIndex(where: { trimmed($0) == projectsHeading }) {
            let end = sectionEnd(lines, after: section)
            if let last = (section + 1 ..< end).last(where: { lines[$0].hasPrefix("- ") }) {
                lines.insert(item, at: last + 1)
            } else {
                lines.insert(contentsOf: ["", item], at: section + 1)
            }
        } else {
            lines += (lines.isEmpty ? [] : [""]) + [projectsHeading, "", item]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `index` with `- [<title>](./<folder>/<file>)` per link under
    /// `## Conhecimento registrado` → `### <indexHeading>` (any `### Decisões…`
    /// for a decision), after the subsection's last item. Missing subsection
    /// or section → created at the end of the section or file. The
    /// placeholder line goes away; a link already in the index isn't added
    /// again. `path` is vault-relative (`<project>/<folder>/<file>.md`).
    public static func indexAddingLinks(_ index: String, links: [(type: OKKnowledgeType, title: String, path: String)]) -> String {
        var lines = contentLines(index)
        var changed = false
        for link in links where addLink(&lines, type: link.type, title: link.title, path: link.path) {
            changed = true
        }
        return changed ? lines.joined(separator: "\n") + "\n" : index
    }

    // MARK: - Helpers

    private static func addLink(_ lines: inout [String], type: OKKnowledgeType, title: String, path: String) -> Bool {
        let project = path.split(separator: "/").first.map(String.init) ?? ""
        let relative = OKPath.relativeLink(from: "\(project)/index.md", to: path)
        let target = "./\(relative)"
        guard !lines.contains(where: { $0.contains("](\(target))") || $0.contains("](\(relative))") }) else { return false }
        let item = "- [\(OKMeetingRenderer.linkText(title))](\(target))"

        let section: Int
        if let found = lines.firstIndex(where: { trimmed($0) == knowledgeHeading }) {
            section = found
        } else {
            lines += (lines.isEmpty ? [] : [""]) + [knowledgeHeading]
            section = lines.count - 1
        }
        for i in (section + 1 ..< sectionEnd(lines, after: section)).reversed() where lines[i].hasPrefix("_Links aparecem aqui") {
            lines.remove(at: i)
        }
        let end = sectionEnd(lines, after: section)

        func isSubsection(_ line: String) -> Bool {
            let t = trimmed(line)
            return type == .decisao ? t.hasPrefix("### Decisões") : t == "### \(type.indexHeading)"
        }
        if let heading = (section + 1 ..< end).first(where: { isSubsection(lines[$0]) }) {
            let subEnd = (heading + 1 ..< end).first(where: { lines[$0].hasPrefix("### ") }) ?? end
            if let last = (heading + 1 ..< subEnd).last(where: { lines[$0].hasPrefix("- ") }) {
                lines.insert(item, at: last + 1)
            } else {
                lines.insert(contentsOf: ["", item], at: heading + 1)
            }
        } else {
            var at = end
            while at > section + 1, trimmed(lines[at - 1]).isEmpty { at -= 1 }
            lines.removeSubrange(at ..< end)
            var block = ["", "### \(type.indexHeading)", "", item]
            if at < lines.count { block.append("") }
            lines.insert(contentsOf: block, at: at)
        }
        return true
    }

    /// The file's lines without the trailing blank ones (callers add the
    /// final newline back).
    private static func contentLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, trimmed(last).isEmpty { lines.removeLast() }
        return lines
    }

    /// Index of the next `## ` heading after `start`, else the line count.
    private static func sectionEnd(_ lines: [String], after start: Int) -> Int {
        (start + 1 ..< lines.count).first(where: { lines[$0].hasPrefix("## ") }) ?? lines.count
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private static func folderFile(project: String, folder: String, title: String, description: String, tags: [String]) -> OKFileWrite {
        OKFileWrite(
            path: "\(project)/\(folder)/.ok/frontmatter.yml",
            content: "title: \(title)\ndescription: \(description)\ntags:\n" + tags.map { "  - \($0)\n" }.joined()
        )
    }

    private static func frontmatter(_ fields: [(String, String)]) -> String {
        "---\n" + fields.map { "\($0.0): \($0.1)\n" }.joined() + "---\n\n"
    }
}
