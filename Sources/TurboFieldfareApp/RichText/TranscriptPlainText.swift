import Foundation

/// The transcript's text projection. A typeset equation occupies one
/// object-replacement character and carries its LaTeX on the attachment, so
/// anything that reads the string back — a pasteboard flavour, an
/// accessibility client, the renderer's own `plainText` — has to put the
/// source back or hand out U+FFFC where the equation was.
///
/// Shared rather than Mac-only because `ResponseMarkdownRenderer.plainText`
/// calls it: leaving it beside the `NSTextView` would have pointed the shared
/// target back at the AppKit one.
public enum TranscriptPlainText {
    public static func string(of attributed: NSAttributedString) -> String {
        let characters = attributed.string as NSString
        var text = ""
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []) { value, range, _ in
            if let attachment = value as? MathAttachment {
                text += attachment.latexSource
            } else {
                text += characters.substring(with: range)
            }
        }
        return text
    }

    /// The same projection kept as an attributed string: each typeset equation
    /// becomes its LaTeX carrying the run's own attributes, and every other
    /// attachment — an image in the prompt strip — is left where it is.
    ///
    /// Every rich flavour is serialised from this copy. AppKit rasterises an
    /// attachment that has no file wrapper, so Cmd-C on a fifty-equation answer
    /// wrote a 12.3 MB RTFD of fifty TIFFs and logged a hundred
    /// `CGImageDestinationFinalize` lines, while the RTF flavour, which cannot
    /// carry attachments at all, dropped every equation on the floor.
    public static func replacingMath(in attributed: NSAttributedString) -> NSAttributedString {
        let replaced = NSMutableAttributedString()
        attributed.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: attributed.length),
            options: []) { value, range, _ in
            guard let attachment = value as? MathAttachment else {
                replaced.append(attributed.attributedSubstring(from: range))
                return
            }
            var attributes = attributed.attributes(at: range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            replaced.append(NSAttributedString(
                string: attachment.latexSource,
                attributes: attributes))
        }
        return replaced
    }
}
