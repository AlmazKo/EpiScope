import AppKit

// Tiny Markdown → NSAttributedString renderer. Only does font work
// (size + bold / italic / monospaced), no background colours or
// separators. Supported features:
//
//   #..###### headers           → larger + bold body font
//   ```fenced code blocks```    → monospaced, preserved newlines
//   `inline code`               → monospaced
//   **bold** / __bold__         → bold
//   *italic* / _italic_         → italic
//   - / * / + list items        → "• " prefix, body inline-parsed
//   > blockquote                → italic body
//   [text](url)                 → link colour + underline
//
// Tables, nested lists, images, raw HTML, footnotes, task lists,
// strikethrough, autolinks are deliberately out of scope.
enum MarkdownRenderer {

    // codeBackground tints `inline code` and fenced blocks. Off by default —
    // a caller that renders dense text (the transcript) doesn't want the
    // speckling; the Reports pane does, and pairs it with a layout manager
    // that draws the fill as a padded chip.
    static func render(
        _ source: String,
        baseFont: NSFont,
        color: NSColor = .labelColor,
        paragraphStyle: NSParagraphStyle? = nil,
        codeBackground: NSColor? = nil
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                // Greedy: collect until matching closing fence (or EOF).
                var j = i + 1
                var buf: [String] = []
                while j < lines.count,
                      !lines[j].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    buf.append(lines[j])
                    j += 1
                }
                let body = buf.joined(separator: "\n")
                out.append(plain(body + "\n", font: monoFont(of: baseFont),
                                 color: color, paragraph: paragraphStyle,
                                 background: codeBackground))
                i = j + 1
                continue
            }
            // Markdown table — needs a header row + separator row +
            // (optional) body rows. If the separator doesn't validate,
            // fall through to plain-line rendering.
            if i + 1 < lines.count,
               isTableRow(line),
               isTableSeparator(lines[i + 1]) {
                let header = parseRow(line)
                let alignments = parseAlignments(lines[i + 1])
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, isTableRow(lines[j]) {
                    rows.append(parseRow(lines[j]))
                    j += 1
                }
                out.append(renderTable(
                    header: header,
                    alignments: alignments,
                    rows: rows,
                    baseFont: baseFont,
                    color: color,
                    paragraph: paragraphStyle
                ))
                i = j
                continue
            }
            out.append(renderBlock(line, baseFont: baseFont, color: color,
                                   paragraph: paragraphStyle,
                                   codeBackground: codeBackground))
            // Preserve the source's line break.
            if i < lines.count - 1 {
                out.append(plain("\n", font: baseFont, color: color, paragraph: paragraphStyle))
            }
            i += 1
        }
        return out
    }

    // MARK: - Tables

    private enum CellAlignment { case left, right, center }

    private static func isTableRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.dropFirst().contains("|")
    }

    // A separator like `|---|:--:|--:|` — each cell is some `-` with
    // optional `:` on either end. Rejects rows that look table-like
    // but don't satisfy the dash rule.
    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = parseRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let body = cell
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    private static func parseRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t = String(t.dropFirst()) }
        if t.hasSuffix("|") { t = String(t.dropLast()) }
        return t.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseAlignments(_ separatorLine: String) -> [CellAlignment] {
        parseRow(separatorLine).map { cell -> CellAlignment in
            let t = cell.trimmingCharacters(in: .whitespaces)
            let left = t.hasPrefix(":")
            let right = t.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            return .left
        }
    }

    private static func renderTable(
        header: [String],
        alignments: [CellAlignment],
        rows: [[String]],
        baseFont: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle?
    ) -> NSAttributedString {
        let mono = monoFont(of: baseFont)
        // Use the secondary label as the border tint so it reads as
        // structural chrome, not content. Renders cleanly against
        // both light and dark backgrounds.
        let borderColor = NSColor.secondaryLabelColor

        let colCount = max(header.count, alignments.count,
                           rows.map { $0.count }.max() ?? 0)
        guard colCount > 0 else { return NSAttributedString() }

        // Pad short rows to colCount with empty cells so the column
        // grid stays rectangular.
        func pad(_ cells: [String]) -> [String] {
            var out = cells
            while out.count < colCount { out.append("") }
            return Array(out.prefix(colCount))
        }
        let paddedHeader = pad(header)
        let paddedRows = rows.map(pad)
        let allRows = [paddedHeader] + paddedRows

        // Column widths in glyph units. We measure character count —
        // works because the body uses a monospaced font, where every
        // glyph occupies the same advance width.
        var widths = [Int](repeating: 1, count: colCount)
        for row in allRows {
            for (idx, cell) in row.enumerated() {
                widths[idx] = max(widths[idx], cell.count)
            }
        }

        func textAttrs() -> [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: mono, .foregroundColor: color,
            ]
            if let p = paragraph { attrs[.paragraphStyle] = p }
            return attrs
        }
        func borderAttrs() -> [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: mono, .foregroundColor: borderColor,
            ]
            if let p = paragraph { attrs[.paragraphStyle] = p }
            return attrs
        }

        let out = NSMutableAttributedString()

        func padCell(_ value: String, width: Int, align: CellAlignment) -> String {
            let extra = max(0, width - value.count)
            switch align {
            case .left:
                return " " + value + String(repeating: " ", count: extra) + " "
            case .right:
                return " " + String(repeating: " ", count: extra) + value + " "
            case .center:
                let l = extra / 2
                let r = extra - l
                return " " + String(repeating: " ", count: l) + value
                     + String(repeating: " ", count: r) + " "
            }
        }
        func alignment(at col: Int) -> CellAlignment {
            col < alignments.count ? alignments[col] : .left
        }

        // Unicode light box-drawing characters — every glyph below is
        // one cell wide in a monospaced font, so the columns stay
        // aligned with the padded cell strings above.
        let hChar = "─"  // U+2500 horizontal
        let vChar = "│"  // U+2502 vertical
        let topLeft  = "┌", topJoin  = "┬", topRight  = "┐"  // U+250C/U+252C/U+2510
        let midLeft  = "├", midCross = "┼", midRight  = "┤"  // U+251C/U+253C/U+2524
        let botLeft  = "└", botJoin  = "┴", botRight  = "┘"  // U+2514/U+2534/U+2518

        func borderRow(left: String, join: String, right: String) -> String {
            var s = left
            for (i, w) in widths.enumerated() {
                // +2 accounts for the single-space padding on either
                // side of every cell value.
                s += String(repeating: hChar, count: w + 2)
                s += (i == widths.count - 1) ? right : join
            }
            return s + "\n"
        }

        func appendRow(_ cells: [String]) {
            out.append(NSAttributedString(string: vChar, attributes: borderAttrs()))
            for (idx, cell) in cells.enumerated() {
                out.append(NSAttributedString(
                    string: padCell(cell, width: widths[idx], align: alignment(at: idx)),
                    attributes: textAttrs()
                ))
                out.append(NSAttributedString(string: vChar, attributes: borderAttrs()))
            }
            out.append(NSAttributedString(string: "\n", attributes: textAttrs()))
        }

        // Top border, header, header/body separator, body rows, bottom border.
        out.append(NSAttributedString(
            string: borderRow(left: topLeft, join: topJoin, right: topRight),
            attributes: borderAttrs()
        ))
        appendRow(paddedHeader)
        out.append(NSAttributedString(
            string: borderRow(left: midLeft, join: midCross, right: midRight),
            attributes: borderAttrs()
        ))
        for row in paddedRows { appendRow(row) }
        out.append(NSAttributedString(
            string: borderRow(left: botLeft, join: botJoin, right: botRight),
            attributes: borderAttrs()
        ))
        return out
    }

    private static func renderBlock(
        _ raw: String,
        baseFont: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle?,
        codeBackground: NSColor?
    ) -> NSAttributedString {
        let line = raw

        // Header: 1–6 `#` followed by a space.
        let hashes = line.prefix(while: { $0 == "#" }).count
        if hashes >= 1, hashes <= 6,
           line.dropFirst(hashes).first == " " {
            let text = String(line.dropFirst(hashes + 1))
                .trimmingCharacters(in: .whitespaces)
            // h1 +5pt, h2 +3pt, h3 +2pt, h4..h6 +1pt above body.
            let bump: CGFloat
            switch hashes {
            case 1: bump = 5
            case 2: bump = 3
            case 3: bump = 2
            default: bump = 1
            }
            let font = NSFont.systemFont(
                ofSize: baseFont.pointSize + bump,
                weight: .bold
            )
            // A header needs air above it to read as a section break — TextKit
            // takes paragraph-level metrics from the paragraph's first
            // character, which is this line.
            let headerPara = mutable(paragraph)
            headerPara.paragraphSpacingBefore =
                max(headerPara.paragraphSpacingBefore, font.pointSize * 0.9)
            return renderInline(text, baseFont: font, color: color,
                                paragraph: headerPara, codeBackground: codeBackground)
        }

        // List item: leading whitespace + (-|*|+) + space. The source indent
        // decides the nesting level — marker and left inset step with it.
        if let listMatch = line.firstMatch(pattern: #"^\s*([-*+])\s+"#) {
            let level = nestingLevel(of: line)
            return listItem(marker: bullets[min(level, bullets.count - 1)],
                            markerFont: bulletFont(of: baseFont),
                            body: String(line[listMatch.upperBound...]),
                            level: level, baseFont: baseFont,
                            color: color, paragraph: paragraph,
                            codeBackground: codeBackground)
        }
        // Ordered list: leading whitespace + digits + . + space.
        if let listMatch = line.firstMatch(pattern: #"^\s*\d+\.\s+"#) {
            let label = String(line[listMatch]).trimmingCharacters(in: .whitespaces)
            return listItem(marker: label, markerFont: baseFont,
                            body: String(line[listMatch.upperBound...]),
                            level: nestingLevel(of: line), baseFont: baseFont,
                            color: color, paragraph: paragraph,
                            codeBackground: codeBackground)
        }

        // Blockquote.
        if line.hasPrefix("> ") {
            return renderInline(String(line.dropFirst(2)),
                                baseFont: italicize(baseFont),
                                color: color, paragraph: paragraph,
                                codeBackground: codeBackground)
        }
        if line == ">" {
            return plain("", font: baseFont, color: color, paragraph: paragraph)
        }

        // Plain paragraph.
        return renderInline(line, baseFont: baseFont, color: color,
                            paragraph: paragraph, codeBackground: codeBackground)
    }

    private static func renderInline(
        _ text: String,
        baseFont: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle?,
        codeBackground: NSColor?
    ) -> NSAttributedString {
        let chars = Array(text)
        let out = NSMutableAttributedString()
        var buffer = ""
        var i = 0

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            out.append(plain(buffer, font: baseFont, color: color, paragraph: paragraph))
            buffer.removeAll()
        }

        while i < chars.count {
            let c = chars[i]
            // Inline code — first because it shouldn't itself be parsed.
            if c == "`",
               let end = nextIndex(of: "`", in: chars, from: i + 1) {
                flushBuffer()
                let inner = String(chars[(i + 1)..<end])
                out.append(plain(inner, font: monoFont(of: baseFont),
                                 color: color, paragraph: paragraph,
                                 background: codeBackground))
                i = end + 1
                continue
            }
            // Bold (** or __) — match the same marker as opener.
            if (c == "*" || c == "_"),
               i + 1 < chars.count, chars[i + 1] == c,
               let end = nextDouble(of: c, in: chars, from: i + 2) {
                flushBuffer()
                let inner = String(chars[(i + 2)..<end])
                out.append(renderInline(inner,
                                        baseFont: boldify(baseFont),
                                        color: color,
                                        paragraph: paragraph,
                                        codeBackground: codeBackground))
                i = end + 2
                continue
            }
            // Italic (* or _) — but skip if it would empty-match
            // (e.g. "* * *" horizontal rule).
            if (c == "*" || c == "_"),
               let end = nextIndex(of: c, in: chars, from: i + 1),
               end > i + 1 {
                flushBuffer()
                let inner = String(chars[(i + 1)..<end])
                out.append(renderInline(inner,
                                        baseFont: italicize(baseFont),
                                        color: color,
                                        paragraph: paragraph,
                                        codeBackground: codeBackground))
                i = end + 1
                continue
            }
            // Link [text](url).
            if c == "[",
               let closeBracket = nextIndex(of: "]", in: chars, from: i + 1),
               closeBracket + 1 < chars.count,
               chars[closeBracket + 1] == "(",
               let closeParen = nextIndex(of: ")", in: chars, from: closeBracket + 2) {
                flushBuffer()
                let label = String(chars[(i + 1)..<closeBracket])
                let url = String(chars[(closeBracket + 2)..<closeParen])
                // The label is markdown too — a `code` span inside a link has
                // to render as code, not as literal backticks painted in link
                // colour. Style the parsed label, don't re-flatten it.
                let text = NSMutableAttributedString(attributedString: renderInline(
                    label, baseFont: baseFont, color: .linkColor,
                    paragraph: paragraph, codeBackground: codeBackground))
                let whole = NSRange(location: 0, length: text.length)
                text.addAttribute(.underlineStyle,
                                  value: NSUnderlineStyle.single.rawValue, range: whole)
                if let real = URL(string: url) {
                    text.addAttribute(.link, value: real, range: whole)
                }
                out.append(text)
                i = closeParen + 1
                continue
            }
            buffer.append(c)
            i += 1
        }
        flushBuffer()
        return out
    }

    // MARK: - Lists

    // One marker per nesting level; deeper levels reuse the last one.
    private static let bullets = ["•", "◦", "▪"]

    // SF's "•" at body size is a speck — at 14pt it's barely 3pt across, so a
    // list reads as ragged text rather than a list. Drawing the marker a few
    // points up (and semibold) gives it the weight of a real bullet without
    // touching the body's size.
    private static func bulletFont(of base: NSFont) -> NSFont {
        NSFont.systemFont(ofSize: base.pointSize + 4, weight: .semibold)
    }

    // Leading whitespace → nesting level (2 spaces or 1 tab per level).
    private static func nestingLevel(of line: String) -> Int {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        return min(indent / 2, 4)
    }

    // A list line: marker + body, with the paragraph indented by its nesting
    // level and a hanging indent so wrapped lines line up under the item's
    // text, not under its marker. Indents are measured from the real rendered
    // marker width, so bullets and "10." land the same way.
    private static func listItem(
        marker: String,
        markerFont: NSFont,
        body: String,
        level: Int,
        baseFont: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle?,
        codeBackground: NSColor?
    ) -> NSAttributedString {
        let para = mutable(paragraph)
        para.firstLineHeadIndent += baseFont.pointSize * 1.3 * CGFloat(level)
        let text = marker + " "
        let width = (text as NSString).size(withAttributes: [.font: markerFont]).width
        para.headIndent = para.firstLineHeadIndent + width
        let out = NSMutableAttributedString()
        // The bigger marker would stretch the line box; pull it back onto the
        // body's metrics so leading stays even across the list.
        var attrs: [NSAttributedString.Key: Any] = [
            .font: markerFont, .foregroundColor: color, .paragraphStyle: para,
        ]
        if markerFont.pointSize > baseFont.pointSize {
            attrs[.baselineOffset] = -(markerFont.pointSize - baseFont.pointSize) / 4
        }
        out.append(NSAttributedString(string: text, attributes: attrs))
        out.append(renderInline(body, baseFont: baseFont, color: color,
                                paragraph: para, codeBackground: codeBackground))
        return out
    }

    // MARK: - helpers

    private static func plain(
        _ s: String,
        font: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle?,
        background: NSColor? = nil
    ) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        if let p = paragraph { attrs[.paragraphStyle] = p }
        if let background { attrs[.backgroundColor] = background }
        return NSAttributedString(string: s, attributes: attrs)
    }

    private static func mutable(_ style: NSParagraphStyle?) -> NSMutableParagraphStyle {
        (style?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
    }

    private static func boldify(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func italicize(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }

    private static func monoFont(of base: NSFont) -> NSFont {
        // SF Mono glyphs are visibly heavier than SF Pro at the same
        // point size, so step down 1pt to keep code / tables looking
        // the same weight as the surrounding prose.
        NSFont.monospacedSystemFont(
            ofSize: max(1, base.pointSize - 1),
            weight: .regular
        )
    }

    private static func nextIndex(of char: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == char { return i }
            i += 1
        }
        return nil
    }

    private static func nextDouble(of char: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == char, chars[i + 1] == char { return i }
            i += 1
        }
        return nil
    }
}

// Lightweight regex match helper — returns the matched String.Index
// range (or nil) without forcing the caller to deal with NSRange.
private extension String {
    func firstMatch(pattern: String) -> Range<String.Index>? {
        range(of: pattern, options: .regularExpression)
    }
}
