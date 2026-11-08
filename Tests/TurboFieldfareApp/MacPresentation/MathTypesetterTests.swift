import AppKit
import Foundation
import Testing
@testable import TurboFieldfareRichText
@testable import TurboFieldfareMacPresentation

/// Exercises the typesetting library only through the production conformer, so
/// what these tests pin is the behaviour the transcript actually gets. A pin
/// change that breaks a command shows up here rather than as a blank equation.
@MainActor
@Suite struct MathTypesetterTests {
    static let fontSize: CGFloat = 13

    static func render(
        _ latex: String,
        mode: MathRenderMode = .inline,
        tint: NSColor = .black
    ) -> MathRender? {
        SwiftMathTypesetter().render(
            latex: latex,
            fontSize: fontSize,
            tint: tint,
            mode: mode)
    }

    /// Draws the attachment image the way the text view does and returns its
    /// pixels, so a tint difference is a measured difference and not an
    /// identity comparison on two `NSImage` objects.
    static func pixels(_ image: NSImage) -> [UInt8]? {
        let width = Int(ceil(image.size.width))
        let height = Int(ceil(image.size.height))
        guard width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0) else {
            return nil
        }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        return Array(UnsafeBufferPointer(
            start: data,
            count: rep.bytesPerRow * rep.pixelsHigh))
    }

    @Test(arguments: [
        #"\frac{a}{b}"#,
        #"\sqrt{b^2 - 4ac}"#,
        #"\sum_{i=1}^{n} i"#,
        #"\begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix}"#,
        #"\alpha + \beta = \gamma"#,
        // The pin probe: tag 1.7.3 duplicates the fenced content here, the
        // pinned revision does not.
        #"\left( \frac{a}{b} \right)"#,
    ])
    func typesetsTheCommandsGemmaEmits(_ latex: String) throws {
        let render = try #require(Self.render(latex))
        #expect(render.ascent > 0)
        #expect(render.descent > 0)
        #expect(render.image.size.width > 0)
        #expect(render.image.size.height > 0)
    }

    @Test(arguments: [
        (#"\begin{cases} x & x \ge 0 \\ -x & x < 0 \end{cases}"#, true),
        (#"\begin{aligned} a &= b \\ c &= d \end{aligned}"#, true),
        (#"\begin{matrix} a & b \end{matrix}"#, true),
        // Rejected by the pinned revision with an error; the normalizer
        // rewrites these before the transcript reaches the typesetter, and an
        // unrewritten one falls back to raw text rather than disappearing.
        // A character with no atom is a different failure: the build drops it
        // without an error at all, which is what the refusal above catches.
        (#"\begin{align*} a &= b \end{align*}"#, false),
        (#"\begin{array}{cc} 1 & 2 \end{array}"#, false),
    ])
    func environmentCoverageIsPinnedInBothDirections(_ probe: (String, Bool)) {
        #expect((Self.render(probe.0) != nil) == probe.1, "\(probe.0)")
    }

    /// The pinned build skips a character it has no atom for and reports
    /// nothing, so these came back as finished-looking images with the
    /// operator missing: `\u{221A}2` was pixel-identical to `2`. Refusing
    /// restores the span's own source, which the reader can at least read.
    @Test(arguments: [
        "\u{221A}2",
        "f\u{2032}(x)",
        "90\u{00B0}",
        "\u{00AC}p \u{2228} q",
        "a \u{2218} b",
        "x \u{226A} y",
        "a~b",
        "x\u{200B}y",
        "50% of it",
    ])
    func scalarsThePinnedBuildDropsAreRefusedNotDrawn(_ latex: String) {
        #expect(Self.render(latex) == nil, "\(latex.debugDescription)")
    }

    /// The two the plan expected to be refused and the build actually draws.
    /// `'` is in the accented table, which `atom(forCharacter:)` consults
    /// before its ASCII rules, and a combining mark joins the letter before it
    /// into a grapheme that sorts inside the a-z range.
    @Test(arguments: ["f'(x)", "e\u{301} = 1"])
    func theTwoLookAlikesThePinnedBuildDoesDraw(_ latex: String) {
        #expect(Self.render(latex) != nil, "\(latex.debugDescription)")
    }

    @Test(arguments: [#"\frac{"#, #"\unknowncmd"#, #"\left( x"#])
    func invalidLatexProducesNoImage(_ latex: String) {
        #expect(Self.render(latex) == nil)
    }

    /// The attachment bounds are `-descent` tall below the baseline and
    /// `ascent` above it, so the image must be exactly that tall or the
    /// equation sits off the line.
    @Test func imageHeightIsAscentPlusDescent() throws {
        for latex in [#"\frac{a}{b}"#, #"x"#, #"\sum_{i=1}^{n} i"#, #"\sqrt{x}"#] {
            let render = try #require(Self.render(latex))
            #expect(render.image.size.height == render.ascent + render.descent,
                    "\(latex)")
        }
    }

    /// The glyph's alpha at 3x, rows from the top.
    static func coverage(_ image: NSImage) -> [[UInt8]]? {
        let scale: CGFloat = 3
        let width = Int(ceil(image.size.width * scale))
        let height = Int(ceil(image.size.height * scale))
        guard width > 0, height > 0, let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        // Before the context is made, or it draws at 1x into the 3x bitmap.
        rep.size = image.size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return (0..<height).map { y in
            (0..<width).map { x in UInt8(rep.colorAt(x: x, y: y)!.alphaComponent * 255) }
        }
    }

    /// Measured before the fix at 17 pt, the iPhone's size: every one of these
    /// had ink in its edge rows or columns, so part of a glyph was cut off. A
    /// lone `x` or `ε` lost its foot, and an italic `y` the end of its tail.
    @Test(arguments: [
        "x", #"\epsilon"#, #"\varepsilon"#, "a", "y", "f", "-", #"\cdot"#,
        "f(x)", "x^2", #"\frac{a}{b}"#, #"\int_0^1 f"#,
    ])
    func noGlyphTouchesTheImageEdge(_ latex: String) throws {
        for mode in [MathRenderMode.inline, .display] {
            let render = try #require(SwiftMathTypesetter().render(
                latex: latex, fontSize: 17, tint: .black, mode: mode))
            let rows = try #require(Self.coverage(render.image))
            let edges = [rows.first!, rows.last!, rows.map(\.first!), rows.map(\.last!)]
            #expect(edges.allSatisfy { $0.allSatisfy { $0 == 0 } }, "\(latex) \(mode)")
        }
    }

    /// The reported descent is where the baseline really is in the image, so
    /// the equation sits on the line of text around it. An `x` stands on the
    /// baseline, and a `y` hangs below it.
    @Test func theDescentIsTheBaselineInTheImage() throws {
        func lowestInk(_ latex: String) throws -> (ink: CGFloat, descent: CGFloat) {
            let render = try #require(SwiftMathTypesetter().render(
                latex: latex, fontSize: 17, tint: .black, mode: .inline))
            let rows = try #require(Self.coverage(render.image))
            let lowest = try #require(rows.lastIndex { $0.contains { $0 > 128 } })
            return (CGFloat(rows.count - 1 - lowest) / 3, render.descent)
        }
        let x = try lowestInk("x")
        #expect(abs(x.ink - x.descent) < 0.7, "x: ink at \(x.ink), baseline at \(x.descent)")
        let y = try lowestInk("y")
        #expect(y.ink < y.descent - 2, "y: ink at \(y.ink), baseline at \(y.descent)")
    }

    @Test func anEquationWiderThanTheLineIsShrunkAboutItsBaseline() {
        let bounds = CGRect(x: 0, y: -10, width: 400, height: 40)
        #expect(MathAttachment.fitted(bounds, width: 200)
            == CGRect(x: 0, y: -5, width: 200, height: 20))
        #expect(MathAttachment.fitted(bounds, width: 400) == bounds)
        #expect(MathAttachment.fitted(bounds, width: 0) == bounds)
        #expect(MathAttachment.fitted(bounds, width: .infinity) == bounds)

        let list = NSMutableParagraphStyle()
        list.firstLineHeadIndent = 4
        list.headIndent = 20
        #expect(MathAttachment.indent(list) == 20)
        #expect(MathAttachment.indent(nil) == 0)
    }

    /// Through a real text view, the way the transcript lays it out.
    @Test func aLongEquationFitsTheTextViewItIsShownIn() throws {
        let render = try #require(Self.render(
            #"a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_{10} + a_{11} + a_{12}"#,
            mode: .display))
        let attachment = MathAttachment(latexSource: "long")
        attachment.image = render.image
        attachment.bounds = CGRect(
            x: 0, y: -render.descent,
            width: render.image.size.width, height: render.image.size.height)
        let width: CGFloat = 120
        #expect(render.image.size.width > width)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(NSAttributedString(attachment: attachment))
        let layout = try #require(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var widest: CGFloat = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location) { fragment in
            widest = max(widest, fragment.layoutFragmentFrame.maxX)
            return true
        }
        #expect(widest <= width + 0.5, "laid out \(widest) wide in \(width)")
    }

    @Test func maskTintProducesVisibleGlyphsInTheRequestedColor() throws {
        let render = try #require(Self.render(#"x = \frac{a}{b}"#, tint: .red))
        let pixels = try #require(Self.pixels(render.image))
        let opaqueRed = stride(from: 0, to: pixels.count, by: 4).contains { index in
            pixels[index] > 200 && pixels[index + 1] < 80 && pixels[index + 3] > 200
        }
        #expect(opaqueRed, "the tint must paint the glyph coverage, not the background")
    }

    @Test func twoTintsProduceDifferentPixels() throws {
        let latex = #"E = mc^2"#
        let redRender = try #require(Self.render(latex, tint: .red))
        let blueRender = try #require(Self.render(latex, tint: .blue))
        let red = try #require(Self.pixels(redRender.image))
        let blue = try #require(Self.pixels(blueRender.image))
        #expect(red.count == blue.count)
        #expect(red != blue)
    }

    /// Finalising a fifty-equation answer costs 36.7 ms, and a rebuild while
    /// the answer is terminal re-renders all of it, so the same equation at the
    /// same size and colour must come back as the same image.
    @Test func repeatedRendersOfTheSameEquationReuseOneImage() throws {
        let cache = MathRenderCache()
        let typesetter = SwiftMathTypesetter(cache: cache)
        let first = try #require(typesetter.render(
            latex: #"\frac{a}{b}"#,
            fontSize: 13,
            tint: .labelColor,
            mode: .inline))
        let second = try #require(typesetter.render(
            latex: #"\frac{a}{b}"#,
            fontSize: 13,
            tint: .labelColor,
            mode: .inline))
        #expect(first.image === second.image)
        #expect(cache.count == 1)

        // Anything that changes the pixels is a different entry.
        _ = typesetter.render(latex: #"\frac{a}{b}"#, fontSize: 22, tint: .labelColor, mode: .inline)
        _ = typesetter.render(latex: #"\frac{a}{b}"#, fontSize: 13, tint: .red, mode: .inline)
        _ = typesetter.render(latex: #"\frac{a}{b}"#, fontSize: 13, tint: .labelColor, mode: .display)
        #expect(cache.count == 4)
        // The bound is what the masks cost, not how many there are: a display
        // equation's is about ten times an inline one's.
        #expect(cache.byteCount > 0)
    }

    /// A count limit is either far too small for a page of prose or far too
    /// large for a page of derivations, because the two differ by an order of
    /// magnitude in what they retain.
    @Test func theRenderCacheIsBoundedByBytesAndDropsWhenItOverflows() throws {
        let measure = MathRenderCache()
        let typesetter = SwiftMathTypesetter(cache: measure)
        _ = try #require(typesetter.render(
            latex: #"\frac{a}{b}"#, fontSize: 13, tint: .labelColor, mode: .inline))
        let one = measure.byteCount
        #expect(one > 0)

        // Room for one entry and not two: storing the second empties the table.
        let tight = MathRenderCache(byteLimit: one + one / 2)
        let bounded = SwiftMathTypesetter(cache: tight)
        _ = bounded.render(latex: #"\frac{a}{b}"#, fontSize: 13, tint: .labelColor, mode: .inline)
        #expect(tight.count == 1)
        #expect(tight.byteCount == one)
        _ = bounded.render(latex: #"\frac{c}{d}"#, fontSize: 13, tint: .labelColor, mode: .inline)
        #expect(tight.count == 1)
        #expect(tight.byteCount <= tight.byteCount)

        // An entry bigger than the whole budget is drawn and not kept, rather
        // than emptying the table for something that cannot fit.
        let tiny = MathRenderCache(byteLimit: one / 2)
        let unbounded = SwiftMathTypesetter(cache: tiny)
        #expect(unbounded.render(
            latex: #"\frac{a}{b}"#, fontSize: 13, tint: .labelColor, mode: .inline) != nil)
        #expect(tiny.count == 0)
        #expect(tiny.byteCount == 0)
    }

    /// Measured on the pinned revision: `.text` mode shrinks a fraction (19 pt
    /// against 24 pt at 13 pt type) but still stacks big-operator limits, so
    /// `\sum_{i=1}^n i` is 34 pt tall in both modes and is not a valid pin for
    /// the mode mapping.
    @Test func inlineAndDisplayModesDifferInHeight() throws {
        let inline = try #require(Self.render(#"\frac{a}{b}"#, mode: .inline))
        let display = try #require(Self.render(#"\frac{a}{b}"#, mode: .display))
        #expect(display.image.size.height > inline.image.size.height)

        let inlineSum = try #require(Self.render(#"\sum_{i=1}^n i"#, mode: .inline))
        let displaySum = try #require(Self.render(#"\sum_{i=1}^n i"#, mode: .display))
        #expect(displaySum.image.size.height == inlineSum.image.size.height)
    }
}
