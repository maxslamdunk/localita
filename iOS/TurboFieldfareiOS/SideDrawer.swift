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
/// The slide is UIKit's, not SwiftUI's. The two screens stay SwiftUI inside,
/// but each is hosted in a view that UIKit moves: a drag moves those views
/// directly, and the settle is a Core Animation spring that runs outside the
/// app. As a SwiftUI offset, every frame of a slide laid out both screens
/// again on the main thread, which took most of a 120 Hz frame and dropped
/// some of them.
///
/// The drag is a UIKit recognizer, which has to decide, before it begins,
/// whether a movement is its own. It begins only for a mostly horizontal
/// movement in the direction that opens or shuts the panel, so the transcript
/// and the chat list still scroll up and down. A rightward drag that starts on
/// a wide table or code block which is scrolled away from its left edge
/// scrolls that back instead of opening the panel.
struct SideDrawer<Main: View, Drawer: View>: View {
    @Binding var isOpen: Bool
    /// The panel's scroll thumb, drawn on the seam. `nil` draws none.
    var seamThumb: SeamThumb? = nil
    @ViewBuilder var main: Main
    @ViewBuilder var drawer: Drawer

    var body: some View {
        // The whole screen, so each hosted screen takes its own safe areas,
        // and the keyboard's, from the window.
        DrawerHost(isOpen: $isOpen, seamThumb: seamThumb,
                   main: AnyView(main), drawer: AnyView(drawer))
            .ignoresSafeArea()
    }
}

private struct DrawerHost: UIViewControllerRepresentable {
    @Binding var isOpen: Bool
    let seamThumb: SeamThumb?
    let main: AnyView
    let drawer: AnyView

    func makeUIViewController(context: Context) -> DrawerController {
        let controller = DrawerController(main: main, drawer: drawer,
                                          seamThumb: seamThumb, isOpen: isOpen)
        controller.onSettle = { [binding = $isOpen] open in binding.wrappedValue = open }
        return controller
    }

    func updateUIViewController(_ controller: DrawerController, context: Context) {
        controller.onSettle = { [binding = $isOpen] open in binding.wrappedValue = open }
        controller.update(main: main, drawer: drawer, isOpen: isOpen)
    }
}

private final class DrawerController: UIViewController, UIGestureRecognizerDelegate {
    /// Told when a drag, a tap or the escape gesture opens or shuts the panel.
    var onSettle: (Bool) -> Void = { _ in }

