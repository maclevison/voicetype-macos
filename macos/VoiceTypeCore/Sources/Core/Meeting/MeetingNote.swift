import Foundation

// A finished meeting, ready to be written as Markdown into a notes folder
// (an Obsidian vault in practice, but any folder works — plain files, no API).
public struct MeetingNote: Codable, Sendable, Equatable {
    /// Stable identity. Written to the frontmatter and used by the writer to
    /// make re-saves idempotent (retry after a partial failure overwrites the
    /// same file instead of creating "(2)").
    public var id: UUID
    public var startedAt: Date
    public var duration: TimeInterval
    /// `MeetingApp.platform` ("teams", "zoom", "browser", ...); nil/empty =
    /// unknown, omitted from the frontmatter.
    public var platform: String?
    public var summary: MeetingSummary
    /// Merged transcript ("Você:" / "Outros:" lines). Nil = no transcript file.
    public var transcript: String?
    /// The calendar invite, if one matched: organizer/participants become
    /// `[[Name]]` links in the frontmatter.
    public var event: MeetingCalendarEvent?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        duration: TimeInterval,
        platform: String? = nil,
        summary: MeetingSummary,
        transcript: String? = nil,
        event: MeetingCalendarEvent? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.platform = platform
        self.summary = summary
        self.transcript = transcript
        self.event = event
    }
}

public enum MeetingNoteRenderer {
    /// "2026-10-13 1430 Sprint review" — no extension.
    public static func baseName(for note: MeetingNote, timeZone: TimeZone = .current) -> String {
        let stamp = formatter("yyyy-MM-dd HHmm", timeZone).string(from: note.startedAt)
        let title = fileSafe(note.summary.title)
        return title.isEmpty ? stamp : "\(stamp) \(title)"
    }

    public static func transcriptBaseName(for note: MeetingNote, timeZone: TimeZone = .current) -> String {
        "\(baseName(for: note, timeZone: timeZone)) — transcrição"
    }

    /// Obsidian-safe file name: strips characters that break links or
    /// filesystems (`/ \ : * ? " < > | # ^ [ ]`), no leading dot, ≤ 80 chars.
    static func fileSafe(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]").union(.newlines).union(.controlCharacters)
        var name = value.unicodeScalars
            .map { forbidden.contains($0) ? " " : String($0) }
            .joined()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        // A leading dot would make the file hidden; cap length well under NAME_MAX.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name
    }

    /// `transcriptLink` / `noteLink` are file names without extension.
    public static func renderNote(_ note: MeetingNote, transcriptLink: String? = nil, timeZone: TimeZone = .current) -> String {
        let s = note.summary
        var fields: [(String, String)] = [
            ("id", note.id.uuidString),
            ("type", "meeting"),
            ("title", yamlString(s.title)),
            ("date", formatter("yyyy-MM-dd", timeZone).string(from: note.startedAt)),
            ("created", formatter("yyyy-MM-dd'T'HH:mm:ssxxx", timeZone).string(from: note.startedAt)),
            ("duration_minutes", "\(max(1, Int((note.duration / 60).rounded())))"),
        ]
        if let platform = note.platform, !platform.isEmpty { fields.append(("platform", yamlString(platform))) }
        if let org = s.org { fields.append(("org", yamlString("[[\(org)]]"))) }
        if let client = s.client { fields.append(("client", yamlString(client))) }
        if let type = s.meetingType { fields.append(("meeting_type", type)) }
        if let organizer = note.event?.organizer.map(personLink) { fields.append(("organizer", yamlString(organizer))) }
        let people = (note.event?.participants ?? []).map(personLink)
        if !people.isEmpty { fields.append(("participants", "[" + people.map(yamlString).joined(separator: ", ") + "]")) }
        if let transcriptLink { fields.append(("transcript", yamlString("[[\(transcriptLink)]]"))) }
        fields.append(("tags", "[meeting]"))

        var out = frontmatter(fields) + "# \(singleLine(s.title))\n\n## Resumo\n\n\(s.summary)\n"
        if !s.decisions.isEmpty {
            out += "\n## Decisões\n\n" + s.decisions.map { "- \(singleLine($0))\n" }.joined()
        }
        if !s.actionItems.isEmpty {
            out += "\n## Action items\n\n" + s.actionItems.map { taskLine($0) + "\n" }.joined()
        }
        if let speakers = s.speakers, !speakers.isEmpty {
            out += "\n## Vozes\n\n" + speakers.map { "- \($0.label): provavelmente \(personLink($0.name))\n" }.joined()
                + "\nSugestão a partir da conversa; a transcrição mantém os rótulos originais.\n"
        }
        if let transcriptLink {
            out += "\n## Transcrição\n\n[[\(transcriptLink)]]\n"
        }
        return out
    }

    /// `[[Ana Silva]]`; characters that break a wikilink are dropped.
    static func personLink(_ name: String) -> String {
        "[[\(fileSafe(name))]]"
    }

    /// Dataview task: `- [ ] task [owner:: Nome] [due:: 2026-10-16]`.
    static func taskLine(_ item: MeetingSummary.ActionItem) -> String {
        var line = "- [ ] \(singleLine(item.task))"
        if let owner = item.owner { line += " [owner:: \(singleLine(owner))]" }
        if let due = item.dueDate { line += " [due:: \(due)]" }
        return line
    }

    public static func renderTranscript(_ note: MeetingNote, transcript: String, noteLink: String, timeZone: TimeZone = .current) -> String {
        frontmatter([
            ("id", note.id.uuidString),
            ("type", "transcript"),
            ("meeting", yamlString("[[\(noteLink)]]")),
            ("date", formatter("yyyy-MM-dd", timeZone).string(from: note.startedAt)),
            ("tags", "[transcript]"),
        ]) + "# \(singleLine(note.summary.title)) — transcrição\n\n\(transcript)\n"
    }

    /// Index note for an org at the vault root (`<Org>.md`): Dataview queries
    /// over `Meetings/` matching notes whose `org` links here.
    public static func renderOrgIndex(org: String) -> String {
        frontmatter([("type", "org"), ("tags", "[org]")]) + """
        # \(singleLine(org))

        Reuniões e tarefas abertas de \(singleLine(org)), montadas pelo plugin Dataview a partir das notas \
        em `Meetings/`. Criada uma vez pelo VoiceType e nunca sobrescrita — edite à vontade.

        ## Reuniões por cliente

        ```dataview
        TABLE rows.file.link AS "Reunião", rows.date AS "Data", rows.meeting_type AS "Tipo"
        FROM "Meetings"
        WHERE org = this.file.link
        SORT date DESC
        GROUP BY client
        ```

        ## Tarefas abertas

        ```dataview
        TASK
        FROM "Meetings"
        WHERE !completed AND org = this.file.link
        ```

        """
    }

    // MARK: - Helpers

    /// YAML double-quoted scalar: escapes `\` and `"`, folds newlines to spaces
    /// so model output can never break out of the frontmatter.
    static func yamlString(_ value: String) -> String {
        let flat = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        return "\"\(flat)\""
    }

    /// Model output may carry newlines; a heading must stay on one line.
    static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
    }

    private static func frontmatter(_ fields: [(String, String)]) -> String {
        "---\n" + fields.map { "\($0.0): \($0.1)\n" }.joined() + "---\n\n"
    }

    static func formatter(_ format: String, _ timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = format
        return f
    }
}

