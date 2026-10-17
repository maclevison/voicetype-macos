import Foundation

/// A strict reader for the YAML a frontmatter holds: block mappings and
/// sequences indented with spaces, plain, single- and double-quoted scalars
/// (on one line or continued on more indented ones), `|`/`>` block scalars
/// and one-line flow sequences of scalars. What it can't prove valid is
/// refused instead of guessed: tabs, flow mappings, nested flow collections,
/// anchors, aliases, tags, directives, explicit `?` keys, `<<` merges,
/// comments after a plain scalar, a trailing comma, indentation indicators,
/// repeated keys and characters YAML doesn't allow. So whatever it accepts
/// parses, with the same structure, in YAML 1.1 and 1.2 parsers.
enum OKYAML {
    indirect enum Node {
        case null
        /// `plain`: written without quotes, so a YAML parser may read it as
        /// something other than a string (see `isString`).
        case scalar(String, plain: Bool)
        case sequence([Node])
        case mapping([(key: String, value: Node)])

        /// A string for YAML 1.1 and 1.2 alike: quoted or a block scalar, or
        /// a plain scalar that doesn't read as null, a boolean, a number or a
        /// date (`2024`, `yes`, `1:30` and `2026-10-16` don't count).
        var isString: Bool {
            guard case let .scalar(text, plain) = self else { return false }
            return !plain || !OKYAML.resolvesToNonString(text)
        }

        func value(_ key: String) -> Node? {
            guard case let .mapping(entries) = self else { return nil }
            return entries.first { $0.key == key }?.value
        }
    }