    private let mainHost: UIHostingController<AnyView>
    private let drawerHost: UIHostingController<AnyView>
    private let seamHost: UIHostingController<SeamDecoration>
    /// Moves with the main screen and rounds its corners like the display's.
    private let screen = UIView()
    /// Moves with the panel.
    private let panel = UIView()
    /// The panel lies under the chat screen, in its shade until it is
    /// uncovered, and brightens as the screen slides off it.
    private let shade = UIView()
    /// Catches the tap that closes the panel. Clear, so the chat screen keeps
    /// its own colours while it is pushed aside.
    private let closeCatcher = CloseCatcher()
    private let frameRate = DragFrameRate()
    private let haptics = UIImpactFeedbackGenerator(style: .rigid)
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))

    /// Where the panel is headed: the state it is in, or animating to.
    private var isOpen: Bool
    /// How far the main screen is pushed.
    private var offset: CGFloat = 0
    /// Where a drag in progress started. `nil` when there is none.
    private var dragStart: CGFloat?
    private var laidOutSize = CGSize.zero
    /// Counts settles, so only the latest one lets the frame rate go.
    private var settles = 0
    /// Whether a keyboard is up, which with the panel open is its search's.
    private var isKeyboardShown = false
    private var keyboardObservers: [NSObjectProtocol] = []

    /// Room around the screen for the glow, the shadow and the thumb, which
    /// reach past its edge.
    private static let seamOutset: CGFloat = 60

    init(main: AnyView, drawer: AnyView, seamThumb: SeamThumb?, isOpen: Bool) {
        mainHost = UIHostingController(rootView: main)
        drawerHost = UIHostingController(rootView: drawer)
        seamHost = UIHostingController(
            rootView: SeamDecoration(seamThumb: seamThumb, outset: Self.seamOutset))
        self.isOpen = isOpen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = DrawerRootView()
        root.onEscape = { [weak self] in
            guard let self, isOpen else { return false }
            settle(open: false, velocity: 0)
            return true
        }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        for host in [drawerHost, seamHost, mainHost] as [UIViewController] {
            addChild(host)
        }
        // The panel stays put under the keyboard: its search is the only
        // thing in it that brings one up, and scrolling the list puts it
        // away. Following it lifted New Chat, Settings and their fade.
        drawerHost.safeAreaRegions = .container
        mainHost.safeAreaRegions = keyboardRegions(isOpen: isOpen)
        panel.addSubview(drawerHost.view)
        shade.backgroundColor = .black
        shade.isUserInteractionEnabled = false
        panel.addSubview(shade)
        view.addSubview(panel)

        // Behind the screen, so only the parts past its edge show. A shadow on
        // the screen itself would shadow every piece of text and every button.
        seamHost.view.backgroundColor = .clear
        seamHost.view.isUserInteractionEnabled = false
        seamHost.safeAreaRegions = []
        view.addSubview(seamHost.view)

        // Rounded like the display. Shut, the corners sit exactly on the
        // display's own, so they only show once it slides.
        screen.layer.cornerRadius = displayCornerRadius
        screen.layer.cornerCurve = .continuous
        screen.clipsToBounds = true
        screen.addSubview(mainHost.view)
        closeCatcher.onActivate = { [weak self] in self?.settle(open: false, velocity: 0) }
        closeCatcher.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTap)))
        screen.addSubview(closeCatcher)
        view.addSubview(screen)

        for host in [drawerHost, seamHost, mainHost] as [UIViewController] {
            host.didMove(toParent: self)
        }

        pan.delegate = self
        view.addGestureRecognizer(pan)
        let center = NotificationCenter.default
        keyboardObservers = [
            center.addObserver(forName: UIResponder.keyboardWillShowNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isKeyboardShown = true }
            },
            center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isKeyboardShown = false }
            },
        ]
        haptics.prepare()
        updateInteraction()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size != laidOutSize else { return }
        laidOutSize = size
        // Frames are laid out untransformed, then moved again.
        for moving in [screen, panel, seamHost.view!] { moving.transform = .identity }
        let width = panelWidth
        screen.frame = view.bounds
        mainHost.view.frame = screen.bounds
        closeCatcher.frame = screen.bounds
        panel.frame = CGRect(x: 0, y: 0, width: width, height: size.height)
        drawerHost.view.frame = panel.bounds
        shade.frame = panel.bounds
        seamHost.view.frame = view.bounds.insetBy(dx: -Self.seamOutset, dy: -Self.seamOutset)
        if dragStart == nil { offset = isOpen ? width : 0 }
        place(offset)
    }

    func update(main: AnyView, drawer: AnyView, isOpen: Bool) {
        mainHost.rootView = main
        drawerHost.rootView = drawer
        // The menu button, or the list closing itself after opening a chat.
        if isOpen != self.isOpen, dragStart == nil {
            settle(open: isOpen, velocity: 0, notify: false)
        }
    }

    /// Leaves about a quarter of the chat screen showing on a phone.
    private var panelWidth: CGFloat { min(view.bounds.width * 0.76, 380) }

    /// Puts everything where `offset` puts it, in the current animation if
    /// there is one.
    private func place(_ offset: CGFloat) {
        let width = panelWidth
        let progress = width > 0 ? offset / width : 0
        screen.transform = CGAffineTransform(translationX: offset, y: 0)
        seamHost.view.transform = CGAffineTransform(translationX: offset, y: 0)
        // The glow, shadow and thumb are drawn at full strength and faded in
        // as the screen slides, which is what scaling each by `progress` did.
        seamHost.view.alpha = progress
        // A little parallax: the panel travels less than the screen.
        panel.transform = CGAffineTransform(translationX: (offset - width) * 0.25, y: 0)
        shade.alpha = 0.2 * (1 - progress)
    }

    // MARK: - Opening and shutting

    /// `velocity` carries a flick's speed into the spring, in points a second.
    private func settle(open: Bool, velocity: CGFloat, notify: Bool = true) {
        let target = open ? panelWidth : 0
        let changed = open != isOpen
        let distance = target - offset
        isOpen = open
        dragStart = nil
        offset = target
        updateInteraction()
        if changed {
            // A crisp click as the screen is let go and heads off on its own,
            // like a catch engaging. A drag released short of the midpoint
            // changes nothing and so does not click.
            haptics.impactOccurred(intensity: 0.6)
            // Either way, since the keyboard belongs to the side being left.
            dismissKeyboard()
            mainHost.safeAreaRegions = keyboardRegions(isOpen: open)
        }
        frameRate.hold()
        settles += 1
        let settle = settles
        // SwiftUI's `.snappy(duration: 0.3)`, as the slide was before.
        UIView.animate(springDuration: 0.3, bounce: 0.15,
                       initialSpringVelocity: abs(distance) > 1 ? velocity / distance : 0,
                       delay: 0, options: [.allowUserInteraction]) {
            self.place(target)
        } completion: { [weak self] _ in
            guard let self, settle == settles, dragStart == nil else { return }
            frameRate.release(after: 0)
        }
        if changed, notify { onSettle(open) }
    }

    private func updateInteraction() {
        closeCatcher.isUserInteractionEnabled = isOpen
        closeCatcher.isAccessibilityElement = isOpen
        drawerHost.view.accessibilityElementsHidden = !isOpen
        mainHost.view.accessibilityElementsHidden = isOpen
    }

    /// A tap on the strip of chat closes the panel, or with the search's
    /// keyboard up only puts the keyboard away: leaving the panel is the
    /// bigger step, and a tap meant for the keyboard should not take it.
    @objc private func handleTap() {
        if isKeyboardShown {
            dismissKeyboard()
        } else {
            settle(open: false, velocity: 0)
        }
    }

    // MARK: - Dragging

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view).x
        switch recognizer.state {
        case .began:
            beginDrag()
            moveDrag(to: translation)
        case .changed:
            moveDrag(to: translation)
        case .ended:
            endDrag(at: translation, velocity: recognizer.velocity(in: view).x)
        case .cancelled, .failed:
            // Back where it was.
            endDrag(at: 0, velocity: 0)
        default:
            break
        }
    }

    private func beginDrag() {
        // Caught mid-slide, the screen stays where it is on screen.
        if let shown = screen.layer.presentation() {
            offset = shown.affineTransform().tx
        }
        for moving in [screen, panel, shade, seamHost.view!] {
            moving.layer.removeAllAnimations()
        }
        place(offset)
        dragStart = offset
        dismissKeyboard()
        frameRate.hold()
    }

    private func moveDrag(to translation: CGFloat) {
        guard let dragStart else { return }
        offset = min(max(dragStart + translation, 0), panelWidth)
        place(offset)
    }

    private func endDrag(at translation: CGFloat, velocity: CGFloat) {
        moveDrag(to: translation)
        // Where a flick would carry the panel, so a quick short swipe counts.
        let projected = offset + velocity * 0.2
        settle(open: projected > panelWidth / 2, velocity: velocity)
    }

    /// The chat screen follows the keyboard only while it is in front. With
    /// the panel open, the keyboard is the panel's search, and the composer
    /// on the strip of chat still showing rose with it.
    private func keyboardRegions(isOpen: Bool) -> SafeAreaRegions {
        isOpen ? .container : .all
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan else { return true }
        let velocity = pan.velocity(in: view)
        let sideways = abs(velocity.x) > abs(velocity.y)
        if isOpen {
            return sideways && velocity.x < 0
        }
        return sideways && velocity.x > 0 && !startsInScrolledContent(pan)
    }

    /// Whether the drag started on something that scrolls sideways and is
    /// not at its left edge, such as a wide table the reader scrolled.
    /// Dragging right there should scroll it back, not open the panel.
    private func startsInScrolledContent(_ pan: UIPanGestureRecognizer) -> Bool {
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

    /// A scroll view waits to scroll until the drag has decided it is not a
    /// sideways one, which it does within its first few points. Both ran at
    /// once before, so a slightly diagonal drag moved the panel and scrolled
    /// the chat or the list under it, and the two jiggled.
    func gestureRecognizer(
        _ recognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        recognizer === pan && (other.view as? UIScrollView)?.panGestureRecognizer === other
    }
}