public enum MeetingNoteWriter {
    public struct Written: Sendable, Equatable {
        public let note: URL
        public let transcript: URL?
        /// `<vault>/<Org>.md` when this write created it (nil if it existed).
        public let orgIndex: URL?
    }

    /// Vault layout: `Meetings/YYYY/` for notes, `Transcripts/YYYY/` for
    /// transcripts, `<Org>.md` index notes at the root. Obsidian resolves
    /// `[[name]]` vault-wide, so links don't carry folders.
    public static let notesSubfolder = "Meetings"
    public static let transcriptsSubfolder = "Transcripts"

    /// Writes the note (and its transcript, if any) under `vault`, creating
    /// folders as needed, plus the org index note if missing. Each file is
    /// written atomically. Name collisions with a *different* meeting get
    /// " (2)", " (3)", ...; a file that already carries this meeting's id is
    /// overwritten, so retries are idempotent.
    public static func write(
        _ note: MeetingNote,
        to vault: URL,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> Written {
        let year = MeetingNoteRenderer.formatter("yyyy", timeZone).string(from: note.startedAt)
        func folder(_ sub: String) throws -> URL {
            let url = vault.appendingPathComponent(sub, isDirectory: true).appendingPathComponent(year, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        let noteURL = destination(
            base: MeetingNoteRenderer.baseName(for: note, timeZone: timeZone),
            id: note.id, in: try folder(notesSubfolder), fileManager: fileManager
        )
        let noteLink = noteURL.deletingPathExtension().lastPathComponent

        var transcriptURL: URL?
        if let transcript = note.transcript {
            let url = destination(
                base: MeetingNoteRenderer.transcriptBaseName(for: note, timeZone: timeZone),
                id: note.id, in: try folder(transcriptsSubfolder), fileManager: fileManager
            )
            try Data(MeetingNoteRenderer.renderTranscript(note, transcript: transcript, noteLink: noteLink, timeZone: timeZone).utf8)
                .write(to: url, options: .atomic)
            transcriptURL = url
        }

        let link = transcriptURL.map { $0.deletingPathExtension().lastPathComponent }
        try Data(MeetingNoteRenderer.renderNote(note, transcriptLink: link, timeZone: timeZone).utf8)
            .write(to: noteURL, options: .atomic)

        return Written(note: noteURL, transcript: transcriptURL, orgIndex: try note.summary.org.flatMap {
            try writeOrgIndex($0, in: vault, fileManager: fileManager)
        })
    }

    /// Creates `<vault>/<Org>.md` once; an existing file (the user's edits) is
    /// never touched. Returns the URL only when it was created now.
    /// ponytail: file name is `fileSafe(org)` but the notes link `[[org]]`;
    /// they only diverge for org names with `/ : # [ ]`..., which the catalog doesn't have.
    static func writeOrgIndex(_ org: String, in vault: URL, fileManager: FileManager) throws -> URL? {
        let name = MeetingNoteRenderer.fileSafe(org)
        guard !name.isEmpty else { return nil }
        let url = vault.appendingPathComponent("\(name).md")
        guard !fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            try Data(MeetingNoteRenderer.renderOrgIndex(org: org).utf8).write(to: url, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            return nil
        }
        return url
    }
    static func destination(base: String, id: UUID, in directory: URL, fileManager: FileManager) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? "\(base).md" : "\(base) (\(n)).md"
            let url = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: url.path) || belongs(url, to: id) { return url }
            n += 1
        }
    }

    /// True when the file's frontmatter carries `id: <id>`. Reads only the
    /// head (64 KiB): an OpenKnowledge record puts `id` after the title,
    /// description and participants, so it can sit well past the first lines.
    static func belongs(_ url: URL, to id: UUID) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 64 * 1024) else { return false }
        let text = String(decoding: head, as: UTF8.self)
        guard text.hasPrefix("---\n") else { return false }
        let frontmatter = text.range(of: "\n---\n").map { text[..<$0.upperBound] } ?? text[...]
        return frontmatter.contains("\nid: \(id.uuidString)\n")
    }
}
