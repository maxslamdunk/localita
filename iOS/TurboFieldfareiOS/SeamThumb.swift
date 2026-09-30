import SwiftUI

/// The chat list's scroll thumb, drawn on the seam between the list and the
/// chat screen instead of as a bar inside the list: a stretch of the seam's
/// glow (its shadow in light mode) that is stronger, most at its middle and
/// fading along a bell curve either side.
///
/// The list writes where it is scrolled to, and only the glow reads it, so a
/// scroll redraws the glow and nothing else.
@Observable
final class SeamThumb {
    /// How far down the list is scrolled, 0 at the top and 1 at the bottom.
    var position: CGFloat = 0
    /// How much of the list is on screen at once. 1 or more means all of it,
    /// and then there is no thumb.
    var visibleFraction: CGFloat = 1
    /// Shown while the list scrolls and for a moment after, like the system's.
    var isVisible = false
}

extension View {
    /// Hides the system scroll indicator and reports the scroll to `thumb`.
    func reportsScroll(to thumb: SeamThumb) -> some View {
        modifier(SeamThumbReporter(thumb: thumb))
    }
}

private struct SeamThumbReporter: ViewModifier {
    let thumb: SeamThumb
    @State private var hide: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: CGPoint.self) { geometry in
                let insets = geometry.contentInsets.top + geometry.contentInsets.bottom
                let total = geometry.contentSize.height + insets
                let range = total - geometry.containerSize.height
                let position = range > 0
                    ? (geometry.contentOffset.y + geometry.contentInsets.top) / range
                    : 0
                return CGPoint(x: min(max(position, 0), 1),
                               y: geometry.containerSize.height / max(total, 1))
            } action: { _, scroll in
                thumb.position = scroll.x
                thumb.visibleFraction = scroll.y
            }
            .onScrollPhaseChange { _, phase in
                hide?.cancel()
                if phase.isScrolling {
                    thumb.isVisible = true
                } else {
                    hide = Task {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { thumb.isVisible = false }
                    }
                }
            }
    }
}

/// The thumb itself: a stretch of the seam, lit along a bell curve and blurred
/// like the seam's glow. Position and curve are measured along the seam's own
/// length, round the top corner, down the side and round the bottom corner,
/// so the thumb travels the whole seam and bends with it at the ends.
struct SeamThumbGlow: View {
    let thumb: SeamThumb
    let cornerRadius: CGFloat
    let color: Color
    let strength: Double
    let reach: CGFloat
    let softness: CGFloat

    /// The shortest the thumb gets, however long the list.
    private static var minimumLength: CGFloat { 80 }
    /// Room around the screen for the stroke and its blur, which a canvas
    /// would otherwise clip at its edges.
    private static var margin: CGFloat { 40 }
    /// Pieces the lit stretch is drawn in, each at its own brightness.
    private static var pieces: Int { 48 }

    var body: some View {
        // Read here rather than in the canvas, so a scroll redraws it.
        let position = thumb.position
        let visibleFraction = thumb.visibleFraction
        Canvas { context, size in
            let margin = Self.margin
            let screen = CGRect(x: margin, y: margin,
                                width: size.width - 2 * margin,
                                height: size.height - 2 * margin)
            let radius = min(cornerRadius, screen.width / 2, screen.height / 2)
            let seam = Self.seam(in: screen, radius: radius)
            let total = .pi * radius + (screen.height - 2 * radius)
            guard total > 0 else { return }

            let length = min(max(visibleFraction * total, Self.minimumLength), total)
            // ±2σ spans the thumb's length, and the peak runs end to end.
            let sigma = length / 4
            let center = position * total
            let step = 6 * sigma / CGFloat(Self.pieces)
            for index in 0..<Self.pieces {
                let from = max(center - 3 * sigma + CGFloat(index) * step, 0)
                let to = min(from + step, total)
                guard from < to else { continue }
                let k = ((from + to) / 2 - center) / sigma
                context.stroke(
                    seam.trimmedPath(from: from / total, to: to / total),
                    with: .color(color.opacity(strength * exp(-0.5 * k * k))),
                    style: StrokeStyle(lineWidth: 2 * reach, lineCap: .butt))
            }
        }
        .padding(-Self.margin)
        .blur(radius: softness)
        .opacity(thumb.isVisible && visibleFraction < 1 ? 1 : 0)
        .animation(.easeOut(duration: 0.3), value: thumb.isVisible)
        .allowsHitTesting(false)
    }

    /// The screen's left edge, from where its top edge leaves the display,
    /// round the top-left corner, down, and round the bottom-left corner.
    /// Circular corners stand in for the screen's continuous ones, which
    /// differ by a point or so, well inside the blur.
    private static func seam(in rect: CGRect, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
                    radius: radius)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
                    radius: radius)
        return path
    }
}
