import SwiftUI
import UIKit

/// A panel that slides in from the left and pushes the main screen aside.
///
/// It opens with a rightward drag anywhere on the screen, or with the menu
/// button, and closes with a leftward drag anywhere, a tap on the part of the
/// main screen still showing, or the VoiceOver escape gesture. The drags follow
/// the finger and settle on release, open or shut, by where a flick would
/// carry them.
///
/// The drags are UIKit recognizers rather than a SwiftUI `DragGesture`, because
/// they have to decide, before they begin, whether a movement is theirs. Each
/// begins only for a mostly horizontal movement in its own direction, so the
/// transcript and the chat list still scroll up and down. A rightward drag
/// that starts on a wide table or code block which is scrolled away from its
/// left edge scrolls that back instead of opening the panel.
///
/// Every open and close animates the whole layout in one transaction. Setting
/// `isOpen` without one moved the screen at once while the glass menu button
/// animated to its new place on its own, so the two came apart.
struct SideDrawer<Main: View, Drawer: View>: View {
    @Binding var isOpen: Bool
    @ViewBuilder var main: Main
    @ViewBuilder var drawer: Drawer

    /// How far the main screen is pushed while a finger is down. `nil` when
    /// no drag is in progress, and the position follows `isOpen`.
    @State private var dragOffset: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            // Leaves about a quarter of the chat screen showing on a phone.
            let width = min(geometry.size.width * 0.76, 380)
            let offset = dragOffset ?? (isOpen ? width : 0)
            let progress = width > 0 ? offset / width : 0

            ZStack(alignment: .leading) {
                drawer
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    // A little parallax: the panel travels less than the screen.
                    .offset(x: (offset - width) * 0.25)
                    // The panel lies under the chat screen, in its shade until
                    // it is uncovered, and brightens as the screen slides off it.
                    .overlay {
                        Color.black
                            .opacity(0.2 * (1 - progress))
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                    .accessibilityHidden(!isOpen)

                main
                    .frame(width: geometry.size.width)
                    // Catches the tap that closes the panel. Clear, so the chat
                    // screen keeps its own colours while it is pushed aside.
                    // Always present rather than inserted with the drag, so it
                    // cannot come apart from the screen as it slides.
                    .overlay {
                        Color.clear
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .allowsHitTesting(offset > 0)
                            .onTapGesture { settle(open: false) }
                            .accessibilityHidden(offset == 0)
                            .accessibilityLabel("Close chats")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { settle(open: false) }
                    }
                    // Rounded like the display. Shut, the corners sit exactly
                    // on the display's own, so they only show once it slides.
                    .mask { screenShape.ignoresSafeArea() }
                    // The shadow belongs to the screen's edge, so it is drawn
                    // by a plain shape behind it. A `.shadow` on the screen
                    // itself shadows every piece of text and every button in it.
                    .background {
                        screenShape
                            .fill(Color(uiColor: .systemBackground))
                            .shadow(color: .black.opacity(0.18 * progress), radius: 20)
                            .ignoresSafeArea()
                    }
                    .offset(x: offset)
                    .accessibilityHidden(isOpen)
                    .gesture(HorizontalPan(direction: .right,
                                           isEnabled: !isOpen) { translation, velocity in
                        drag(to: translation, velocity: velocity,
                             from: 0, width: width)
                    })
            }
            .gesture(HorizontalPan(direction: .left,
                                   isEnabled: isOpen) { translation, velocity in
                drag(to: translation, velocity: velocity,
                     from: width, width: width)
            })
            .accessibilityAction(.escape) {
                if isOpen { settle(open: false) }
            }
            // For opens and closes that come from a button rather than a drag.
            // A drag's release already animates in `settle`.
            .animation(Self.animation, value: isOpen)
        }
        .onChange(of: isOpen) { _, open in
            if open { dismissKeyboard() }
        }
    }

    /// `velocity` is nil while the finger is down and set on release.
    private func drag(to translation: CGFloat, velocity: CGFloat?,
                      from start: CGFloat, width: CGFloat) {
        let position = min(max(start + translation, 0), width)
        guard let velocity else {
            if dragOffset == nil { dismissKeyboard() }
            dragOffset = position
            return
        }
        // Where a flick would carry the panel, so a quick short swipe counts.
        let projected = position + velocity * 0.2
        settle(open: projected > width / 2)
    }

    private static var animation: Animation { .snappy(duration: 0.3) }

    private var screenShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: displayCornerRadius, style: .continuous)
    }

    private func settle(open: Bool) {
        withAnimation(Self.animation) {
            isOpen = open
            dragOffset = nil
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}

/// The radius of the display's own corners. There is no public API for it,
/// so it is read from UIKit's private key, and falls back to square corners if
/// that ever disappears. `ConcentricRectangle`, the public route, drew square
/// corners here.
@MainActor
private let displayCornerRadius: CGFloat = {
    let screen = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.screen }
        .first
    return (screen?.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 0
}()

/// Reports a horizontal pan: the translation while it moves, then the
/// translation and velocity once it ends. A cancelled pan reports a zero
/// translation and velocity, which settles the panel back where it was.
private typealias PanHandler = (_ translation: CGFloat, _ velocity: CGFloat?) -> Void

private func report(_ recognizer: UIPanGestureRecognizer, to handler: PanHandler) {
    let view = recognizer.view
    let translation = recognizer.translation(in: view).x
    switch recognizer.state {
    case .began, .changed:
        handler(translation, nil)
    case .ended:
        handler(translation, recognizer.velocity(in: view).x)
    case .cancelled, .failed:
        handler(0, 0)
    default:
        break
    }
}

/// A pan that begins only when it moves mostly sideways in `direction`, and
/// that lets a scroll view under it keep its own gesture.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    enum Direction { case left, right }

    let direction: Direction
    let isEnabled: Bool
    let onPan: PanHandler

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer,
                                   context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.direction = direction
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer,
                                         context: Context) {
        report(recognizer, to: onPan)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var direction = Direction.right

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            let sideways = abs(velocity.x) > abs(velocity.y)
            switch direction {
            case .left:
                return sideways && velocity.x < 0
            case .right:
                return sideways && velocity.x > 0
                    && !startsInScrolledContent(pan, in: view)
            }
        }

        /// Whether the drag started on something that scrolls sideways and is
        /// not at its left edge, such as a wide table the reader scrolled.
        /// Dragging right there should scroll it back, not open the panel.
        private func startsInScrolledContent(_ pan: UIPanGestureRecognizer,
                                             in view: UIView) -> Bool {
            var candidate = view.hitTest(pan.location(in: view), with: nil)
            while let current = candidate, current !== view {
                if let scroll = current as? UIScrollView,
                   scroll.contentSize.width > scroll.bounds.width + 1,
                   scroll.contentOffset.x > -scroll.adjustedContentInset.left + 1 {
                    return true
                }
                candidate = current.superview
            }
            return false
        }

        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        /// A scroll view waits to scroll until this pan has decided the drag is
        /// not a sideways one, which it does within its first few points. Both
        /// ran at once before, so a slightly diagonal drag moved the panel and
        /// scrolled the chat or the list under it, and the two jiggled.
        func gestureRecognizer(
            _ recognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            recognizer.isEnabled
                && (other.view as? UIScrollView)?.panGestureRecognizer === other
        }
    }
}
