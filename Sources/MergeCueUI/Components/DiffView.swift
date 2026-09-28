import MergeCueCore
import SwiftUI

/// One rendered line of a unified diff.
nonisolated struct DiffLine: Hashable, Identifiable, Sendable {
    enum Kind: Sendable { case meta, hunk, context, added, removed }
    var id: Int
    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
}

/// One file of a unified diff.
nonisolated struct DiffFile: Hashable, Identifiable, Sendable {
    var id: Int
    var path: String
    var lines: [DiffLine]
    var additions: Int { lines.filter { $0.kind == .added }.count }
    var deletions: Int { lines.filter { $0.kind == .removed }.count }
}

/// Minimal unified-diff parser (file headers, hunks, line numbers).
nonisolated enum DiffParser {
    static func parse(_ diff: String, defaultPath: String = "") -> [DiffFile] {
        var files: [DiffFile] = []
        var current = DiffFile(id: 0, path: defaultPath, lines: [])
        var oldLine = 0, newLine = 0, lineID = 0
        func flush() {
            if !current.lines.isEmpty { files.append(current) }
        }
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            lineID += 1
            if line.hasPrefix("diff --git ") {
                flush()
                let path = line.components(separatedBy: " b/").last ?? line
                current = DiffFile(id: files.count + 1, path: path, lines: [])
                continue
            }
            if line.hasPrefix("index ") || line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("new file mode") {
                continue
            }
            if line.hasPrefix("@@") {
                let numbers = Self.hunkStarts(line)
                oldLine = numbers.old
                newLine = numbers.new
                current.lines.append(DiffLine(id: lineID, kind: .hunk, text: line))
                continue
            }
            if line.hasPrefix("+") {
                current.lines.append(DiffLine(id: lineID, kind: .added, text: String(line.dropFirst()), newNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                current.lines.append(DiffLine(id: lineID, kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                current.lines.append(DiffLine(id: lineID, kind: .meta, text: line))
            } else {
                if line.isEmpty, current.lines.isEmpty { continue }
                current.lines.append(DiffLine(id: lineID, kind: .context, text: line.isEmpty ? "" : String(line.dropFirst()),
                                              oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        flush()
        // Drop trailing empty context lines produced by a final newline.
        return files.map { file in
            var file = file
            while let last = file.lines.last, last.kind == .context, last.text.isEmpty { file.lines.removeLast() }
            return file
        }
    }

    /// `@@ -80,10 +80,14 @@` → (80, 80).
    static func hunkStarts(_ header: String) -> (old: Int, new: Int) {
        let parts = header.split(separator: " ")
        func start(_ prefix: Character) -> Int {
            guard let part = parts.first(where: { $0.first == prefix }) else { return 1 }
            return Int(part.dropFirst().split(separator: ",").first ?? "1") ?? 1
        }
        return (start("-"), start("+"))
    }
}

/// Renders a unified diff with line numbers, per-file headers and horizontal scrolling for long lines.
struct DiffView: View {
    var files: [DiffFile]
    var showFileHeaders = true
    @State private var viewportWidth: CGFloat = 0

    init(diff: String, defaultPath: String = "", showFileHeaders: Bool = true) {
        self.files = DiffParser.parse(diff, defaultPath: defaultPath)
        self.showFileHeaders = showFileHeaders
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: 0) {
                    if showFileHeaders {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundStyle(Theme.textSecondary)
                                .accessibilityHidden(true)
                            Text(file.path)
                                .scaledFont(.callout.monospaced().weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Text("+\(file.additions)").foregroundStyle(Theme.mintText)
                            Text("−\(file.deletions)").foregroundStyle(Theme.criticalText)
                        }
                        .scaledFont(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.textSecondary.opacity(0.08))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(file.path), \(file.additions) additions, \(file.deletions) deletions")
                    }
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(file.lines) { line in
                                DiffLineRow(line: line)
                            }
                        }
                        .padding(.vertical, 4)
                        .frame(minWidth: viewportWidth, alignment: .leading)
                    }
                    .scrollIndicators(.automatic)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            }
        }
    }
}

private struct DiffLineRow: View {
    var line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .frame(width: 16)
                .foregroundStyle(markerColor)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .meta ? Theme.textSecondary : Theme.textPrimary)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 12)
        }
        .scaledFont(.system(.caption, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 36, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        default: " "
        }
    }

    private var markerColor: Color {
        switch line.kind {
        case .added: Theme.mintText
        case .removed: Theme.criticalText
        default: Theme.textSecondary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Theme.mint.opacity(0.13)
        case .removed: Theme.critical.opacity(0.11)
        case .hunk: Theme.accent.opacity(0.08)
        default: .clear
        }
    }

    private var accessibilityText: String {
        switch line.kind {
        case .added: "Added line \(line.newNumber ?? 0): \(line.text)"
        case .removed: "Removed line \(line.oldNumber ?? 0): \(line.text)"
        case .hunk: "Hunk \(line.text)"
        default: line.text
        }
    }
}

/// A bounded, redacted CI log excerpt (untrusted output) with failure lines highlighted.
struct LogExcerptView: View {
    var excerpt: LogExcerpt
    var maxHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("CI output — untrusted", systemImage: "exclamationmark.shield")
                    .scaledFont(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                if excerpt.truncated {
                    Chip(text: "Excerpt", symbol: "scissors")
                }
                Spacer()
                if let bytes = excerpt.totalBytes {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " total")
                        .scaledFont(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(excerpt.text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, raw in
                        let line = String(raw)
                        Text(line.isEmpty ? " " : line)
                            .scaledFont(.system(.caption, design: .monospaced))
                            .foregroundStyle(Self.isFailure(line) ? Theme.criticalText : Theme.textPrimary)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Self.isFailure(line) ? Theme.critical.opacity(0.08) : Color.clear)
                    }
                }
                .padding(.vertical, 6)
                .textSelection(.enabled)
            }
            .frame(maxHeight: maxHeight)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
            .accessibilityLabel("CI log excerpt")
        }
    }

    static func isFailure(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("error") || lower.contains("fail") || lower.contains("✘") || lower.contains("panic")
    }
}
