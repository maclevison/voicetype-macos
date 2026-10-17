import Darwin
import Foundation

/// Voice notes in OpenKnowledge mode: the same daily + idea flow as
/// `DailyNote`/`IdeaNote`, under `<vault>/_inbox/` (outside every project),
/// with OK frontmatter and relative Markdown links instead of `[[wikilinks]]`.
public enum OKInbox {
    public static let folder = "_inbox"
    static let dailyFolder = "diario"
    static let ideasFolder = "ideias"
    static let metadata = "title: Inbox\ndescription: Notas de voz do VoiceType (diário e ideias), fora dos projetos.\ntags:\n  - inbox\n"

    /// `<vault>/_inbox/diario/YYYY-MM-DD.md`
    public static func dailyURL(in vault: URL, for date: Date, timeZone: TimeZone = .current) -> URL {
        vault.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(dailyFolder, isDirectory: true)
            .appendingPathComponent("\(day(date, timeZone)).md")
    }

    /// The idea note with OK frontmatter; the body is `IdeaNote.render`'s.
    public static func renderIdea(_ idea: IdeaNote, timeZone: TimeZone = .current) -> String {
        let f = { MeetingNoteRenderer.formatter($0, timeZone).string(from: idea.createdAt) }
        let tags = ["ideia"] + idea.tags.filter { $0 != "ideia" }
        return """
        ---
        id: \(idea.id.uuidString)
        title: \(MeetingNoteRenderer.yamlString(idea.title))
        description: \(MeetingNoteRenderer.yamlString(description(of: idea.text)))
        type: ideia
        date: \(f("yyyy-MM-dd"))
        created: \(f("yyyy-MM-dd'T'HH:mm:ssxxx"))
        tags: [\(tags.joined(separator: ", "))]
        ---

        \(idea.text)

        ## Transcrição original

        \(idea.original.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }

    /// Writes atomically to `_inbox/ideias/YYYY-MM-DD-<slug>.md` (empty slug →
    /// `ideia`); another idea gets `-2`, `-3`…, the same id overwrites.
    @discardableResult
    public static func writeIdea(
        _ idea: IdeaNote,
        to vault: URL,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> URL {
        try writeIdea(idea, to: vault, timeZone: timeZone, fileManager: fileManager, beforeRename: nil)
    }

    /// `beforeRename` sees the staged file right before it is moved in (tests).
    static func writeIdea(
        _ idea: IdeaNote,
        to vault: URL,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default,
        beforeRename: ((URL) throws -> Void)?
    ) throws -> URL {
        let dir = vault.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(ideasFolder, isDirectory: true)
        try prepare(dir, in: vault, fileManager: fileManager)
        let slug = OKSlug.make(from: idea.title)
        let base = "\(day(idea.createdAt, timeZone))-\(slug.isEmpty ? "ideia" : slug)"
        let url = OKPath.uniqueDestination(base: base, id: idea.id, in: dir, fileManager: fileManager)
        try stagedWrite(Data(renderIdea(idea, timeZone: timeZone).utf8), to: url, vault: vault,
                        replacing: true, fileManager: fileManager, beforeRename: beforeRename)
        return url
    }

    /// `[Título](../ideias/<arquivo>.md)` — the daily's entry for an idea.
    /// `[ ] ( )` and line breaks leave the label so they can't break the link.
    public static func link(toIdea idea: URL, title: String, vault: URL) -> String {
        let label = title.unicodeScalars
            .map { "[]()".unicodeScalars.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let root = vault.standardizedFileURL.path + "/"
        let path = idea.standardizedFileURL.path
        let target = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : "\(folder)/\(ideasFolder)/\(idea.lastPathComponent)"
        let from = "\(folder)/\(dailyFolder)/daily.md"
        return "[\(label.isEmpty ? "ideia" : label)](\(OKPath.relativeLink(from: from, to: target)))"
    }

    /// `DailyNote.append` for `_inbox/diario/`: a new day starts with the OK
    /// frontmatter; an existing note only gains lines.
    @discardableResult
    public static func appendToDaily(
        _ text: String,
        at date: Date = Date(),
        to vault: URL,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> URL {
        try appendToDaily(text, at: date, to: vault, timeZone: timeZone, fileManager: fileManager, beforeRename: nil)
    }

    public enum AppendError: Error, Equatable, LocalizedError {
        /// The daily kept changing between each read and the rename.
        case dailyKeepsChanging
        /// The daily changed during the append and couldn't be put back; the
        /// version taken out of it is at this path.
        case outsideVersionKept(String)

        public var errorDescription: String? {
            switch self {
            case .dailyKeepsChanging:
                "O diário de hoje foi alterado durante a gravação da nota de voz. Tente de novo."
            case let .outsideVersionKept(path):
                "O diário de hoje foi alterado durante a gravação da nota de voz e não pôde ser restaurado. A versão alterada foi guardada em \(path)."
            }
        }
    }

    static let dailyAttempts = 5

    /// Where the test hook of `appendToDaily` runs, after a swap took a
    /// version out of the daily: before it's moved to the preserved folder,
    /// and before it's swapped back in. A throw there acts as a failure of
    /// that step.
    enum DailyStep: Equatable { case preserve, restore }

    /// `beforeRename` sees the staged file right before each attempt to move
    /// it in (tests). The new daily goes in only over the version it was
    /// built from: a save in between is put back and the entry is inserted
    /// again into it. Every version taken out of the daily is kept (see
    /// `installDaily`).
    static func appendToDaily(
        _ text: String,
        at date: Date = Date(),
        to vault: URL,
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default,
        beforeRename: ((URL) throws -> Void)?,
        fault: ((DailyStep) throws -> Void)? = nil
    ) throws -> URL {
        let url = dailyURL(in: vault, for: date, timeZone: timeZone)
        try prepare(url.deletingLastPathComponent(), in: vault, fileManager: fileManager)
        let day = day(date, timeZone)
        let header = "---\ntitle: \(MeetingNoteRenderer.yamlString("Diário \(day)"))\n"
            + "description: \(MeetingNoteRenderer.yamlString("Notas de voz de \(day)."))\n"
            + "type: diario\ndate: \(day)\ntags: [diario]\n---\n\n"
        for _ in 0..<dailyAttempts {
            let existing = try readDaily(url)
            let out = DailyNote.inserting(text, at: date, into: existing?.text, timeZone: timeZone, newFileHeader: header)
            if try installDaily(Data(out.utf8), over: existing?.data, at: url, vault: vault,
                                fileManager: fileManager, beforeRename: beforeRename, fault: fault) {
                return url
            }
        }
        throw AppendError.dailyKeepsChanging
    }

    // MARK: - Helpers

    private static func day(_ date: Date, _ timeZone: TimeZone) -> String {
        MeetingNoteRenderer.formatter("yyyy-MM-dd", timeZone).string(from: date)
    }

    /// First non-empty line of the text, at most 160 characters.
    private static func description(of text: String) -> String {
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(160)).trimmingCharacters(in: .whitespaces)
    }

    private static func prepare(_ dir: URL, in vault: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try ensureMetadata(in: vault, fileManager: fileManager)
    }

    /// `_inbox/.ok/frontmatter.yml` (the folder's title in OpenKnowledge),
    /// created when missing and never replaced: moved in with `RENAME_EXCL`,
    /// so a file someone else wrote in the meantime wins.
    private static func ensureMetadata(in vault: URL, fileManager: FileManager) throws {
        let url = vault.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(".ok", isDirectory: true)
            .appendingPathComponent("frontmatter.yml")
        guard !fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try stagedWrite(Data(metadata.utf8), to: url, vault: vault, replacing: false, fileManager: fileManager, beforeRename: nil)
    }

    /// The daily's bytes and text; `nil` when there's no daily. A file that
    /// isn't UTF-8 throws instead of being overwritten.
    private static func readDaily(_ url: URL) throws -> (data: Data, text: String)? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return (data, text)
    }

    /// Moves `data` onto the daily only if it still holds `read` (`nil`: no
    /// daily, created with `RENAME_EXCL`). The update is a `RENAME_SWAP`
    /// whose outcome is checked: when what came out isn't `read`, it's
    /// swapped back and `false` returned for the caller to rebuild on it.
    ///
    /// What comes out of the daily (by either swap) is an inode someone may
    /// still be writing to through a descriptor opened on the daily, so it's
    /// never deleted, on success or on any error: it goes to
    /// `.ok/local/voicetype-preserved/inbox/`, or stays in the staging when
    /// that move fails. When the outside version can't be swapped back,
    /// `outsideVersionKept` says where it is.
    private static func installDaily(
        _ data: Data,
        over read: Data?,
        at url: URL,
        vault: URL,
        fileManager: FileManager,
        beforeRename: ((URL) throws -> Void)?,
        fault: ((DailyStep) throws -> Void)?
    ) throws -> Bool {
        let tmp = try stage(data, for: url, vault: vault, fileManager: fileManager)
        var tmpIsOurs = true
        defer { if tmpIsOurs { try? fileManager.removeItem(at: tmp) } }
        try beforeRename?(tmp)
        guard let read else {
            if renamex_np(tmp.path, url.path, UInt32(RENAME_EXCL)) == 0 { return true }
            guard errno == EEXIST else { throw OKDurableFile.posixError() }
            return false
        }
        guard renamex_np(tmp.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
            guard errno == ENOENT else { throw OKDurableFile.posixError() }
            return false
        }
        tmpIsOurs = false
        try? OKDurableFile.syncDirectory(url.deletingLastPathComponent())
        let kept = retain(tmp, in: vault, fileManager: fileManager, fault: fault)
        guard let out = try? Data(contentsOf: kept) else { throw AppendError.outsideVersionKept(kept.path) }
        if out == read { return true }
        do {
            try fault?(.restore)
            guard renamex_np(kept.path, url.path, UInt32(RENAME_SWAP)) == 0 else { throw OKDurableFile.posixError() }
        } catch {
            throw AppendError.outsideVersionKept(kept.path)
        }
        try? OKDurableFile.syncDirectory(url.deletingLastPathComponent())
        try? OKDurableFile.syncDirectory(kept.deletingLastPathComponent())
        return false
    }

    /// Moves a version taken out of the daily to
    /// `.ok/local/voicetype-preserved/inbox/` (on disk before returning) and
    /// returns where it is: still in the staging when the move fails.
    private static func retain(_ file: URL, in vault: URL, fileManager: FileManager, fault: ((DailyStep) throws -> Void)?) -> URL {
        let dir = vault.appendingPathComponent(".ok/local/voicetype-preserved/inbox", isDirectory: true)
        let target = dir.appendingPathComponent(file.lastPathComponent)
        do {
            try fault?(.preserve)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            guard renamex_np(file.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw OKDurableFile.posixError() }
            try OKDurableFile.syncDirectory(dir)
            try OKDurableFile.syncDirectory(file.deletingLastPathComponent())
            return target
        } catch {
            return fileManager.fileExists(atPath: target.path) ? target : file
        }
    }

    /// A uniquely named copy of `data` under `.ok/local/voicetype-staging/`
    /// (ignored by OpenKnowledge's git), so no temporary or partial copy
    /// ever sits in a content folder, where the OK auto-commit would pick it up.
    private static func stage(_ data: Data, for url: URL, vault: URL, fileManager: FileManager) throws -> URL {
        let staging = vault.appendingPathComponent(".ok/local/voicetype-staging", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let tmp = staging.appendingPathComponent("inbox-\(UUID().uuidString).\(url.pathExtension)")
        try data.write(to: tmp, options: .withoutOverwriting)
        return tmp
    }

    /// Stages `data` (see `stage`) and renames it onto `url`. `replacing:
    /// false` uses `RENAME_EXCL` and keeps an existing file. A failure leaves
    /// `url` as it was.
    private static func stagedWrite(
        _ data: Data,
        to url: URL,
        vault: URL,
        replacing: Bool,
        fileManager: FileManager,
        beforeRename: ((URL) throws -> Void)?
    ) throws {
        let tmp = try stage(data, for: url, vault: vault, fileManager: fileManager)
        defer { try? fileManager.removeItem(at: tmp) }
        try beforeRename?(tmp)
        if renamex_np(tmp.path, url.path, replacing ? 0 : UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            guard !replacing, code == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
    }
}
