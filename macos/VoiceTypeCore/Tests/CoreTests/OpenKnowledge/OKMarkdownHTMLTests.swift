import Foundation
import Testing
@testable import Core

@Suite("OKMarkdownHTML")
struct OKMarkdownHTMLTests {

    @Test func escapesHTMLAndDropsUnsafeLinks() {
        let html = OKMarkdownHTML.body("<script>alert(1)</script> [x](javascript:alert(1)) [y](../decisoes/y.md)")
        #expect(!html.contains("<script") && html.contains("&lt;script&gt;"))
        #expect(!html.contains("javascript:") || !html.contains("href=\"javascript"))
        #expect(html.contains("href=\"../decisoes/y.md\""))
    }

    @Test func escapesQuotesAndRefusesOtherSchemes() {
        let html = OKMarkdownHTML.body("Tom & \"Jerry\" 'x' [a](https://ex.com/?a=1&b=\"2\") [b](data:text/html,x) [c](file:///etc/passwd) [d](//evil.com) [e](JavaScript:x)")
        #expect(html.contains("Tom &amp; &quot;Jerry&quot; &#39;x&#39;"))
        #expect(html.contains("href=\"https://ex.com/?a=1&amp;b=&quot;2&quot;\""))
        #expect(!html.contains("href=\"data:") && !html.contains("href=\"file:"))
        #expect(!html.contains("href=\"//evil") && !html.lowercased().contains("href=\"javascript"))
    }

    @Test func rendersTableCalloutTasksAndHeadings() {
        let html = OKMarkdownHTML.body("## Fontes\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n> [!info] Status: **aceita**\n> Linha\n\n- [ ] fazer\n- [x] feito\n")
        #expect(html.contains("<h2>Fontes</h2>") && html.contains("<table>") && html.contains("<td>2</td>"))
        #expect(html.contains("callout-info") && html.contains("<strong>aceita</strong>"))
        #expect(html.contains("☐ fazer") && html.contains("☑ feito"))
    }

    @Test func frontmatterBecomesKeyValueTable() {
        let html = OKMarkdownHTML.body("---\ntitle: X\ntags:\n  - a\n---\n# H")
        #expect(html.contains("<th>title</th><td>X</td>"))
        #expect(html.contains("<th>tags</th>") && html.contains("- a"))
        #expect(html.contains("<h1>H</h1>"))
        #expect(!html.contains("<hr"))
    }

    @Test func hostileFrontmatterIsEscaped() {
        let html = OKMarkdownHTML.body("---\ntitle: \"<img src=x onerror=alert(1)>\"\n---\n")
        #expect(!html.contains("<img") && html.contains("&lt;img"))
    }

    @Test func listsNestOneLevelAndOrderedListsRender() {
        let html = OKMarkdownHTML.body("- a\n  - a1\n* b\n\n1. um\n2. dois\n")
        #expect(html.contains("<ul><li>a<ul><li>a1</li></ul></li><li>b</li></ul>"))
        #expect(html.contains("<ol><li>um</li><li>dois</li></ol>"))
    }

    @Test func codeFencesKeepContentLiteral() {
        let html = OKMarkdownHTML.body("```mermaid\ngraph TD; A-->B **x**\n```\n\nTexto `<b>` e *it* e _it2_\n")
        #expect(html.contains("<pre><code class=\"language-mermaid\">graph TD; A--&gt;B **x**</code></pre>"))
        #expect(html.contains("<code>&lt;b&gt;</code>") && html.contains("<em>it</em>") && html.contains("<em>it2</em>"))
    }

    @Test func blockquoteWithoutCalloutAndParagraphs() {
        let html = OKMarkdownHTML.body("> citação\n\nlinha um\nlinha dois\n\n### T\n")
        #expect(html.contains("<blockquote>") && html.contains("citação"))
        #expect(html.contains("<p>linha um\nlinha dois</p>") && html.contains("<h3>T</h3>"))
    }

