import SwiftUI
import TurboFieldfareAppCore
import TurboFieldfareAppPresentation
import TurboFieldfareRichText
import UIKit

/// One rendered block, hosted in a `UITextView`.
///
/// SwiftUI's own `Text` cannot draw this, for two independent reasons. It
/// ignores paragraph-level attributes entirely — head indent, tab stops, line
/// spacing — so a list would lose its hanging indent and a quote its bar, both
/// of which `ResponseMarkdownRenderer` expresses as paragraph style. And it
/// cannot draw an `NSTextAttachment`, which is precisely what a typeset
/// equation is. A text view honours both, so the renderer's output goes here
/// rather than through `AttributedString`.
///
/// Scrolling is off: the view reports its full height to SwiftUI and the
/// transcript's own `ScrollView` does the scrolling, so the two never fight for
/// the pan gesture and selection still works across a block.
struct MarkdownText: UIViewRepresentable {
    let attributed: NSAttributedString

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.isEditable = false
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        // The only links here are the renderer's own `.link` runs, which it has
        // already filtered to the schemes it is willing to open. Data detectors
        // would add destinations it never vetted.
        view.dataDetectorTypes = []
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        view.setContentHuggingPriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.quotingModel = context.environment.quotingModel
        // A streaming block hands over a new string every tick; an equal one is
        // a no-op worth skipping, since assigning resets the selection.
        guard view.attributedText != attributed else { return }
        view.attributedText = attributed
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.replacingUnspecifiedDimensions().width
        guard width > 0 else { return nil }
        let fitted = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }

    /// Adds "Ask about this" to the selection menu.
    ///
    /// Only a `UITextView` takes a custom item, so fenced code, which is a
    /// SwiftUI `Text`, keeps the plain menu. `TranscriptPlainText` because a
    /// typeset equation is a single placeholder character in the view's string.
    final class Coordinator: NSObject, UITextViewDelegate {
        var quotingModel: AppModel?

        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let quotingModel, range.length > 0 else { return nil }
            let selected = textView.attributedText.attributedSubstring(from: range)
            let ask = UIAction(title: "Ask about this",
                               image: UIImage(systemName: "text.quote")) { _ in
                quotingModel.quoteInComposer(TranscriptPlainText.string(of: selected))
            }
            return UIMenu(children: [ask] + suggestedActions)
        }
    }
}

extension EnvironmentValues {
    /// Where "Ask about this" sends a selection, or nil for text that does not
    /// offer it. Set on answers and left off reasoning. A reference rather than
    /// a closure, which would count as new on every streaming tick.
    var quotingModel: AppModel? {
        get { self[QuotingModelKey.self] }
        set { self[QuotingModelKey.self] = newValue }
    }

    private struct QuotingModelKey: EnvironmentKey {
        static let defaultValue: AppModel? = nil
    }
}

extension ResponseTypography {
    /// How replies read on the phone: New York at 17 pt, the iPhone's body
    /// size and the size of the user's own messages, with room between lines,
    /// paragraphs and list items. Chosen on the device after trying 14 and
    /// 16. It scales with the text-size setting, read when a renderer is made,
    /// which is at launch.
    static var phone: ResponseTypography {
        .reading(bodySize: UIFontMetrics(forTextStyle: .body).scaledValue(for: 17))
    }
}

/// Renders the blocks of a turn that is no longer streaming.
///
/// A frozen turn has no scan lineage to key against — `StreamingBlocks` owns
/// that, and only the live turn has one — so this memoises by the block's own
/// text. The hash costs the block on each lookup, which is affordable only
/// because a frozen turn's bytes never change: the entry is written once and
/// hit forever after. The live path must not use it, which is why
/// `StreamingBlocks` keys on the UTF-8 offset instead.
@MainActor
final class FrozenRenderCache {
    static let shared = FrozenRenderCache()

    private let renderer = ResponseMarkdownRenderer().setting(.phone)
    private var entries: [String: NSAttributedString] = [:]
    /// Insertion order, for the eviction below.
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 512) {
        self.limit = limit
    }

    /// Nothing more is arriving for this turn, so even a block whose fence the
    /// model never closed is final — and is rendered with math typeset, which is
    /// what the Mac's finalize pass does to a whole answer for the same reason.
    func rendered(_ text: String) -> NSAttributedString {
        if let hit = entries[text] { return hit }
        let drawn = renderer.render(text, typesetsMath: true).attributedString
        entries[text] = drawn
        order.append(text)
        if order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
        return drawn
    }
}