/// Answers the VoiceOver escape gesture.
private final class DrawerRootView: UIView {
    var onEscape: () -> Bool = { false }

    override func accessibilityPerformEscape() -> Bool { onEscape() }
}

/// The part of the chat screen left showing beside the open panel, which
/// shuts it when tapped.
private final class CloseCatcher: UIView {
    var onActivate: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        accessibilityLabel = "Close chats"
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityActivate() -> Bool {
        onActivate()
        return true
    }
}

/// What lies behind the main screen's edge, drawn at full strength: the
/// controller fades it in as the screen slides away.
///
/// A shadow cannot darken a black panel, so in dark mode it is inverted: a
/// glow, as if lit from under the screen. That glow is near `glowStrength`
/// from the seam out to about `glowReach` points, then rolls off over roughly
/// `glowSoftness` points either side of it, like a sigmoid. It is the screen's
/// shape grown by `glowReach` and blurred, so the blur's S-curve is centred
/// `glowReach` out instead of on the seam, where the screen would hide half
/// of it.
private struct SeamDecoration: View {
    let seamThumb: SeamThumb?
    let outset: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    private static var glowStrength: Double { 0.5 }
    private static var glowReach: CGFloat { 3.6 }
    private static var glowSoftness: CGFloat { 7.2 }

