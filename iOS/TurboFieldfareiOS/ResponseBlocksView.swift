import SwiftUI
import TurboFieldfareAppPresentation
import TurboFieldfareRichText

/// Draws one response as the blocks `ResponseBlockSplitter` found in it.
///
/// Blocks rather than one view, because a fenced code block needs a monospaced
/// font and a horizontal scroller of its own, and the splitter is what says
/// where one ends. Going through it also keeps the per-tick cost proportional
/// to the text that arrived — see `StreamingBlocks`.
///
/// Block-level markdown and LaTeX are typeset by `ResponseMarkdownRenderer`,
/// the same renderer the Mac uses, hosted in a `UITextView` — see `MarkdownText`
/// for why SwiftUI's `Text` cannot do it. Two kinds are drawn as views instead,
/// both for the same reason: an attributed string cannot draw a rule or a box
/// on iOS, where `NSTextTable` does not exist. Fenced code gets a scroller, and
/// a table gets `MarkdownTableView`.
struct ResponseBlocksView: View {
    let response: String
    let split: ResponseBlockSplitter.Split
    /// The live turn's scan state, which also memoises the blocks it has
    /// sealed. Nil for a frozen turn, which has no lineage to key against and
    /// uses the text-keyed cache instead.
    var blocks: StreamingBlocks?
    /// Whether anything more is coming. False only while the turn is in flight.
    ///
    /// This is the port of the Mac's `closeTail`. The splitter never commits a
    /// trailing block — it is always `split.open`, by construction — so without
    /// a terminal pass the last block of every answer keeps its streaming
    /// dress for good: math left as LaTeX source and the tail auto-closed.
    /// Closing it here rather than re-rendering the whole answer is deliberate
    /// and is the Mac's reasoning verbatim: a message-wide render puts the text
    /// back through gates the streaming pass applies per block, so an answer
    /// that streamed styled would flip to raw source the moment it finished.
    var isTerminal = false
    /// Whether this is the model's reasoning rather than its answer. It changes
    /// two things: code draws in secondary grey to match the prose around it,
    /// and an indent-only code block is read as prose — see `dedented`.
    var isReasoning = false

