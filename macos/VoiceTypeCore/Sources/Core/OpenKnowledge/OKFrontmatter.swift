import Foundation

/// Line-based reads and edits of top-level frontmatter keys. Not a YAML
/// parser: enough for the vault's templates and docs (plain or quoted
/// scalars, flow lists, indented blocks), and every edit keeps the other
/// lines byte for byte. Keys are compared by their YAML identity: `project`,
/// `project :`, `'project'` and `"proj\u0065ct"` are the same key.
public enum OKFrontmatter {
    /// The text between the `---` fences (without them) and what follows the
    /// closing fence. No opening `---` line, or no closing one, → `nil` and
    /// the whole input as body.
    public static func split(_ md: String) -> (frontmatter: String?, body: String) {
        guard let parts = fences(md) else { return (nil, md) }
        return (parts.lines.joined(separator: "\n"), parts.body)
    }

    /// A top-level scalar, unquoted (`''` → `'` in single quotes, `\"` and
    /// `\\` in double quotes). Indented lines after it that don't start with
    /// `- ` are folded in with one space. An empty value followed by an
    /// indented block (a map or a list) → `nil`, and so does a key that
    /// appears more than once (ambiguous; see `duplicateKeys`).
    public static func scalar(_ key: String, in md: String) -> String? {
        guard let lines = fences(md)?.lines else { return nil }
        let ranges = keyRanges(key, in: lines)
        guard ranges.count == 1, let range = ranges.first,
              case .key(_, let rawValue) = parseLine(lines[range.lowerBound]) else { return nil }
        var value = rawValue.trimmingCharacters(in: .whitespaces)
        for line in lines[(range.lowerBound + 1)..<range.upperBound] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                if value.isEmpty { return nil }
                break
            }
            if value.isEmpty, !trimmed.isEmpty, trimmed.contains(":") { return nil }
            if !trimmed.isEmpty { value += value.isEmpty ? trimmed : " " + trimmed }
        }
        return unquoted(value)
    }

    /// Replaces `key` (with its indented continuation lines) by `key: yamlValue`
    /// where it first appears and drops any repeated occurrence, so the result
    /// holds the key exactly once. A missing key goes right before the closing
    /// fence, and a document without frontmatter gets one. `yamlValue` is
    /// written as is.
    public static func setting(_ key: String, to yamlValue: String, in md: String) -> String {
        let entry = "\(key): \(yamlValue)"
        guard var parts = fences(md) else { return "---\n\(entry)\n---\n" + md }
        let ranges = keyRanges(key, in: parts.lines)
        if let first = ranges.first {
            for range in ranges.dropFirst().reversed() { parts.lines.removeSubrange(range) }
            parts.lines.replaceSubrange(first, with: [entry])
        } else {
            parts.lines.append(entry)
        }
        return join(parts.lines, parts.closing, parts.body)
    }

    /// Drops every occurrence of `key` with its indented continuation lines;
    /// no key → `md` unchanged.
    public static func removing(_ key: String, in md: String) -> String {
        guard var parts = fences(md) else { return md }
        let ranges = keyRanges(key, in: parts.lines)
        guard !ranges.isEmpty else { return md }
        for range in ranges.reversed() { parts.lines.removeSubrange(range) }
        return join(parts.lines, parts.closing, parts.body)
    }

    /// Top-level keys that appear more than once (by YAML identity), in order
    /// of first appearance. Lines whose key this parser can't read are not
    /// counted, so an empty result alone proves nothing: use `isWellFormed`.
    public static func duplicateKeys(_ md: String) -> [String] {
        guard let lines = fences(md)?.lines else { return [] }
        var seen: Set<String> = []
        var duplicates: [String] = []
        for line in lines {
            guard case .key(let key, _) = parseLine(line) else { continue }
            if !seen.insert(key).inserted, !duplicates.contains(key) { duplicates.append(key) }
        }
        return duplicates
    }

    /// True when the document has a frontmatter whose every top-level line
    /// is a `key: …` this parser reads (or a comment, a blank line, or a list
    /// item or indented line under a key), no key repeats, and the whole of
    /// it is YAML that `OKYAML` accepts. Explicit `? ` keys, flow, anchored,
    /// aliased or tagged keys, `<<` merges, bad escapes, stray scalars and
    /// invalid values (`title: Fila: jobs`, an unclosed quote or list) make
    /// it false: untrusted Markdown that fails this after `setting` is
    /// refused, never written.
    public static func isWellFormed(_ md: String) -> Bool {
        guard let lines = fences(md)?.lines, OKYAML.parse(lines.joined(separator: "\n")) != nil else { return false }
        var seen: Set<String> = []
        for line in lines {
            switch parseLine(line) {
            case .key(let key, _):
                guard seen.insert(key).inserted else { return false }
            case .listItem:
                guard !seen.isEmpty else { return false }
            case .other:
                continue
            case .unsupported:
                return false
            }
        }
        return true
    }

    /// `isWellFormed`, with the fields an OpenKnowledge doc needs in their
    /// YAML types: `title`, `description` and `type` strings, and `tags`,
    /// when present, a list of strings.
    public static func isValidDocument(_ md: String) -> Bool {
        guard isWellFormed(md), let lines = fences(md)?.lines,
              let yaml = OKYAML.parse(lines.joined(separator: "\n")),
              ["title", "description", "type"].allSatisfy({ yaml.value($0)?.isString == true }) else { return false }
        guard let tags = yaml.value("tags") else { return true }
        guard case let .sequence(items) = tags else { return false }
        return items.allSatisfy(\.isString)
    }

    /// True when the frontmatter (never the body) still holds a template `TODO`.
    public static func containsTODO(_ md: String) -> Bool {
        fences(md)?.lines.contains { $0.contains("TODO") } ?? false
    }

    // MARK: - Helpers

    private struct Parts {
        var lines: [String]
        /// `"---\n"`, or `"---"` when the file ends right at the fence.
        var closing: String
        var body: String
    }

    private static func fences(_ md: String) -> Parts? {
        guard md.hasPrefix("---\n") else { return nil }
        var lines: [String] = []
        var rest = md.dropFirst(4)
        while !rest.isEmpty {
            let end = rest.firstIndex(of: "\n")
            let line = String(rest[..<(end ?? rest.endIndex)])
            let next = end.map { rest.index(after: $0) } ?? rest.endIndex
            if line == "---" {
                return Parts(lines: lines, closing: end == nil ? "---" : "---\n", body: String(rest[next...]))
            }
            lines.append(line)
            rest = rest[next...]
        }
        return nil
    }

    private static func join(_ lines: [String], _ closing: String, _ body: String) -> String {
        "---\n" + lines.map { $0 + "\n" }.joined() + closing + body
    }

    /// Each occurrence of the key line plus the indented (or `- ` list) lines
    /// that belong to it, in ascending order.
    private static func keyRanges(_ key: String, in lines: [String]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        while start < lines.count {
            guard case .key(key, _) = parseLine(lines[start]) else { start += 1; continue }
            var end = start + 1
            while end < lines.count, belongsToPrevious(lines[end]) { end += 1 }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    private enum Line: Equatable {
        /// A top-level `key: value`, the key decoded, `value` after the `:`.
        case key(String, value: String)
        /// `- item` at column 0, part of the previous key's block.
        case listItem
        /// Blank, comment or indented line.
        case other
        /// A top-level line whose key this parser can't read.
        case unsupported
    }

    /// Reads a frontmatter line: plain keys (trailing spaces before the `:`
    /// dropped), single-quoted keys (`''`) and double-quoted keys (YAML
    /// escapes). The `:` must be followed by a space, a tab or the line end.
    private static func parseLine(_ line: String) -> Line {
        guard let first = line.unicodeScalars.first else { return .other }
        if first == " " || first == "\t" || first == "#" { return .other }
        if line == "-" || line.hasPrefix("- ") || line.hasPrefix("-\t") { return .listItem }

        let scalars = Array(line.unicodeScalars)
        var key = ""
        var i = 0
        switch first {
        case "\"":
            guard let (decoded, end) = doubleQuoted(scalars) else { return .unsupported }
            (key, i) = (decoded, end)
        case "'":
            guard let (decoded, end) = singleQuoted(scalars) else { return .unsupported }
            (key, i) = (decoded, end)
        default:
            if "?,[]{}&*!|>%@`".unicodeScalars.contains(first) { return .unsupported }
            while i < scalars.count, !(scalars[i] == ":" && isSeparator(scalars, i + 1)) {
                if scalars[i] == "#", i > 0, scalars[i - 1] == " " || scalars[i - 1] == "\t" { return .unsupported }
                key.unicodeScalars.append(scalars[i])
                i += 1
            }
            guard i < scalars.count else { return .unsupported }
            while let last = key.unicodeScalars.last, last == " " || last == "\t" { key.unicodeScalars.removeLast() }
            if key == "<<" { return .unsupported }
        }
        while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" { i += 1 }
        guard i < scalars.count, scalars[i] == ":", isSeparator(scalars, i + 1) else { return .unsupported }
        var value = ""
        value.unicodeScalars.append(contentsOf: scalars[(i + 1)...])
        return .key(key, value: value)
    }

    private static func isSeparator(_ scalars: [Unicode.Scalar], _ i: Int) -> Bool {
        i == scalars.count || scalars[i] == " " || scalars[i] == "\t"
    }

    /// `'…'` starting at index 0 → decoded text and the index after the quote.
    private static func singleQuoted(_ s: [Unicode.Scalar]) -> (String, Int)? {
        var out = ""
        var i = 1
        while i < s.count {
            if s[i] == "'" {
                if i + 1 < s.count, s[i + 1] == "'" { out.append("'"); i += 2; continue }
                return (out, i + 1)
            }
            out.unicodeScalars.append(s[i])
            i += 1
        }
        return nil
    }

    /// `"…"` starting at index 0 → decoded text and the index after the quote;
    /// an unknown escape (invalid YAML) → `nil`.
    private static func doubleQuoted(_ s: [Unicode.Scalar]) -> (String, Int)? {
        let simple: [Unicode.Scalar: String] = [
            "0": "\u{0}", "a": "\u{7}", "b": "\u{8}", "t": "\t", "\t": "\t", "n": "\n", "v": "\u{B}",
            "f": "\u{C}", "r": "\r", "e": "\u{1B}", " ": " ", "\"": "\"", "/": "/", "\\": "\\",
            "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
        ]
        var out = ""
        var i = 1
        while i < s.count {
            let c = s[i]
            if c == "\"" { return (out, i + 1) }
            guard c == "\\" else { out.unicodeScalars.append(c); i += 1; continue }
            guard i + 1 < s.count else { return nil }
            let e = s[i + 1]
            if let text = simple[e] { out += text; i += 2; continue }
            let width = e == "x" ? 2 : e == "u" ? 4 : e == "U" ? 8 : 0
            guard width > 0, i + 2 + width <= s.count else { return nil }
            var hex = ""
            hex.unicodeScalars.append(contentsOf: s[(i + 2)..<(i + 2 + width)])
            guard hex.unicodeScalars.allSatisfy(\.properties.isASCIIHexDigit),
                  let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
            out.unicodeScalars.append(scalar)
            i += 2 + width
        }
        return nil
    }

    private static func belongsToPrevious(_ line: String) -> Bool {
        line.hasPrefix(" ") || line.hasPrefix("\t") || line.hasPrefix("- ") || line == "-"
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.hasPrefix("\""), value.hasSuffix("\"") {
            var out = ""
            var escaping = false
            for ch in value.dropFirst().dropLast() {
                if escaping {
                    if ch != "\"" && ch != "\\" { out.append("\\") }
                    out.append(ch)
                    escaping = false
                } else if ch == "\\" {
                    escaping = true
                } else {
                    out.append(ch)
                }
            }
            if escaping { out.append("\\") }
            return out
        }
        return value
    }
}
