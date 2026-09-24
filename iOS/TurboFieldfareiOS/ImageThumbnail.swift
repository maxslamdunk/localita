import ImageIO
import SwiftUI
import TurboFieldfareAppCore

/// A small square preview of an attached or stored image.
///
/// Decoded through ImageIO's thumbnail path at the size drawn, off the main
/// actor. `UIImage(contentsOfFile:)` would decode a 12 MP photo in full, about
/// 48 MB each, on a phone the model already holds near its memory ceiling.
struct ImageThumbnail: View {
    let image: ChatImage
    var side: CGFloat = 64

    @Environment(\.displayScale) private var displayScale
    @State private var decoded: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemFill)
            if let decoded {
                Image(uiImage: decoded)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(.rect(cornerRadius: 10))
        .accessibilityLabel(image.displayName)
        .task(id: image.id) {
            let url = image.fileURL
            let pixels = Int(side * displayScale)
            decoded = await Task.detached(priority: .utility) {
                Self.downsample(url, maxPixels: pixels)
            }.value
        }
    }

    private static func downsample(_ url: URL, maxPixels: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
