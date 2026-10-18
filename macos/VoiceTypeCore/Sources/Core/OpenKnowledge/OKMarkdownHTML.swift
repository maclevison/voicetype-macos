import Foundation

/// Markdown → HTML for the approval Preview, shown in a `WKWebView` with
/// JavaScript off. Covers what the vault's templates and docs use: frontmatter
/// (as a key/value table), headings, paragraphs, lists (one nesting level),
/// task items, pipe tables, quotes and `> [!tipo]` callouts, code fences and
/// inline code, bold, italic and links. Every piece of text is escaped before
/// any markup is added, and `href` only carries `http(s)://` or relative URLs.
public enum OKMarkdownHTML {
    /// The rendered fragment, frontmatter table first.
    public static func body(_ markdown: String) -> String {
        let (frontmatter, body) = OKFrontmatter.split(markdown)
        var html = ""
        if let frontmatter { html += frontmatterTable(frontmatter, in: markdown) }
        html += blocks(lines(body), depth: 0)
        return html
    }

    /// A self-contained page (inline CSS, light and dark, no external
    /// resource). With `previous`, a "O que muda" block with the line diff of
    /// the raw Markdown comes before the rendered document.
    public static func document(_ markdown: String, previous: String? = nil) -> String {
        var html = "<!doctype html>\n<html lang=\"pt-BR\"><head><meta charset=\"utf-8\">"
        html += "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'\">"
        html += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        html += "<style>\(css)</style></head><body>"
        if let previous { html += changes(OKLineDiff.diff(old: previous, new: markdown)) }
        html += "<article>\(body(markdown))</article></body></html>\n"
        return html
    }

    // MARK: - Diff block

    /// Unchanged runs longer than `collapseOver` keep `context` lines next to
    /// each change and show "…" in place of the rest.
    static let collapseOver = 6
    static let context = 2

    private static func changes(_ diff: [OKLineDiff.Line]) -> String {
        var html = "<section class=\"changes\"><h2 class=\"changes-title\">O que muda</h2>"
        guard diff.contains(where: { if case .same = $0 { return false } else { return true } }) else {
            return html + "<p class=\"diff-none\">Nenhuma diferença no texto.</p></section>"
        }
        html += "<div class=\"diff\">"
        var i = 0
        while i < diff.count {
            guard case .same = diff[i] else {
                html += diffLine(diff[i])
                i += 1
                continue
            }
            var end = i
            while end < diff.count, case .same = diff[end] { end += 1 }
            let run = diff[i..<end]
            if run.count <= collapseOver {
                html += run.map(diffLine).joined()
            } else {
                let head = i == 0 ? 0 : context
                let tail = end == diff.count ? 0 : context
                html += run.prefix(head).map(diffLine).joined()
                html += "<div class=\"diff-gap\">…</div>"
                html += run.suffix(tail).map(diffLine).joined()
            }
            i = end
        }
        return html + "</div></section>"
    }

    private static func diffLine(_ line: OKLineDiff.Line) -> String {
        switch line {
        case .same(let text): return "<div class=\"diff-same\">\(escape(text))</div>"
        case .added(let text): return "<div class=\"diff-added\">\(escape(text))</div>"
        case .removed(let text): return "<div class=\"diff-removed\">\(escape(text))</div>"
        }
    }

    // MARK: - Frontmatter