    @Test func calloutTypeIsSanitizedIntoClassName() {
        let html = OKMarkdownHTML.body("> [!warn\" onclick=\"x] Título\n")
        #expect(!html.contains("onclick=\""))
        #expect(html.contains("class=\"callout callout-"))
    }

    @Test func documentIsSelfContainedWithDarkMode() {
        let doc = OKMarkdownHTML.document("# H\n")
        #expect(doc.hasPrefix("<!doctype html>") && doc.contains("prefers-color-scheme: dark"))
        #expect(!doc.contains("<script") && !doc.contains("http://") && !doc.contains("https://"))
        #expect(!doc.contains("O que muda"))
    }

    @Test func documentWithPreviousShowsChangesFirst() {
        let old = "# Doc\n\nlinha velha\n"
        let new = "# Doc\n\nlinha nova\n"
        let doc = OKMarkdownHTML.document(new, previous: old)
        let changes = doc.range(of: "O que muda")
        let heading = doc.range(of: "<h1>Doc</h1>")
        #expect(changes != nil && heading != nil)
        if let changes, let heading { #expect(changes.lowerBound < heading.lowerBound) }
        #expect(doc.contains("class=\"diff-added\">linha nova") && doc.contains("class=\"diff-removed\">linha velha"))
    }

    @Test func diffCollapsesLongUnchangedRuns() {
        let common = (1...20).map { "l\($0)" }
        let old = (common + ["fim"]).joined(separator: "\n")
        let new = (common + ["FIM"]).joined(separator: "\n")
        let doc = OKMarkdownHTML.document(new, previous: old)
        let block = String(doc[..<(doc.range(of: "</section>")?.lowerBound ?? doc.endIndex)])
        #expect(block.contains("…"))
        #expect(!block.contains(">l1<") && block.contains(">l19<") && block.contains(">l20<"))
    }

    // MARK: - Metacharacters glued to combining / prepend characters
    //
    // `"` + U+0301 (combining acute) and U+0600 (prepend) + `"` are single
    // grapheme clusters, so a `Character` comparison never sees the `"`. These
    // checks look at Unicode scalars, which is what the HTML parser reads.

    /// Metacharacters glued to a neighbor that joins their grapheme cluster.
    static let glued: [String] = ["&", "<", ">", "\"", "'"].flatMap { ["\($0)\u{301}", "\u{600}\($0)", "\u{600}\($0)\u{301}"] }

    @Test func escapeWorksPerScalarNotPerGrapheme() {
        let input = "\u{600}\"x\"\u{301}<\u{301}&\u{301}'\u{301}>\u{20DD}"
        let expected = "\u{600}&quot;x&quot;\u{301}&lt;\u{301}&amp;\u{301}&#39;\u{301}&gt;\u{20DD}"
        #expect(Array(OKMarkdownHTML.escape(input).unicodeScalars) == Array(expected.unicodeScalars))
    }

    @Test func combiningQuoteCannotBreakOutOfHref() {
        let md = "[x](<https://e.test/\"\u{301}/style=\"\u{301};position:fixed;inset:0;background:white;z-index:9999\"\u{301}>)"
        let html = OKMarkdownHTML.body(md)
        let tags = Self.tags(html)
        #expect(tags.count == 4)  // <p>, <a href="…">, </a>, </p>
        let anchors = tags.filter { $0.hasPrefix("<a") }
        #expect(anchors.count == 1)
        for anchor in anchors {
            // Only `href` is an attribute: "style=" survives as escaped URL text.
            #expect(anchor.unicodeScalars.filter { $0 == "\"" }.count == 2)
            #expect(anchor.unicodeScalars.starts(with: "<a href=\"".unicodeScalars))
            #expect(Array(anchor.unicodeScalars.suffix(2)) == Array("\">".unicodeScalars))
            #expect(Self.scalarContains(anchor, "&quot;\u{301}/style=&quot;\u{301};position:fixed"))
        }
    }

    @Test func gluedMetacharactersNeverReachTheMarkup() {
        for meta in Self.glued {
            let samples = [
                "texto \(meta)b\(meta)",
                "# título \(meta)",
                "- item \(meta)\n- [x] \(meta)",
                "| A\(meta) | B |\n| --- | --- |\n| \(meta) | 2 |",
                "> [!info\(meta)] Título \(meta)\n> corpo \(meta)",
                "```js\(meta)\ncódigo \(meta)\n```",
                "`code \(meta)` **n\(meta)** *i\(meta)* [r\(meta)](../a\(meta).md) [h](https://e.test/\(meta))",
                "---\ntitle: \"\(meta)\"\nk\(meta): v\(meta)\n---\n",
            ]
            for md in samples {
                let page = OKMarkdownHTML.document(md, previous: md + "\n\(meta)")
                let pageBody = page.components(separatedBy: "<body>").dropFirst().joined(separator: "<body>")
                for html in [OKMarkdownHTML.body(md), pageBody] {
                    #expect(Self.onlyKnownMarkup(html), "\(Array(md.unicodeScalars))")
                }
            }
        }
    }

    // MARK: - Scalar helpers

    /// Every `<…>` in `html`, read scalar by scalar.
    static func tags(_ html: String) -> [String] {
        var tags: [String] = []
        var current: String.UnicodeScalarView?
        for scalar in html.unicodeScalars {
            if scalar == "<" { current = String.UnicodeScalarView() }
            current?.append(scalar)
            if scalar == ">", let tag = current {
                tags.append(String(tag))
                current = nil
            }
        }
        return tags
    }

    static func scalarContains(_ haystack: String, _ needle: String) -> Bool {
        let h = Array(haystack.unicodeScalars), n = Array(needle.unicodeScalars)
        guard n.count <= h.count else { return false }
        return (0...(h.count - n.count)).contains { Array(h[$0..<($0 + n.count)]) == n }
    }

    /// Outside tags, every `&` starts one of the five entities and no raw
    /// `<`, `>`, `"` or `'` appears; inside tags, every scalar is ASCII
    /// (element names, fixed attributes, escaped values) and quotes pair up.
    static func onlyKnownMarkup(_ html: String) -> Bool {
        let scalars = Array(html.unicodeScalars)
        var inTag = false
        var quotes = 0
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if inTag {
                if s == "\"" { quotes += 1 }
                if s == ">", quotes % 2 == 0 { inTag = false }
                // Escaped href values may hold non-ASCII text, never a raw quote.
                if s == "'" || s == "<" { return false }
            } else if s == "<" {
                inTag = true
                quotes = 0
            } else if s == ">" || s == "\"" || s == "'" {
                return false
            } else if s == "&" {
                let rest = String(String.UnicodeScalarView(scalars[i..<min(i + 6, scalars.count)]))
                guard ["&amp;", "&lt;", "&gt;", "&quot;", "&#39;"].contains(where: { rest.unicodeScalars.starts(with: $0.unicodeScalars) })
                else { return false }
            }
            i += 1
        }
        return !inTag
    }
}

@Suite("OKLineDiff")
struct OKLineDiffTests {

    @Test func lineDiffMarksAddedAndRemoved() {
        #expect(OKLineDiff.diff(old: "a\nb\nc", new: "a\nB\nc") == [.same("a"), .removed("b"), .added("B"), .same("c")])
    }

    @Test func emptyAndIdentical() {
        #expect(OKLineDiff.diff(old: "", new: "x") == [.added("x")])
        #expect(OKLineDiff.diff(old: "a\n", new: "a") == [.same("a")])
        #expect(OKLineDiff.diff(old: "a\nb", new: "a\nb") == [.same("a"), .same("b")])
        #expect(OKLineDiff.diff(old: "a", new: "a\nb\nc") == [.same("a"), .added("b"), .added("c")])
    }
}
