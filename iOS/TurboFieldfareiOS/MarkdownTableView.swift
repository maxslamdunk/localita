import SwiftUI
import TurboFieldfareAppPresentation
import TurboFieldfareRichText
import UIKit

/// A table drawn as a grid of views.
///
/// The Mac rules its tables with `NSTextTable`. iOS does not have it, and
/// nothing inside an attributed string can draw a rule there — so on the phone
/// the grid has to be built out of views, which is the whole reason this is a
/// view and not something the shared renderer does. `MarkdownTable` owns the
/// parse; this owns only the layout.
///
/// Equal-width columns rather than content-sized ones. A phone has no spare
/// width for a column to take what it wants, and a `Grid` sizing itself from a
/// `UIViewRepresentable` has no width to propose to it — the cell would have to
/// measure itself before being told how wide it is. Equal columns give every
/// cell a concrete width to wrap inside, which is what `MarkdownText` needs in
/// order to report a height at all.
struct MarkdownTableView: View {
    let table: MarkdownTable
    /// Renders one cell. Every cell goes back through the same markdown
    /// renderer the prose uses, so bold, inline code and inline maths all work
    /// inside a cell. Supplied by the caller because the colour differs between
    /// an answer and reasoning, and the renderer is what carries that colour.
    let renderCell: (String) -> NSAttributedString

    private var columns: [Int] { Array(0..<table.columnCount) }

    var body: some View {
        VStack(spacing: 0) {
            row(table.headers, isHeader: true)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                Divider()
                row(cells, isHeader: false)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground),
                    in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(uiColor: .separator), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        // `columns` and not `0..<count`: a range literal is treated as constant
        // by `ForEach`, and this one changes when a streaming table's widest
        // row arrives.
        HStack(alignment: .top, spacing: 0) {
            ForEach(columns, id: \.self) { column in
                MarkdownText(attributed: cell(
                    column < cells.count ? cells[column] : "",
                    isHeader: isHeader))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity,
                           alignment: Self.alignment(table.alignment(column)))
            }
        }
        .background(isHeader
            ? Color(uiColor: .tertiarySystemFill)
            : Color.clear)
    }

    private static func alignment(_ alignment: MarkdownTable.Alignment) -> Alignment {
        switch alignment {
        case .leading: .topLeading
        case .center: .top
        case .trailing: .topTrailing
        }
    }

    private func cell(_ text: String, isHeader: Bool) -> NSAttributedString {
        let rendered = renderCell(text)
        return isHeader ? Self.emboldened(rendered) : rendered
    }

    /// Header weight applied to the rendered string, not by wrapping the cell
    /// source in `**`: a header cell that is already bold — which is how this
    /// model writes most of them — would become `****like this****`, and that
    /// parses as literal asterisks around emphasis rather than as bold.
    private static func emboldened(_ string: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: string)
        let whole = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.font, in: whole) { value, range, _ in
            guard let font = value as? UIFont,
                  let descriptor = font.fontDescriptor.withSymbolicTraits(
                    font.fontDescriptor.symbolicTraits.union(.traitBold))
            else { return }
            copy.addAttribute(.font,
                              value: UIFont(descriptor: descriptor, size: font.pointSize),
                              range: range)
        }
        return copy
    }
}