    /// One row per top-level key. The value is the unquoted scalar when
    /// `OKFrontmatter` reads one, otherwise the raw text with its indented
    /// lines (lists, maps), shown as written.
    private static func frontmatterTable(_ frontmatter: String, in markdown: String) -> String {
        var rows: [(key: String, raw: [String])] = []
        for line in frontmatter.components(separatedBy: "\n") {
            let topLevel = !line.hasPrefix(" ") && !line.hasPrefix("\t") && !line.hasPrefix("-") && !line.hasPrefix("#")
            if topLevel, let colon = line.firstIndex(of: ":") {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                rows.append((line[..<colon].trimmingCharacters(in: .whitespaces), value.isEmpty ? [] : [value]))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty || line.hasPrefix("#") {
                continue
            } else if rows.isEmpty {
                rows.append(("", [line]))
            } else {
                rows[rows.count - 1].raw.append(line)
            }
        }
        guard !rows.isEmpty else { return "" }
        var html = "<table class=\"frontmatter\"><tbody>"
        for row in rows {
            let value = OKFrontmatter.scalar(row.key, in: markdown) ?? row.raw.joined(separator: "\n")
            html += "<tr><th>\(escape(row.key))</th><td>\(escape(value))</td></tr>"
        }
        return html + "</tbody></table>"
    }

    // MARK: - Blocks

    /// Quotes nested deeper than this render their content as plain text.
    private static let maxDepth = 8

    private static func blocks(_ lines: [String], depth: Int) -> String {
        var html = ""
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) {
                i += 1
            } else if let fence = fence(line) {
                var code: [String] = []
                i += 1
                while i < lines.count, !closes(lines[i], fence.marker) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1
                let lang = fence.info.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
                let open = lang.isEmpty ? "<code>" : "<code class=\"language-\(lang)\">"
                html += "<pre>\(open)\(escape(code.joined(separator: "\n")))</code></pre>"
            } else if let (level, text) = heading(line) {
                html += "<h\(level)>\(inline(text))</h\(level)>"
                i += 1
            } else if isRule(line) {
                html += "<hr>"
                i += 1
            } else if isTableStart(lines, i) {
                var rows: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[i])
                    i += 1
                }
                html += table(rows)
            } else if quoteContent(line) != nil {
                var inner: [String] = []
                while i < lines.count, let content = quoteContent(lines[i]) {
                    inner.append(content)
                    i += 1
                }
                html += quote(inner, depth: depth)
            } else if listItem(line) != nil {
                let (list, next) = listBlock(lines, from: i)
                html += list
                i = next
            } else {
                var text: [String] = [line]
                i += 1
                while i < lines.count, !isBlank(lines[i]), !startsBlock(lines, i) {
                    text.append(lines[i])
                    i += 1
                }
                html += "<p>\(text.map { inline($0.trimmingCharacters(in: .whitespaces)) }.joined(separator: "\n"))</p>"
            }
        }
        return html
    }

    private static func startsBlock(_ lines: [String], _ i: Int) -> Bool {
        let line = lines[i]
        return fence(line) != nil || heading(line) != nil || isRule(line) || isTableStart(lines, i)
            || quoteContent(line) != nil || listItem(line) != nil
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Up to three leading spaces, as Markdown allows before a block marker.
    private static func dropIndent(_ line: String) -> Substring? {
        let spaces = line.prefix { $0 == " " }.count
        return spaces <= 3 ? line.dropFirst(spaces) : nil
    }

    private static func fence(_ line: String) -> (marker: String, info: String)? {
        guard let rest = dropIndent(line), let first = rest.first, first == "`" || first == "~" else { return nil }
        let marker = rest.prefix { $0 == first }
        guard marker.count >= 3 else { return nil }
        let info = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        return (String(marker), String(info.prefix { !$0.isWhitespace }))
    }

    private static func closes(_ line: String, _ marker: String) -> Bool {
        guard let rest = dropIndent(line), let first = marker.first else { return false }
        let run = rest.prefix { $0 == first }
        return run.count >= marker.count && isBlank(String(rest.dropFirst(run.count)))
    }

    private static func heading(_ line: String) -> (Int, String)? {
        guard let rest = dropIndent(line) else { return nil }
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        let closing = text.reversed().prefix { $0 == "#" }.count
        if closing > 0, closing == text.count || text.dropLast(closing).last == " " {
            text = String(text.dropLast(closing)).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard let rest = dropIndent(line) else { return false }
        let marks = rest.filter { $0 != " " && $0 != "\t" }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    // MARK: - Tables

    private static func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        guard i + 1 < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") else { return false }
        let cells = cells(lines[i + 1])
        return !cells.isEmpty && cells.allSatisfy { cell in
            let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !core.isEmpty && core.allSatisfy { $0 == "-" }
        }
    }

    private static func table(_ rows: [String]) -> String {
        let header = cells(rows[0])
        var html = "<table><thead><tr>"
        html += header.map { "<th>\(inline($0))</th>" }.joined()
        html += "</tr></thead><tbody>"
        for row in rows.dropFirst(2) {
            var values = cells(row)
            if values.count < header.count { values += Array(repeating: "", count: header.count - values.count) }
            html += "<tr>" + values.prefix(header.count).map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
        }
        return html + "</tbody></table>"
    }

    /// The row's cells, split on `|` not preceded by `\`, outer pipes dropped.
    private static func cells(_ row: String) -> [String] {
        var line = row.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") { line.removeFirst() }
        if line.hasSuffix("|"), !line.hasSuffix("\\|") { line.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if ch == "|", !escaped {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
            escaped = ch == "\\" && !escaped
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: - Quotes and callouts

    /// The line without its `>` and the one space after it, or `nil` when it
    /// isn't a quote line.
    private static func quoteContent(_ line: String) -> String? {
        guard let rest = dropIndent(line), rest.first == ">" else { return nil }
        let after = rest.dropFirst()
        return String(after.first == " " ? after.dropFirst() : after)
    }

    /// `[!tipo] Título` on the first line makes a callout; the type becomes a
    /// class name with only `a-z`, `0-9` and `-`.
    private static func quote(_ inner: [String], depth: Int) -> String {
        let content: (([String]) -> String) = { lines in
            depth < maxDepth
                ? blocks(lines, depth: depth + 1)
                : "<p>\(lines.map { escape($0) }.joined(separator: "\n"))</p>"
        }
        if let first = inner.first, first.hasPrefix("[!"), let close = first.firstIndex(of: "]") {
            let rawType = first[first.index(first.startIndex, offsetBy: 2)..<close]
            let type = rawType.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            var title = first[first.index(after: close)...]
            if title.first == "+" || title.first == "-" { title = title.dropFirst() }
            let titleText = title.trimmingCharacters(in: .whitespaces)
            let kind = type.isEmpty ? "note" : type
            var html = "<div class=\"callout callout-\(kind)\">"
            html += "<div class=\"callout-title\">\(titleText.isEmpty ? escape(String(rawType)) : inline(titleText))</div>"
            return html + content(Array(inner.dropFirst())) + "</div>"
        }
        return "<blockquote>\(content(inner))</blockquote>"
    }

    // MARK: - Lists

    private struct ListItem {
        var indent: Int
        var ordered: Bool
        var number: Int
        var text: String
    }

    private struct Item {
        var text: String
        var children: [String] = []
        var childrenOrdered = false
        var childrenStart = 1
    }

    private static func listItem(_ line: String) -> ListItem? {
        var indent = 0
        for ch in line {
            if ch == " " { indent += 1 } else if ch == "\t" { indent += 4 } else { break }
        }
        let rest = line.drop { $0 == " " || $0 == "\t" }
        if let first = rest.first, "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " || after.first == "\t" else { return nil }
            return ListItem(indent: indent, ordered: false, number: 0, text: after.trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let mark = after.first, mark == "." || mark == ")" else { return nil }
        let text = after.dropFirst()
        guard text.first == " " || text.first == "\t" else { return nil }
        return ListItem(indent: indent, ordered: true, number: number, text: text.trimmingCharacters(in: .whitespaces))
    }

    /// Items indented two or more spaces past the first one nest under the
    /// previous item (one level; deeper ones join that level). An indented
    /// plain line continues the previous item. A blank line, a non-indented
    /// line or a top-level item of the other kind ends the list.
    private static func listBlock(_ lines: [String], from start: Int) -> (String, Int) {
        guard let first = listItem(lines[start]) else { return ("", start + 1) }
        var items: [Item] = []
        var i = start
        while i < lines.count, !isBlank(lines[i]) {
            let line = lines[i]
            if let item = listItem(line) {
                if item.indent >= first.indent + 2, !items.isEmpty {
                    if items[items.count - 1].children.isEmpty {
                        items[items.count - 1].childrenOrdered = item.ordered
                        items[items.count - 1].childrenStart = item.number
                    }
                    items[items.count - 1].children.append(item.text)
                } else if item.ordered == first.ordered {
                    items.append(Item(text: item.text))
                } else {
                    break
                }
            } else if line.hasPrefix("  ") || line.hasPrefix("\t"), !items.isEmpty {
                let text = line.trimmingCharacters(in: .whitespaces)
                if items[items.count - 1].children.isEmpty {
                    items[items.count - 1].text += " " + text
                } else {
                    items[items.count - 1].children[items[items.count - 1].children.count - 1] += " " + text
                }
            } else {
                break
            }
            i += 1
        }
        var html = listOpen(ordered: first.ordered, start: first.number)
        for item in items {
            html += "<li>\(itemText(item.text))"
            if !item.children.isEmpty {
                html += listOpen(ordered: item.childrenOrdered, start: item.childrenStart)
                html += item.children.map { "<li>\(itemText($0))</li>" }.joined()
                html += item.childrenOrdered ? "</ol>" : "</ul>"
            }
            html += "</li>"
        }
        html += first.ordered ? "</ol>" : "</ul>"
        return (html, i)
    }

    private static func listOpen(ordered: Bool, start: Int) -> String {
        guard ordered else { return "<ul>" }
        return start == 1 ? "<ol>" : "<ol start=\"\(start)\">"
    }

    /// `[ ]` / `[x]` at the start become ☐ / ☑.
    private static func itemText(_ text: String) -> String {
        for (mark, box) in [("[ ]", "☐"), ("[x]", "☑"), ("[X]", "☑")] where text.hasPrefix(mark) {
            let rest = text.dropFirst(mark.count)
            if rest.isEmpty { return box }
            if rest.first == " " { return "\(box) \(inline(rest.trimmingCharacters(in: .whitespaces)))" }
        }
        return inline(text)
    }

    // MARK: - Inline

    /// Code spans, links, `**bold**`, `*italic*` / `_italic_` and `\` escapes.
    /// A delimiter with no closer stays as escaped text.
    static func inline(_ text: String) -> String {
        var parser = InlineParser(Array(text))
        return parser.render(0, parser.chars.count, linksAllowed: true)
    }

    private struct InlineParser {
        let chars: [Character]
        /// Delimiters known to have no closer from some index on: searching
        /// again from a later index can't find one either.
        private var noCloserAfter: [String: Int] = [:]

        init(_ chars: [Character]) { self.chars = chars }

        mutating func render(_ start: Int, _ end: Int, linksAllowed: Bool) -> String {
            var out = ""
            var i = start
            while i < end {
                let c = chars[i]
                if c == "\\", i + 1 < end, chars[i + 1].isASCII, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                    out += OKMarkdownHTML.escape(String(chars[i + 1]))
                    i += 2
                } else if c == "`" {
                    let run = count("`", from: i, end: end)
                    let delimiter = String(repeating: "`", count: run)
                    if let close = find(delimiter, from: i + run, end: end, exact: true) {
                        var code = String(chars[(i + run)..<close])
                        if code.count >= 2, code.hasPrefix(" "), code.hasSuffix(" "), code.contains(where: { $0 != " " }) {
                            code = String(code.dropFirst().dropLast())
                        }
                        out += "<code>\(OKMarkdownHTML.escape(code))</code>"
                        i = close + run
                    } else {
                        out += OKMarkdownHTML.escape(delimiter)
                        i += run
                    }
                } else if c == "[", linksAllowed, let link = link(at: i, end: end) {
                    let label = render(i + 1, link.labelEnd, linksAllowed: false)
                    if let href = OKMarkdownHTML.safeHref(link.url) {
                        out += "<a href=\"\(OKMarkdownHTML.escape(href))\">\(label)</a>"
                    } else {
                        out += OKMarkdownHTML.escape(String(chars[i..<link.end]))
                    }
                    i = link.end
                } else if (c == "*" || c == "_"), let (inner, close, width) = emphasis(at: i, end: end) {
                    let tag = width == 2 ? "strong" : "em"
                    out += "<\(tag)>\(render(inner, close, linksAllowed: linksAllowed))</\(tag)>"
                    i = close + width
                } else {
                    out += OKMarkdownHTML.escape(String(c))
                    i += 1
                }
            }
            return out
        }

        private func count(_ c: Character, from i: Int, end: Int) -> Int {
            var j = i
            while j < end, chars[j] == c { j += 1 }
            return j - i
        }

        /// First index of `delimiter` in `from..<end`; `exact` rejects a match
        /// that is part of a longer run of the same character.
        private mutating func find(_ delimiter: String, from: Int, end: Int, exact: Bool = false) -> Int? {
            if let none = noCloserAfter[delimiter], from >= none, end == chars.count { return nil }
            let d = Array(delimiter)
            var j = from
            while j + d.count <= end {
                if Array(chars[j..<(j + d.count)]) == d {
                    if !exact { return j }
                    let run = count(d[0], from: j, end: end)
                    if run == d.count { return j }
                    j += run
                } else {
                    j += 1
                }
            }
            if end == chars.count { noCloserAfter[delimiter] = min(noCloserAfter[delimiter] ?? from, from) }
            return nil
        }

        /// `[label](url)` or `[label](url "title")`; the URL may hold balanced
        /// parentheses.
        private mutating func link(at i: Int, end: Int) -> (labelEnd: Int, url: String, end: Int)? {
            guard let labelEnd = find("]", from: i + 1, end: end), labelEnd + 1 < end, chars[labelEnd + 1] == "(" else {
                return nil
            }
            var depth = 0
            var j = labelEnd + 2
            while j < end {
                if chars[j] == "(" { depth += 1 }
                if chars[j] == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                j += 1
            }
            guard j < end else { return nil }
            var target = String(chars[(labelEnd + 2)..<j]).trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("<"), let close = target.firstIndex(of: ">") {
                target = String(target[target.index(after: target.startIndex)..<close])
            } else if let space = target.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                target = String(target[..<space])
            }
            return (labelEnd, target, j + 1)
        }

        /// `**x**`/`__x__` (width 2) or `*x*`/`_x_` (width 1). The opener must
        /// be followed by a non-space and the closer preceded by one; `_` also
        /// needs a non-alphanumeric outside (no `snake_case` italics).
        private mutating func emphasis(at i: Int, end: Int) -> (Int, Int, Int)? {
            let c = chars[i]
            if c == "_", i > 0, chars[i - 1].isLetter || chars[i - 1].isNumber { return nil }
            let width = i + 1 < end && chars[i + 1] == c ? 2 : 1
            let inner = i + width
            guard inner < end, !chars[inner].isWhitespace, chars[inner] != c else { return nil }
            guard let close = find(String(repeating: String(c), count: width), from: inner, end: end) else { return nil }
            guard !chars[close - 1].isWhitespace else { return nil }
            if c == "_", close + width < end, chars[close + width].isLetter || chars[close + width].isNumber { return nil }
            return (inner, close, width)
        }
    }

    // MARK: - Helpers

    /// `http(s)://…` or a relative path (no scheme, not `//host`); anything
    /// else (`javascript:`, `data:`, `file:`…) → `nil`.
    static func safeHref(_ url: String) -> String? {
        guard !url.isEmpty,
              !url.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0 == "\\" || $0 == " " })
        else { return nil }
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return url }
        if url.hasPrefix("//") { return nil }
        let head = url.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        return head.contains(":") ? nil : url
    }

    /// Escapes `& < > " '` scalar by scalar: a metacharacter glued to a
    /// combining mark (`"` + U+0301) or after a prepend character is one
    /// `Character`, and comparing graphemes would let it through raw.
    static func escape(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"": out.append(contentsOf: "&quot;".unicodeScalars)
            case "'": out.append(contentsOf: "&#39;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }

    /// Lines of `text`; a trailing newline doesn't make an extra empty line.
    static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    private static let css = """
    :root{color-scheme:light dark;--fg:#1d1d1f;--muted:#6e6e73;--bg:#ffffff;--soft:#f2f2f5;--line:#d8d8de;\
    --add:#e3f6e6;--add-fg:#14692b;--del:#fde8e8;--del-fg:#a0201b;--accent:#2f6fde}
    @media (prefers-color-scheme: dark){:root{--fg:#ececf0;--muted:#9a9aa2;--bg:#1e1e20;--soft:#2a2a2e;--line:#3d3d43;\
    --add:#183823;--add-fg:#8fe0a4;--del:#43201f;--del-fg:#f3a19c;--accent:#7aa7ff}}
    body{margin:0;padding:16px 20px;background:var(--bg);color:var(--fg);\
    font:14px/1.55 -apple-system,BlinkMacSystemFont,"Helvetica Neue",sans-serif;word-wrap:break-word}
    h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.2em 0 .5em}
    h1{font-size:1.6em}h2{font-size:1.35em}h3{font-size:1.15em}h4,h5,h6{font-size:1em}
    p{margin:.6em 0;white-space:pre-wrap}
    a{color:var(--accent)}
    code{font:12.5px/1.45 ui-monospace,Menlo,monospace;background:var(--soft);padding:1px 4px;border-radius:4px}
    pre{background:var(--soft);padding:10px 12px;border-radius:6px;overflow-x:auto}
    pre code{background:none;padding:0}
    table{border-collapse:collapse;margin:.8em 0;width:auto;max-width:100%}
    th,td{border:1px solid var(--line);padding:4px 8px;text-align:left;vertical-align:top}
    th{background:var(--soft)}
    table.frontmatter{font-size:12.5px;color:var(--muted)}
    table.frontmatter td{white-space:pre-wrap}
    blockquote{margin:.8em 0;padding:2px 12px;border-left:3px solid var(--line);color:var(--muted)}
    .callout{margin:.8em 0;padding:8px 12px;border-left:4px solid var(--accent);background:var(--soft);border-radius:4px}
    .callout-title{font-weight:600}
    .callout-warning,.callout-caution,.callout-attention{border-left-color:#d08a00}
    .callout-danger,.callout-error,.callout-bug{border-left-color:#d23b33}
    .callout-success,.callout-check,.callout-done,.callout-tip{border-left-color:#2e9e4f}
    ul,ol{padding-left:1.6em}
    hr{border:0;border-top:1px solid var(--line);margin:1.2em 0}
    .changes{margin-bottom:20px;padding-bottom:12px;border-bottom:2px solid var(--line)}
    .changes-title{margin-top:0}
    .diff{font:12.5px/1.45 ui-monospace,Menlo,monospace;border:1px solid var(--line);border-radius:6px;overflow:hidden}
    .diff div{white-space:pre-wrap;padding:0 8px;min-height:1.45em}
    .diff-added{background:var(--add);color:var(--add-fg)}
    .diff-added::before{content:"+ "}
    .diff-removed{background:var(--del);color:var(--del-fg);text-decoration:line-through}
    .diff-removed::before{content:"- "}
    .diff-same::before{content:"  "}
    .diff-gap{color:var(--muted);text-align:center}
    .diff-none{color:var(--muted)}
    """
}

/// Line diff of raw Markdown for the "O que muda" block.
public enum OKLineDiff {
    public enum Line: Equatable, Sendable {
        case same(String), added(String), removed(String)
    }

    /// Each change lists its removed lines before the added ones.
    public static func diff(old: String, new: String) -> [Line] {
        let oldLines = OKMarkdownHTML.lines(old)
        let newLines = OKMarkdownHTML.lines(new)
        var removed: Set<Int> = []
        var inserted: Set<Int> = []
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var out: [Line] = []
        var i = 0
        var j = 0
        while i < oldLines.count || j < newLines.count {
            if i < oldLines.count, removed.contains(i) {
                out.append(.removed(oldLines[i]))
                i += 1
            } else if j < newLines.count, inserted.contains(j) {
                out.append(.added(newLines[j]))
                j += 1
            } else if i < oldLines.count, j < newLines.count {
                out.append(.same(newLines[j]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return out
    }
}
