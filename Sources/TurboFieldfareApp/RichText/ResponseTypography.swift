import CoreGraphics

/// The sizes and spacing `ResponseMarkdownRenderer` sets text with.
///
/// `compact` is what the renderer has always drawn, and it stays the default,
/// so the Mac is unchanged. It was tuned for a desktop window at the
/// platform's system font size. On an iPhone that size is 14 pt against a
/// 17 pt reading size, and 3 pt of line spacing is tight at arm's length, so
/// the phone uses `reading` instead: a serif face, a larger size, and more
/// room between lines, paragraphs, headings and list items.
public struct ResponseTypography: Equatable, Sendable {
    /// Body text size in points. Code is half a point smaller.
    public var bodySize: CGFloat
    /// Prose in the platform serif (New York on Apple platforms). Code stays
    /// monospaced either way.
    public var serif: Bool
    public var lineSpacing: CGFloat
    public var paragraphSpacing: CGFloat
    public var headingSpacingBefore: CGFloat
    public var headingSpacingAfter: CGFloat
    /// How much larger than the body each heading level is, from level 1.
    /// Nil keeps the compact rule: 22 pt for level 1, 2 pt less per level,
    /// never below one point above the body.
    public var headingSteps: [CGFloat]?
    /// Where a list item's text starts, and how far each nesting level moves it.
    public var listTextIndent: CGFloat
    public var listNestingIndent: CGFloat
    public var listItemSpacing: CGFloat
    /// Draws "1." and the bullet in semibold, so a list's structure is visible
    /// in a serif face whose regular weight is light.
    public var boldListMarkers: Bool
    /// Whether two blocks that share one rendered string, such as a heading
    /// with its paragraph right under it, are parted by an empty line. The
    /// compact layout relies on that line for the gap. The reading layout
    /// already has paragraph spacing, and the empty line on top of it drew
    /// about twice the gap a heading should have.
    public var blankLineBetweenBlocks: Bool
    /// The factor `scaled(by:)` has applied, for the metrics that have no
    /// field of their own: quote indents, code and table padding, rule
    /// spacing. Every field above is already in points at this scale.
    public private(set) var scale: CGFloat = 1

    public init(bodySize: CGFloat,
                serif: Bool,
                lineSpacing: CGFloat,
                paragraphSpacing: CGFloat,
                headingSpacingBefore: CGFloat,
                headingSpacingAfter: CGFloat,
                headingSteps: [CGFloat]?,
                listTextIndent: CGFloat,
                listNestingIndent: CGFloat,
                listItemSpacing: CGFloat,
                boldListMarkers: Bool,
                blankLineBetweenBlocks: Bool) {
        self.bodySize = bodySize
        self.serif = serif
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
        self.headingSpacingBefore = headingSpacingBefore
        self.headingSpacingAfter = headingSpacingAfter
        self.headingSteps = headingSteps
        self.listTextIndent = listTextIndent
        self.listNestingIndent = listNestingIndent
        self.listItemSpacing = listItemSpacing
        self.boldListMarkers = boldListMarkers
        self.blankLineBetweenBlocks = blankLineBetweenBlocks
    }

    /// The renderer's original values, verbatim.
    public static var compact: ResponseTypography {
        ResponseTypography(bodySize: PlatformFont.systemFontSize,
                           serif: false,
                           lineSpacing: 3,
                           paragraphSpacing: 6,
                           headingSpacingBefore: 8,
                           headingSpacingAfter: 4,
                           headingSteps: nil,
                           listTextIndent: 22,
                           listNestingIndent: 18,
                           listItemSpacing: 2,
                           boldListMarkers: false,
                           blankLineBetweenBlocks: true)
    }

    /// Long-form reading on a phone, at `bodySize` points.
    public static func reading(bodySize: CGFloat) -> ResponseTypography {
        ResponseTypography(bodySize: bodySize,
                           serif: true,
                           lineSpacing: (bodySize * 0.35).rounded(),
                           paragraphSpacing: (bodySize * 0.75).rounded(),
                           headingSpacingBefore: (bodySize * 0.9).rounded(),
                           headingSpacingAfter: (bodySize * 0.4).rounded(),
                           headingSteps: [6, 4, 2, 1],
                           listTextIndent: (bodySize * 1.6).rounded(),
                           listNestingIndent: (bodySize * 1.25).rounded(),
                           listItemSpacing: (bodySize * 0.4).rounded(),
                           boldListMarkers: true,
                           blankLineBetweenBlocks: false)
    }

    /// The same layout with every size and distance multiplied by `factor`.
    /// The Mac's text-size setting uses it on `compact`.
    public func scaled(by factor: CGFloat) -> ResponseTypography {
        var copy = self
        copy.bodySize *= factor
        copy.lineSpacing *= factor
        copy.paragraphSpacing *= factor
        copy.headingSpacingBefore *= factor
        copy.headingSpacingAfter *= factor
        copy.headingSteps = headingSteps?.map { $0 * factor }
        copy.listTextIndent *= factor
        copy.listNestingIndent *= factor
        copy.listItemSpacing *= factor
        copy.scale *= factor
        return copy
    }

    func scaled(_ baseline: CGFloat) -> CGFloat { baseline * scale }

    func headingSize(level: Int) -> CGFloat {
        guard let headingSteps else {
            return max(bodySize + scaled(1), scaled(22 - CGFloat(level - 1) * 2))
        }
        let index = min(max(level - 1, 0), headingSteps.count - 1)
        return bodySize + (headingSteps.isEmpty ? 0 : headingSteps[index])
    }
}
