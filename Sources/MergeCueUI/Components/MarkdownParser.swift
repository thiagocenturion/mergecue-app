import Foundation

/// A block of Markdown (CommonMark / GitHub-flavoured subset used by PR descriptions and review comments).
nonisolated indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    /// Inline Markdown; newlines inside are kept as line breaks (how GitHub, GitLab and Bitbucket show comments).
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    case code(language: String, text: String)
    case table(header: [String], alignments: [MarkdownAlignment], rows: [[String]])
    case rule
    /// An HTML comment (`<!-- … -->`): hidden by the provider's renderer, shown here (muted) because review text
    /// is untrusted and hidden text is exactly where instructions aimed at agents are put.
    case hiddenComment(String)
}

nonisolated struct MarkdownListItem: Hashable, Sendable {
    /// nil = not a task item; true/false = `- [x]` / `- [ ]`.
    var checked: Bool?
    var blocks: [MarkdownBlock]
}

nonisolated enum MarkdownAlignment: Hashable, Sendable {
    case leading, center, trailing
}

/// Line-based block parser. Inline syntax (emphasis, code spans, links) is left to `AttributedString`'s Markdown
/// parser at render time. Never throws: anything it does not recognise is a paragraph.
nonisolated enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
        return parse(lines: normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init), depth: 0)
    }

    /// Nesting limit for quotes and lists (untrusted input must not recurse without bound).
    static let maxDepth = 8

    static func parse(lines: [String], depth: Int) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            if let fence = fenceMarker(trimmed) {
                index = parseFence(lines, from: index, fence: fence, into: &blocks)
                continue
            }
            if trimmed.hasPrefix("<!--") {
                index = parseHTMLComment(lines, from: index, into: &blocks)
                continue
            }
            if let heading = heading(trimmed) {
                blocks.append(heading)
                index += 1
                continue
            }
            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    var rest = current.dropFirst()
                    if rest.first == " " { rest = rest.dropFirst() }
                    quoted.append(String(rest))
                    index += 1
                }
                blocks.append(depth < maxDepth ? .quote(parse(lines: quoted, depth: depth + 1)) : .paragraph(quoted.joined(separator: "\n")))
                continue
            }
            if listMarker(line) != nil, depth < maxDepth {
                index = parseList(lines, from: index, depth: depth, into: &blocks)
                continue
            }
            if index + 1 < lines.count, line.contains("|"), let alignments = tableDelimiter(lines[index + 1]) {
                index = parseTable(lines, from: index, alignments: alignments, into: &blocks)
                continue
            }
            if line.hasPrefix("    "), depth == 0 || !blocks.isEmpty {
                var code: [String] = []
                while index < lines.count, lines[index].hasPrefix("    ") || lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    code.append(String(lines[index].dropFirst(min(4, lines[index].count))))
                    index += 1
                }
                while code.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { code.removeLast() }
                blocks.append(.code(language: "", text: code.joined(separator: "\n")))
                continue
            }
            // Paragraph: until a blank line or the start of another block.
            var paragraph: [String] = []
            while index < lines.count {
                let current = lines[index]
                let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                if currentTrimmed.isEmpty { break }
                if !paragraph.isEmpty, startsBlock(current, next: index + 1 < lines.count ? lines[index + 1] : nil) { break }
                paragraph.append(currentTrimmed)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }
        return blocks
    }

    // MARK: Block starts

    private static func startsBlock(_ line: String, next: String?) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if fenceMarker(trimmed) != nil || heading(trimmed) != nil || isRule(trimmed) { return true }
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("<!--") || listMarker(line) != nil { return true }
        if let next, line.contains("|"), tableDelimiter(next) != nil { return true }
        return false
    }

    /// "```" / "~~~" (3 or more).
    static func fenceMarker(_ trimmed: String) -> String? {
        for character in ["`", "~"] where trimmed.hasPrefix(String(repeating: character, count: 3)) {
            return String(trimmed.prefix { String($0) == character })
        }
        return nil
    }

    static func heading(_ trimmed: String) -> MarkdownBlock? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // Closing hashes ("## Title ##").
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ trimmed: String) -> Bool {
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// Bullet (`-`, `*`, `+`) or ordered (`1.` / `1)`) marker: indentation, content column, ordered, start number.
    static func listMarker(_ line: String) -> (indent: Int, content: Int, ordered: Bool, number: Int)? {
        let indent = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(indent)
        guard let first = rest.first else { return nil }
        if "-*+".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            // "* * *" is a rule, not a list.
            if isRule(String(rest)) { return nil }
            return (indent, indent + 2, false, 1)
        }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else { return nil }
        return (indent, indent + digits.count + 2, true, Int(digits) ?? 1)
    }

    /// GFM table delimiter row (`| --- | :-: |`): the column alignments.
    static func tableDelimiter(_ line: String) -> [MarkdownAlignment]? {
        let cells = tableCells(line)
        guard !cells.isEmpty, line.contains("-") else { return nil }
        var alignments: [MarkdownAlignment] = []
        for cell in cells {
            let spec = cell.trimmingCharacters(in: .whitespaces)
            let core = spec.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            switch (spec.hasPrefix(":"), spec.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// Cells of a table row (outer pipes optional; `\|` stays inside a cell).
    static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    // MARK: Block bodies

    private static func parseFence(_ lines: [String], from start: Int, fence: String, into blocks: inout [MarkdownBlock]) -> Int {
        let opening = lines[start].trimmingCharacters(in: .whitespaces)
        let language = opening.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) ?? ""
        let indent = lines[start].prefix { $0 == " " }.count
        var body: [String] = []
        var index = start + 1
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(fence), trimmed.allSatisfy({ String($0) == String(fence.first ?? "`") }) {
                index += 1
                break
            }
            // Drop the fence's own indentation from its lines.
            let line = lines[index]
            let removable = min(indent, line.prefix { $0 == " " }.count)
            body.append(String(line.dropFirst(removable)))
            index += 1
        }
        blocks.append(.code(language: language, text: body.joined(separator: "\n")))
        return index
    }

    private static func parseHTMLComment(_ lines: [String], from start: Int, into blocks: inout [MarkdownBlock]) -> Int {
        var collected: [String] = []
        var index = start
        while index < lines.count {
            collected.append(lines[index])
            index += 1
            if lines[index - 1].contains("-->") { break }
        }
        var text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // Text after the comment on its closing line is ordinary content.
        var trailing = ""
        if let close = text.range(of: "-->") {
            trailing = String(text[close.upperBound...]).trimmingCharacters(in: .whitespaces)
            text = String(text[..<close.lowerBound])
        }
        if text.hasPrefix("<!--") { text = String(text.dropFirst(4)) }
        let inner = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !inner.isEmpty { blocks.append(.hiddenComment(inner)) }
        if !trailing.isEmpty { blocks.append(.paragraph(trailing)) }
        return index
    }

    private static func parseList(_ lines: [String], from start: Int, depth: Int, into blocks: inout [MarkdownBlock]) -> Int {
        guard let first = listMarker(lines[start]) else { return start + 1 }
        var items: [MarkdownListItem] = []
        var index = start
        while index < lines.count, let marker = listMarker(lines[index]), marker.ordered == first.ordered,
              marker.indent < first.content {
            var body = [String(lines[index].dropFirst(marker.content))]
            index += 1
            // Continuation: indented lines (nested lists, wrapped text) and blank lines followed by indented ones.
            while index < lines.count {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let indent = line.prefix { $0 == " " }.count
                if trimmed.isEmpty {
                    let next = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    guard let next, next.prefix(while: { $0 == " " }).count >= marker.content else { break }
                    body.append("")
                    index += 1
                    continue
                }
                if indent >= marker.content {
                    body.append(String(line.dropFirst(marker.content)))
                    index += 1
                    continue
                }
                // Lazy continuation of the item's text (not a new block).
                if listMarker(line) == nil, !startsBlock(line, next: nil), !(body.last?.isEmpty ?? true) {
                    body.append(trimmed)
                    index += 1
                    continue
                }
                break
            }
            var checked: Bool?
            if let head = body.first {
                let lowered = head.lowercased()
                if lowered.hasPrefix("[ ] ") || lowered == "[ ]" {
                    checked = false
                    body[0] = String(head.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if lowered.hasPrefix("[x] ") || lowered == "[x]" {
                    checked = true
                    body[0] = String(head.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
            }
            items.append(MarkdownListItem(checked: checked, blocks: parse(lines: body, depth: depth + 1)))
            // A blank line between items keeps the same list; anything else ends it.
            if index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
               let next = lines[(index + 1)...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
               let nextMarker = listMarker(lines[next]), nextMarker.ordered == first.ordered, nextMarker.indent < first.content {
                index = next
            }
        }
        blocks.append(.list(ordered: first.ordered, start: first.number, items: items))
        return max(index, start + 1)
    }

    private static func parseTable(_ lines: [String], from start: Int, alignments: [MarkdownAlignment], into blocks: inout [MarkdownBlock]) -> Int {
        let header = tableCells(lines[start])
        var rows: [[String]] = []
        var index = start + 2
        while index < lines.count {
            let line = lines[index]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, line.contains("|") else { break }
            rows.append(tableCells(line))
            index += 1
        }
        let width = max(header.count, alignments.count)
        func pad(_ cells: [String]) -> [String] {
            Array((cells + Array(repeating: "", count: max(0, width - cells.count))).prefix(width))
        }
        let columnAlignments = Array((alignments + Array(repeating: .leading, count: max(0, width - alignments.count))).prefix(width))
        blocks.append(.table(header: pad(header), alignments: columnAlignments, rows: rows.map(pad)))
        return index
    }
}