    /// The document, or `nil` when it isn't valid in the subset above. An
    /// empty one (blank lines and comments) is `.null`.
    static func parse(_ text: String) -> Node? {
        var parser = Parser(lines: text.split(separator: "\n", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) })
        return try? parser.document()
    }

    private struct Invalid: Error {}

    private static let indicators = Set("-?:,[]{}#&*!|>'\"%@`".unicodeScalars)

    private struct Parser {
        var lines: [[Unicode.Scalar]]
        var i = 0

        mutating func document() throws -> Node {
            guard lines.allSatisfy({ $0.allSatisfy(OKYAML.isAllowed) }) else { throw Invalid() }
            skipBlank()
            guard i < lines.count else { return .null }
            guard indentation(lines[i]) == 0 else { throw Invalid() }
            let node = try mapping(0)
            skipBlank()
            guard i == lines.count else { throw Invalid() }
            return node
        }

        // MARK: Collections

        /// Entries at column `n`; a line indented differently, or that isn't
        /// `key: …`, ends it (less indented) or is an error.
        mutating func mapping(_ n: Int) throws -> Node {
            var entries: [(key: String, value: Node)] = []
            var seen: Set<String> = []
            while true {
                skipBlank()
                guard i < lines.count else { break }
                let line = lines[i]
                let column = indentation(line)
                if column < n { break }
                guard column == n, let (key, after) = try key(line, at: n), seen.insert(key).inserted else { throw Invalid() }
                entries.append((key, try value(line, from: after, parent: n, isMappingValue: true)))
            }
            return .mapping(entries)
        }

        /// `- item` lines at column `n`. An item with content on the dash's
        /// line is read with the dash turned into a space, so `- a: 1` opens
        /// a mapping at the column of `a`, as in YAML.
        mutating func sequence(_ n: Int) throws -> Node {
            var items: [Node] = []
            while true {
                skipBlank()
                guard i < lines.count else { break }
                var line = lines[i]
                let column = indentation(line)
                // A key at the dash's column belongs to the mapping this sequence is a value of.
                if column < n || (column == n && !isDash(line, at: n)) { break }
                guard column == n else { throw Invalid() }
                var k = n + 1
                while k < line.count, line[k] == " " { k += 1 }
                if k == line.count || line[k] == "#" {
                    i += 1
                    items.append(try block(parent: n, isMappingValue: false))
                    continue
                }
                line[n] = " "
                lines[i] = line
                if try key(line, at: k) != nil {
                    items.append(try mapping(k))
                } else if isDash(line, at: k) {
                    items.append(try sequence(k))
                } else {
                    items.append(try value(line, from: k, parent: n, isMappingValue: false))
                }
            }
            return .sequence(items)
        }

        /// What follows an entry with nothing after its `:` or dash: a more
        /// indented mapping, sequence or scalar (not a block scalar), a
        /// sequence at the key's own column (mapping values only), or null.
        mutating func block(parent n: Int, isMappingValue: Bool) throws -> Node {
            skipBlank()
            guard i < lines.count else { return .null }
            let line = lines[i]
            let column = indentation(line)
            if column > n {
                if isDash(line, at: column) { return try sequence(column) }
                if try key(line, at: column) != nil { return try mapping(column) }
                guard line[column] != "|", line[column] != ">" else { throw Invalid() }
                return try value(line, from: column, parent: n, isMappingValue: false)
            }
            if column == n, isMappingValue, isDash(line, at: n) { return try sequence(n) }
            return .null
        }

        // MARK: Values

        /// The value starting at `from` on line `i` (consumed with its
        /// continuation lines, which must be indented past `parent`).
        mutating func value(_ line: [Unicode.Scalar], from start: Int, parent n: Int, isMappingValue: Bool) throws -> Node {
            var k = start
            while k < line.count, line[k] == " " { k += 1 }
            i += 1
            guard k < line.count, line[k] != "#" else { return try block(parent: n, isMappingValue: isMappingValue) }
            switch line[k] {
            case "|", ">":
                return try blockScalar(header: Array(line[(k + 1)...]), parent: n)
            case "\"", "'":
                return try quoted(line, from: k, parent: n)
            case "[":
                var items: [Node] = []
                var j = k + 1
                while true {
                    while j < line.count, line[j] == " " { j += 1 }
                    guard j < line.count else { throw Invalid() }
                    if line[j] == "]", items.isEmpty { j += 1; break }
                    let (item, end) = try flowScalar(line, from: j)
                    items.append(item)
                    j = end
                    while j < line.count, line[j] == " " { j += 1 }
                    guard j < line.count else { throw Invalid() }
                    if line[j] == "]" { j += 1; break }
                    guard line[j] == "," else { throw Invalid() }
                    j += 1
                }
                try expectEnd(line, from: j)
                return .sequence(items)
            default:
                return try plain(line, from: k, parent: n)
            }
        }

        /// A plain scalar and its continuation lines, folded with spaces.
        mutating func plain(_ line: [Unicode.Scalar], from k: Int, parent n: Int) throws -> Node {
            let first = line[k]
            if OKYAML.indicators.contains(first) {
                // `-x` is a plain scalar; `- x`, `?`, `:` and the rest open something else.
                guard first == "-", k + 1 < line.count, line[k + 1] != " " else { throw Invalid() }
            }
            var text = try plainText(line[k...])
            while i < lines.count {
                var j = i
                while j < lines.count, isBlank(lines[j]) { j += 1 }
                guard j < lines.count, indentation(lines[j]) > n else { break }
                let next = lines[j]
                let content = next[indentation(next)...]
                if content.first == "#" { break }
                text += " " + (try plainText(content))
                i = j + 1
            }
            return .scalar(text, plain: true)
        }

        /// One line of a plain scalar, trimmed: no `: `, ` #` or final `:`.
        func plainText(_ s: ArraySlice<Unicode.Scalar>) throws -> String {
            let chars = Array(s)
            for (j, c) in chars.enumerated() {
                if c == ":", j + 1 == chars.count || chars[j + 1] == " " { throw Invalid() }
                if c == "#", j > 0, chars[j - 1] == " " { throw Invalid() }
            }
            var text = ""
            text.unicodeScalars.append(contentsOf: chars)
            return text.trimmingCharacters(in: .whitespaces)
        }

        /// A quoted scalar starting at `from`, maybe continued on lines
        /// indented past `parent`; only blanks or a comment may follow it.
        mutating func quoted(_ line: [Unicode.Scalar], from k: Int, parent n: Int) throws -> Node {
            let quote = line[k]
            var current = line
            var j = k + 1
            var text = ""
            while true {
                if j >= current.count {
                    guard i < lines.count else { throw Invalid() }
                    current = lines[i]
                    i += 1
                    if !isBlank(current) { guard indentation(current) > n else { throw Invalid() } }
                    j = indentation(current)
                    text += " "
                    continue
                }
                let c = current[j]
                if quote == "'" {
                    if c == "'" {
                        if j + 1 < current.count, current[j + 1] == "'" { text += "'"; j += 2; continue }
                        j += 1
                        break
                    }
                } else if c == "\"" {
                    j += 1
                    break
                } else if c == "\\" {
                    if j + 1 == current.count { j += 1; continue }
                    guard let (decoded, width) = OKYAML.escape(current, at: j) else { throw Invalid() }
                    text += decoded
                    j += width
                    continue
                }
                text.unicodeScalars.append(c)
                j += 1
            }
            try expectEnd(current, from: j)
            return .scalar(text, plain: false)
        }

        /// One item of a flow sequence: quoted on this line, or plain without
        /// `[]{},:#`. Returns the item and the index after it.
        func flowScalar(_ line: [Unicode.Scalar], from k: Int) throws -> (Node, Int) {
            let c = line[k]
            if c == "\"" || c == "'" {
                guard let (text, end) = OKYAML.quotedOnLine(line, from: k) else { throw Invalid() }
                return (.scalar(text, plain: false), end)
            }
            if OKYAML.indicators.contains(c) {
                guard c == "-", k + 1 < line.count, !" ,[]{}".unicodeScalars.contains(line[k + 1]) else { throw Invalid() }
            }
            var j = k
            while j < line.count, line[j] != ",", line[j] != "]" {
                guard !"[]{}:#".unicodeScalars.contains(line[j]) else { throw Invalid() }
                j += 1
            }
            let text = try plainText(line[k..<j])
            guard !text.isEmpty else { throw Invalid() }
            return (.scalar(text, plain: true), j)
        }

        /// `|` or `>` with an optional `+`/`-`, then lines indented past
        /// `parent` (the first one sets the indentation) or blank.
        mutating func blockScalar(header: [Unicode.Scalar], parent n: Int) throws -> Node {
            var h = 0
            if h < header.count, header[h] == "+" || header[h] == "-" { h += 1 }
            try expectEnd(header, from: h)
            var content: Int?
            var text: [String] = []
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    if content == nil, line.count > n + 1 { throw Invalid() }
                    text.append("")
                    i += 1
                    continue
                }
                let column = indentation(line)
                guard column > n else { break }
                if let content {
                    guard column >= content else { throw Invalid() }
                } else {
                    content = column
                }
                var s = ""
                s.unicodeScalars.append(contentsOf: line[(content ?? column)...])
                text.append(s)
                i += 1
            }
            return .scalar(text.joined(separator: "\n"), plain: false)
        }

        // MARK: Lines

        /// A `key:` at column `k` (plain, or quoted on this line) → the key and
        /// the index after the `:`. `nil` when the line isn't a mapping entry.
        func key(_ line: [Unicode.Scalar], at k: Int) throws -> (String, Int)? {
            guard k < line.count else { return nil }
            var key = ""
            var j: Int
            let c = line[k]
            if c == "\"" || c == "'" {
                guard let (text, end) = OKYAML.quotedOnLine(line, from: k) else { return nil }
                key = text
                j = end
                while j < line.count, line[j] == " " { j += 1 }
                guard j < line.count, line[j] == ":", j + 1 == line.count || line[j + 1] == " " else { return nil }
            } else {
                if OKYAML.indicators.contains(c) {
                    guard c == "-", k + 1 < line.count, line[k + 1] != " " else { return nil }
                }
                j = k
                while j < line.count, !(line[j] == ":" && (j + 1 == line.count || line[j + 1] == " ")) {
                    if line[j] == "#", j > k, line[j - 1] == " " { return nil }
                    j += 1
                }
                guard j < line.count else { return nil }
                key.unicodeScalars.append(contentsOf: line[k..<j])
                key = key.trimmingCharacters(in: .whitespaces)
                if key == "<<" { throw Invalid() }
            }
            return (key, j + 1)
        }

        func isDash(_ line: [Unicode.Scalar], at k: Int) -> Bool {
            k < line.count && line[k] == "-" && (k + 1 == line.count || line[k + 1] == " ")
        }

        func indentation(_ line: [Unicode.Scalar]) -> Int {
            line.prefix { $0 == " " }.count
        }

        func isBlank(_ line: [Unicode.Scalar]) -> Bool {
            line.allSatisfy { $0 == " " }
        }

        /// Blank and comment lines.
        mutating func skipBlank() {
            while i < lines.count {
                let line = lines[i]
                guard isBlank(line) || line[indentation(line)] == "#" else { return }
                i += 1
            }
        }

        /// Only blanks, or blanks and a comment, from `k` to the end.
        func expectEnd(_ line: [Unicode.Scalar], from k: Int) throws {
            var j = k
            while j < line.count, line[j] == " " { j += 1 }
            guard j == line.count || (line[j] == "#" && j > k) else { throw Invalid() }
        }
    }

    // MARK: - Scalars

    /// `'…'` or `"…"` starting at `k` and closing on the same line → the text
    /// and the index after the quote.
    static func quotedOnLine(_ s: [Unicode.Scalar], from k: Int) -> (String, Int)? {
        let quote = s[k]
        var out = ""
        var j = k + 1
        while j < s.count {
            let c = s[j]
            if quote == "'", c == "'" {
                if j + 1 < s.count, s[j + 1] == "'" { out += "'"; j += 2; continue }
                return (out, j + 1)
            }
            if quote == "\"", c == "\"" { return (out, j + 1) }
            if quote == "\"", c == "\\" {
                guard let (decoded, width) = escape(s, at: j) else { return nil }
                out += decoded
                j += width
                continue
            }
            out.unicodeScalars.append(c)
            j += 1
        }
        return nil
    }

    /// The YAML escape at `s[k]` (a backslash) → its text and width; an
    /// unknown or truncated escape → `nil`.
    static func escape(_ s: [Unicode.Scalar], at k: Int) -> (String, Int)? {
        let simple: [Unicode.Scalar: String] = [
            "0": "\u{0}", "a": "\u{7}", "b": "\u{8}", "t": "\t", "n": "\n", "v": "\u{B}",
            "f": "\u{C}", "r": "\r", "e": "\u{1B}", " ": " ", "\"": "\"", "/": "/", "\\": "\\",
            "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
        ]
        guard k + 1 < s.count else { return nil }
        let e = s[k + 1]
        if let text = simple[e] { return (text, 2) }
        let width = e == "x" ? 2 : e == "u" ? 4 : e == "U" ? 8 : 0
        guard width > 0, k + 2 + width <= s.count else { return nil }
        var hex = ""
        hex.unicodeScalars.append(contentsOf: s[(k + 2)..<(k + 2 + width)])
        guard hex.unicodeScalars.allSatisfy(\.properties.isASCIIHexDigit),
              let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) else { return nil }
        return (String(scalar), 2 + width)
    }

    /// Printable in YAML and never a line break for YAML 1.1: no control
    /// characters (tabs included), `DEL`, C1 controls, `U+2028`/`U+2029`,
    /// BOM or noncharacters.
    static func isAllowed(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x20...0x7E, 0xA0...0x2027, 0x202A...0xD7FF, 0xE000...0xFEFE, 0xFF00...0xFFFD, 0x10000...0x10FFFF: true
        default: false
        }
    }

    /// Plain scalars a YAML 1.1 or 1.2 parser reads as null, a boolean, a
    /// number (sexagesimal and `_` included) or a date.
    static func resolvesToNonString(_ text: String) -> Bool {
        let words: Set<String> = [
            "", "~", "null", "Null", "NULL",
            "true", "True", "TRUE", "false", "False", "FALSE", "yes", "Yes", "YES", "no", "No", "NO",
            "on", "On", "ON", "off", "Off", "OFF", "y", "Y", "n", "N",
            ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF", ".nan", ".NaN", ".NAN",
        ]
        if words.contains(text) { return true }
        let range = NSRange(text.startIndex..., in: text)
        return [number, timestamp].contains { $0.firstMatch(in: text, range: range) != nil }
    }

    private static let number = try! NSRegularExpression(pattern:
        #"^[-+]?(0b[01_]+|0x[0-9a-fA-F_]+|0o[0-7_]+|[0-9][0-9_]*(:[0-5]?[0-9])*(\.[0-9_]*)?([eE][-+]?[0-9]+)?|\.[0-9][0-9_]*([eE][-+]?[0-9]+)?)$"#)

    private static let timestamp = try! NSRegularExpression(pattern:
        #"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(([Tt]| +)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(\.[0-9]*)? *(Z|[-+][0-9]{1,2}(:[0-9]{2})?)?)?$"#)
}
