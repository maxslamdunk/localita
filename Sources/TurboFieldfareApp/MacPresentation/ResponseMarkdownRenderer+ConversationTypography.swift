import Foundation
import TurboFieldfareRichText

extension ResponseMarkdownRenderer {
    /// The Mac's renderer at the user's text size: `compact`, scaled.
    ///
    /// The renderer lives in the platform-neutral RichText target and knows
    /// only `ResponseTypography`; `ConversationTypography` is AppKit-side, so
    /// the mapping between them lives here.
    public init(
        typography: ConversationTypography,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        typesetter: any MathTypesetting = SwiftMathTypesetter()
    ) {
        self = ResponseMarkdownRenderer(environment: environment, typesetter: typesetter)
            .setting(.compact.scaled(by: typography.scale))
    }
}