    var body: some View {
        let isDark = colorScheme == .dark
        ZStack {
            if isDark {
                RoundedRectangle(cornerRadius: displayCornerRadius + Self.glowReach,
                                 style: .continuous)
                    .fill(.white.opacity(Self.glowStrength))
                    .padding(-Self.glowReach)
                    .blur(radius: Self.glowSoftness)
            }
            RoundedRectangle(cornerRadius: displayCornerRadius, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(isDark ? 0 : 0.18), radius: 20)
            // Behind the screen's shape, like the glow, so only the part past
            // the seam shows.
            if let seamThumb {
                SeamThumbGlow(thumb: seamThumb,
                              cornerRadius: displayCornerRadius,
                              color: isDark ? .white : .black,
                              strength: isDark ? 1 : 0.35,
                              reach: Self.glowReach,
                              softness: Self.glowSoftness)
                    .zIndex(-1)
            }
        }
        .padding(outset)
    }
}

/// Keeps the display at up to 120 Hz while a finger drags the panel and while
/// it settles. On an iPhone the system otherwise ran a drag at 60 Hz: it
/// raises the rate for scrolling, but a view that simply follows a pan is not
/// one, so the panel moved half as smoothly as a scroll. A display link asking
/// for 120 Hz is what tells the system this motion needs it.
@MainActor
private final class DragFrameRate {
    private var link: CADisplayLink?
    private var pendingRelease: DispatchWorkItem?

    func hold() {
        pendingRelease?.cancel()
        pendingRelease = nil
        guard link == nil else { return }
        let link = CADisplayLink(target: Tick(), selector: #selector(Tick.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120,
                                                        preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func release(after delay: TimeInterval) {
        pendingRelease?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.link?.invalidate()
            self?.link = nil
        }
        pendingRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private final class Tick: NSObject {
        @objc func tick() {}
    }
}

/// The radius of the display's own corners. UIKit has it only under a private
/// key, which App Review can reject, and `ConcentricRectangle`, the public
/// route, drew square corners here. So it comes from a table keyed by the
/// screen's size in pixels, which no two radii share. The radii are what the
/// private key returned in the iOS 26.5 simulators, in points at the standard
/// zoom; the 11s and minis, not run, take Xcode's `DeviceCornerRadius`, which
/// agreed wherever both were read. Display Zoom shows fewer points on the
/// same glass, so the radius scales with the width in points. A size not in
/// the table is a phone newer than it, and gets the newest phones' radius.
@MainActor
private let displayCornerRadius: CGFloat = {
    guard let screen = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.screen })
        .first
    else { return 0 }
    let byPixels: [String: (radius: CGFloat, width: CGFloat)] = [
        "750x1334": (0, 375),           // SE (2nd, 3rd)
        "828x1792": (41.5, 414),        // 11
        "1125x2436": (39, 375),         // 11 Pro
        "1242x2688": (39, 414),         // 11 Pro Max
        "1080x2340": (44, 375),         // 12 mini, 13 mini
        "1170x2532": (47.33, 390),      // 12, 12 Pro, 13, 13 Pro, 14, 16e, 17e
        "1284x2778": (53.33, 428),      // 12 Pro Max, 13 Pro Max, 14 Plus
        "1179x2556": (55, 393),         // 14 Pro, 15, 15 Pro, 16
        "1290x2796": (55, 430),         // 14 Pro Max, 15 Plus, 15 Pro Max, 16 Plus
        "1206x2622": (62, 402),         // 16 Pro, 17, 17 Pro
        "1320x2868": (62, 440),         // 16 Pro Max, 17 Pro Max
        "1260x2736": (62, 420),         // Air
    ]
    let pixels = screen.nativeBounds.size
    let key = "\(Int(min(pixels.width, pixels.height)))x\(Int(max(pixels.width, pixels.height)))"
    guard let entry = byPixels[key] else { return 62 }
    return entry.radius * min(screen.bounds.width, screen.bounds.height) / entry.width
}()
