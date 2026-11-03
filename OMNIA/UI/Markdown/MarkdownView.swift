import SwiftUI
import UIKit

/// Renders model output as native SwiftUI: headings, paragraphs, lists, quotes, tables and
/// syntax-highlighted code blocks with copy buttons. Streams without flicker: blocks keep
/// stable identities, so only the block being written re-renders.
struct MarkdownView: View {
    let text: String
    var isStreaming = false
    var typeface: ChatTypeface = .system
    var scale: Double = 1

    var body: some View {
        let blocks = isStreaming ? MarkdownParser.parse(text) : MarkdownParser.parseCached(text)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, typeface: typeface, scale: scale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var typeface: ChatTypeface
    var scale: Double

    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = 17

    private var bodyFont: Font { .system(size: baseSize * scale, design: typeface.design) }

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(Self.inline(text))
                .font(.system(size: baseSize * scale * headingScale(level), weight: level <= 2 ? .bold : .semibold, design: typeface.design))
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)

        case let .paragraph(text):
            Text(Self.inline(text))
                .font(bodyFont)
                .lineSpacing(baseSize * scale * 0.22)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case let .code(language, code, _):
            CodeBlockView(language: language, code: code, scale: scale)

        case let .list(items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .font(bodyFont.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 16, alignment: .trailing)
                        Text(Self.inline(item.text))
                            .font(bodyFont)
                            .lineSpacing(baseSize * scale * 0.18)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.indent) * 20)
                }
            }

        case let .quote(blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, inner in
                        MarkdownBlockView(block: inner, typeface: typeface, scale: scale)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .table(header, alignments, rows):
            MarkdownTableView(header: header, alignments: alignments, rows: rows, font: bodyFont)

        case .rule:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func headingScale(_ level: Int) -> Double {
        switch level {
        case 1: 1.45
        case 2: 1.28
        case 3: 1.14
        default: 1.04
        }
    }

    /// Inline Markdown (bold, italics, `code`, links, strikethrough) via Foundation.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct CodeBlockView: View {
    let language: String
    let code: String
    var scale: Double = 1
    /// Offers Preview or Run in the conversation's workspace (not inside the workspace itself).
    var showsWorkspaceActions = true

    @State private var copied = false
    @ScaledMetric(relativeTo: .body) private var codeSize: CGFloat = 14
    @Environment(WorkspaceController.self) private var workspace: WorkspaceController?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if showsWorkspaceActions, let workspace {
                    let kind = CodeArtifact.Kind(language: language, code: code)
                    if kind.isPreviewable || kind.isRunnable {
                        Button {
                            workspace.show(language: language, code: code)
                        } label: {
                            Label(kind.isRunnable ? "Run" : "Preview", systemImage: kind.isRunnable ? "play.fill" : "eye")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                }
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? Theme.positive : .secondary)
                .sensoryFeedback(.success, trigger: copied) { _, new in new }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Rectangle().fill(Theme.hairline).frame(height: 0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(.system(size: codeSize * scale, design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
            }
        }
        .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

struct MarkdownTableView: View {
    let header: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    let font: Font

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, cell in
                        cellView(cell, column: index, bold: true)
                    }
                }
                .background(Theme.faint)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            cellView(cell, column: index, bold: false)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func cellView(_ text: String, column: Int, bold: Bool) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .leading
        return Text(MarkdownBlockView.inline(text))
            .font(bold ? font.weight(.semibold) : font)
            .multilineTextAlignment(alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .frame(minWidth: 72, maxWidth: 320, alignment: alignment == .center ? .center : alignment == .trailing ? .trailing : .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .textSelection(.enabled)
    }
}
