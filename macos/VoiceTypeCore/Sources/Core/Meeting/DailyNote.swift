import Foundation

// #79 mode 1: a dictated idea appended to today's daily note in the vault —
// `<vault>/Daily/YYYY/YYYY-MM-DD.md`, one `- HH:mm [[idea note|Título]]` (or
// the plain text, when the assistant CLI is unavailable) under `## Ideias`.
public enum DailyNote {
    public static let subfolder = "Daily"
    static let ideasHeading = "## Ideias"
    /// Obsidian's bundle id: the voice-note "target" for refine style + history.
    public static let obsidianBundleID = "md.obsidian"

    public static func url(in vault: URL, for date: Date, timeZone: TimeZone = .current) -> URL {
        let day = MeetingNoteRenderer.formatter("yyyy-MM-dd", timeZone).string(from: date)
        return vault.appendingPathComponent(subfolder, isDirectory: true)
            .appendingPathComponent(String(day.prefix(4)), isDirectory: true)
            .appendingPathComponent("\(day).md")
    }

    /// `- 14:32 first line` + continuation lines indented 2 spaces so they stay
    /// inside the list item. Blank lines are dropped (they'd end the item).
    static func entry(_ text: String, at date: Date, timeZone: TimeZone) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return [] }
        let time = MeetingNoteRenderer.formatter("HH:mm", timeZone).string(from: date)
        return ["- \(time) \(first)"] + lines.dropFirst().map { "  \($0)" }
    }

    /// `[[2026-10-14 1432 Título|Título]]` — the daily's timeline entry for an
    /// idea note. The alias is file-safe, so `|`/`]` can't break the link.
    public static func link(to note: URL, title: String) -> String {
        "[[\(note.deletingPathExtension().lastPathComponent)|\(MeetingNoteRenderer.fileSafe(title))]]"
    }

    /// Returns `existing` (nil = file doesn't exist) with the idea appended to
    /// the end of `## Ideias`, creating the note or the section when missing.
    /// User content is never removed — lines are only inserted. A new note
    /// starts with `newFileHeader` (nil = the Obsidian `type: daily` frontmatter).
    /// ponytail: a `## ` line inside a code fence counts as a section break;
    /// only matters if a daily note has fenced markdown below `## Ideias`.
    public static func inserting(
        _ text: String,
        at date: Date,
        into existing: String?,
        timeZone: TimeZone = .current,
        newFileHeader: String? = nil
    ) -> String {
        let entry = entry(text, at: date, timeZone: timeZone)
        guard !entry.isEmpty else { return existing ?? "" }

        guard let existing else {
            let day = MeetingNoteRenderer.formatter("yyyy-MM-dd", timeZone).string(from: date)
            let header = newFileHeader ?? "---\ntype: daily\ndate: \(day)\ntags: [daily]\n---\n\n"
            return header + "\(ideasHeading)\n\n" + entry.joined(separator: "\n") + "\n"
        }

        var lines = existing.components(separatedBy: "\n")
        guard let heading = lines.firstIndex(where: { trimmedEnd($0) == ideasHeading }) else {
            let base = existing.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            return (base.isEmpty ? "" : base + "\n\n") + "\(ideasHeading)\n\n" + entry.joined(separator: "\n") + "\n"
        }
        let end = lines[(heading + 1)...].firstIndex(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") }) ?? lines.count
        if let last = lines[(heading + 1)..<end].lastIndex(where: { !trimmedEnd($0).isEmpty }) {
            lines.insert(contentsOf: entry, at: last + 1)
        } else {
            lines.insert(contentsOf: [""] + entry, at: heading + 1)
        }
        let out = lines.joined(separator: "\n")
        return out.hasSuffix("\n") ? out : out + "\n"
    }

    /// Reads today's note (if any), inserts the idea and writes it back
    /// atomically. A file that can't be read as UTF-8 throws instead of
    /// being overwritten.
    @discardableResult
    public static func append(
        _ text: String,
        at date: Date = Date(),
        to vault: URL,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = url(in: vault, for: date, timeZone: timeZone)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = fileManager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
        try Data(inserting(text, at: date, into: existing, timeZone: timeZone).utf8).write(to: url, options: .atomic)
        return url
    }

    private static func trimmedEnd(_ line: String) -> String {
        line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }
}