    var body: some View {
        // The gap between blocks is the gap between paragraphs, so it matches
        // the paragraph spacing the reading typography sets inside a block.
        VStack(alignment: .leading, spacing: ResponseTypography.phone.paragraphSpacing) {
            // Keyed on the block's UTF-8 start offset, which is a stable
            // identity rather than the enumeration index it looks like: the
            // splitter guarantees nothing already in `completed` moves when
            // more text arrives, and blocks are ordered and non-overlapping.
            ForEach(split.completed, id: \.start) { block in
                blockView(block, isOpen: false)
            }
            if let open = split.open {
                blockView(open, isOpen: true)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: ResponseBlockSplitter.Block,
                           isOpen: Bool) -> some View {
        switch block.kind {
        case .fencedCode:
            codeView(block)
        case .indentedCode:
            // Indentation means code in an answer and means nothing in
            // reasoning, where the model indents continuation lines and nested
            // working as a matter of habit.
            if isReasoning {
                MarkdownText(attributed: renderedText(Self.dedented(
                    ResponseBlockSplitter.text(block.utf8Range, in: response))))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                codeView(block)
            }
        case .table:
            tableView(block, isOpen: isOpen)
        case .thematicBreak:
            // A hairline across the column. The renderer's own form is a run
            // of box-drawing characters, centred: a fixed-length stub on a
            // phone-width column.
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
        case .paragraph:
            // A table written without outer pipes — `Name | Role | Level` over
            // `--- | --- | ---` — opens as a paragraph, because the splitter
            // classifies a line by its first byte. It becomes `.table` once
            // its delimiter row ends. This retry covers a delimiter row that is
            // the answer's last line and has no newline, which the splitter
            // never commits.
            if let table = pipelessTable(block, isOpen: isOpen) {
                MarkdownTableView(table: table, renderCell: renderedText)
            } else {
                prose(block, isOpen: isOpen)
            }
        default:
            prose(block, isOpen: isOpen)
        }
    }

    /// A block drawn as attributed text, or nothing while all of it is held
    /// back — an equation alone in its block, still being written. Nothing
    /// rather than an empty text view, which would still take a paragraph gap.
    @ViewBuilder
    private func prose(_ block: ResponseBlockSplitter.Block, isOpen: Bool) -> some View {
        let text = rendered(block, isOpen: isOpen)
        if text.length > 0 {
            MarkdownText(attributed: text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Whether this block is the one still being written, and so is subject
    /// to `StreamingHoldback`.
    private func isStreaming(_ isOpen: Bool) -> Bool {
        isOpen && !isTerminal && blocks != nil
    }

    /// A table, or its source if it turns out not to be one.
    ///
    /// While it streams, only whole rows are shown, so a row never appears as
    /// a line of empty cells that fill in. A block opens as `.table` on its
    /// first `|`, so until the delimiter row lands there is no grid to draw;
    /// that is a line or two held back, not pipes that turn into a grid. Past
    /// that, a block that still does not parse is not a table, and is shown
    /// as written.
    @ViewBuilder
    private func tableView(_ block: ResponseBlockSplitter.Block,
                           isOpen: Bool) -> some View {
        let whole = ResponseBlockSplitter.text(block.utf8Range, in: response)
        let source = isStreaming(isOpen) ? StreamingHoldback.completeLines(whole) : whole
        if let table = MarkdownTable.parse(source) {
            MarkdownTableView(table: table, renderCell: renderedText)
        } else if !isStreaming(isOpen) || source.utf8.count(where: { $0 == 0x0A }) > 2 {
            MarkdownText(attributed: rendered(block, isOpen: isOpen))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A paragraph that is really a pipe table written without outer pipes.
    ///
    /// The `contains` guard is what keeps this off the hot path: a byte scan
    /// over one block that fails immediately for the ordinary prose every other
    /// paragraph is, before any splitting or allocation happens.
    private func pipelessTable(_ block: ResponseBlockSplitter.Block,
                               isOpen: Bool) -> MarkdownTable? {
        let source = ResponseBlockSplitter.text(block.utf8Range, in: response)
        guard source.contains("|") else { return nil }
        return MarkdownTable.parse(
            isStreaming(isOpen) ? StreamingHoldback.completeLines(source) : source)
    }

    private func rendered(_ block: ResponseBlockSplitter.Block,
                          isOpen: Bool) -> NSAttributedString {
        if let blocks {
            return isOpen && !isTerminal
                ? blocks.renderedOpen(block, in: response)
                : blocks.rendered(block, in: response)
        }
        return FrozenRenderCache.shared.rendered(
            ResponseBlockSplitter.text(block.utf8Range, in: response))
    }

    /// Renders text that is not a whole block — a table cell, or a reinterpreted
    /// indented block — through whichever renderer this role owns.
    private func renderedText(_ text: String) -> NSAttributedString {
        if let blocks { return blocks.renderedText(text) }
        return FrozenRenderCache.shared.rendered(text)
    }

    /// Strips one level of block indentation.
    ///
    /// CommonMark opens an indented code block at four spaces after a blank
    /// line, and `ResponseBlockSplitter` agrees — correctly, for an answer.
    /// Reasoning is not written as markup, so every indented continuation line
    /// became a grey box of unrendered monospace. Only the indent-only kind is
    /// reinterpreted; a fenced block in reasoning is still code.
    private static func dedented(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var line = line
                var removed = 0
                while removed < 4, line.first == " " {
                    line = line.dropFirst()
                    removed += 1
                }
                if removed == 0, line.first == "\t" { line = line.dropFirst() }
                return line
            }
            .joined(separator: "\n")
    }

    private func codeView(_ block: ResponseBlockSplitter.Block) -> some View {
        // A fence's body, not the block: the opening and closing marker lines
        // are syntax, not code. An indented block has no fence, so it falls
        // back to its own range.
        let range = block.fence.map { $0.bodyStart..<max($0.bodyStart, $0.bodyEnd) }
            ?? block.utf8Range
        let code = ResponseBlockSplitter.text(range, in: response)
        return ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.footnote, design: .monospaced))
                // Reasoning is grey throughout, and a code block sitting in it
                // at full contrast read as a separate thing the model had said
                // rather than as part of the thought.
                .foregroundStyle(isReasoning ? AnyShapeStyle(.secondary)
                                             : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .padding(12)
        }
        .background(Color(uiColor: .tertiarySystemFill),
                    in: .rect(cornerRadius: 12))
        // Content, not a control: no glass here. The vendored Liquid Glass
        // skill leads with that rule and it is the right one — glass behind a
        // wall of streaming monospaced text is unreadable and composites the
        // container on every tick.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
