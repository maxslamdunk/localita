import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The handful of text types that are spelled differently on the two platforms.
///
/// Everything else the renderer touches — `NSAttributedString`, `NSParagraphStyle`,
/// `NSTextAttachment`, `NSTextAlignment`, `NSTextTab`, `NSUnderlineStyle` — is
/// already common to UIKit and AppKit, so this file is deliberately short. It
/// exists so `ResponseMarkdownRenderer` reads the same on both platforms rather
/// than carrying `#if` at every use site.
///
/// The one thing with no iOS counterpart at all is `NSTextTable`, which the Mac
/// uses to box a code block and to rule a table. That is not shimmed here: a
/// fake would be worse than its absence. See `codeAttributes` and
/// `tableCellStyle`, which fence it off, and the iOS transcript, which draws
/// both with SwiftUI instead.
#if canImport(UIKit)
public typealias PlatformFont = UIFont
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
public typealias PlatformFont = NSFont
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
#endif

/// Semantic colours. The values agree across platforms; only the spellings
/// differ, and AppKit suffixes most of them with `Color`.
extension PlatformColor {
    public static var transcriptLabel: PlatformColor {
        #if canImport(UIKit)
        .label
        #else
        .labelColor
        #endif
    }

    public static var transcriptSecondaryLabel: PlatformColor {
        #if canImport(UIKit)
        .secondaryLabel
        #else
        .secondaryLabelColor
        #endif
    }

    public static var transcriptLink: PlatformColor {
        #if canImport(UIKit)
        .link
        #else
        .linkColor
        #endif
    }

    public static var transcriptSeparator: PlatformColor {
        #if canImport(UIKit)
        .separator
        #else
        .separatorColor
        #endif
    }

    /// The wash behind an inline code span and a fenced block. Spelled the same
    /// on both platforms, and named here only so call sites stay uniform.
    public static var transcriptFill: PlatformColor { .quaternarySystemFill }
}

extension PlatformFont {
    /// AppKit's `withSymbolicTraits` returns a descriptor and UIKit's returns an
    /// optional, and the trait itself is spelled `.italic` against `.traitItalic`
    /// — so the italic derivation cannot be written once without this.
    ///
    /// Falls back to the upright face rather than failing: a missing italic is a
    /// styling loss, and dropping the run would be a content loss.
    /// The serif design of a system font (New York), keeping its weight.
    /// Falls back to the font as given, for the same reason as `italicized`.
    public static func serif(_ font: PlatformFont, size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        guard let descriptor = font.fontDescriptor.withDesign(.serif) else { return font }
        return UIFont(descriptor: descriptor, size: size)
        #else
        guard let descriptor = font.fontDescriptor.withDesign(.serif) else { return font }
        return NSFont(descriptor: descriptor, size: size) ?? font
        #endif
    }

    public static func italicized(_ font: PlatformFont, size: CGFloat) -> PlatformFont {
        #if canImport(UIKit)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) else {
            return font
        }
        return UIFont(descriptor: descriptor, size: size)
        #else
        let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? font
        #endif
    }
}

extension PlatformImage {
    /// A private copy carrying its own accessibility text.
    ///
    /// The typesetter memoises by latex, size and tint, so two spans written
    /// with different delimiters share one image — and setting the description
    /// on the shared instance let the second span's source overwrite the first
    /// for both of them. Each attachment takes its own handle instead.
    public func describingMath(_ source: String) -> PlatformImage {
        #if canImport(UIKit)
        // `UIImage` is immutable and `copy()` may return the same instance, so
        // a genuinely separate object is built from the backing image.
        let copy = cgImage.map {
            UIImage(cgImage: $0, scale: scale, orientation: imageOrientation)
        } ?? self
        copy.accessibilityLabel = source
        return copy
        #else
        let copy = self.copy() as? NSImage ?? self
        copy.accessibilityDescription = source
        return copy
        #endif
    }
}
