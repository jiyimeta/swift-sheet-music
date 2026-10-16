import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import SheetMusicLayout
import SwiftUI

/// The pictures of a box (`LayoutFrameImage`, already sized and placed by the layout): an image layer each on screen,
/// and drawn into a `GraphicsContext` for the PDF. Both read the bytes through `FrameImageCache`, so a picture is
/// decoded once while it stays cached, however often it is drawn. A picture ImageIO cannot read draws nothing.
@available(macOS 15.0, *)
enum FrameImageDrawing {
    /// One layer per picture, holding the decoded image stretched to its rect (`contentsGravity = .resize`: the layout
    /// already chose the size) and flipped like the texts beside it: `rect` is y down from the top of a block `height`
    /// tall.
    static func layers(for images: [LayoutFrameImage], height: CGFloat) -> [CALayer] {
        images.compactMap { image in
            guard let decoded = FrameImageCache.shared.image(for: image.data) else { return nil }
            let layer = CALayer()
            layer.contents = decoded
            layer.contentsGravity = .resize
            layer.frame = platformRect(image.rect, height: height)
            return layer
        }
    }

    /// `rect`, y down from the top of a block `height` tall, in the host layer's native orientation: AppKit's layers
    /// are Y-up, so the rect is flipped about the block's height (as `ScoreLayerBuilder.flipForPlatform` flips the
    /// texts' paths); UIKit's are Y-down, so it passes through.
    static func platformRect(_ rect: CGRect, height: CGFloat) -> CGRect {
        #if os(macOS)
            return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        #else
            return rect
        #endif
    }

    /// Each picture filling its rect moved by `origin`, in a y-down `GraphicsContext` such as a PDF page's canvas.
    static func draw(_ images: [LayoutFrameImage], into context: inout GraphicsContext, origin: CGPoint) {
        for image in images {
            guard let decoded = FrameImageCache.shared.image(for: image.data) else { continue }
            context.draw(
                Image(decorative: decoded, scale: 1),
                in: image.rect.offsetBy(dx: origin.x, dy: origin.y),
            )
        }
    }
}

/// Decoded pictures keyed by their bytes, so a picture redrawn on every view update, or repeated on several pages, is
/// read by ImageIO once while it stays cached. Bounded twice: no picture decodes with a side longer than
/// `maxPixelSize`, and the cache evicts past `totalCostLimit` bytes of pixels. Bytes ImageIO cannot read are
/// remembered too, so such a file is not retried on every draw. Its one piece of state is an `NSCache`, which
/// synchronizes itself; that is what makes the `@unchecked Sendable` sound. Two threads missing the same picture at
/// once may both decode it, and the second store wins — the same image either way.
final class FrameImageCache: @unchecked Sendable {
    static let shared = FrameImageCache()

    /// The longest side, in pixels, a picture is decoded at: a picture a page wide on a 2× screen, or about 250 dpi
    /// across an A4 page in a PDF. 2048 × 2048 RGBA is 16 MB.
    static let maxPixelSize = 2048
    /// The pixel bytes the cache holds before it evicts: six pictures at `maxPixelSize`, many more at score sizes.
    static let totalCostLimit = 96 * 1024 * 1024

    /// One decode: the image, or `nil` for bytes ImageIO cannot read.
    private final class Entry {
        let image: CGImage?

        init(_ image: CGImage?) {
            self.image = image
        }
    }

    private let decoded: NSCache<NSData, Entry> = {
        let cache = NSCache<NSData, Entry>()
        cache.totalCostLimit = FrameImageCache.totalCostLimit
        return cache
    }()

    /// `data` decoded by ImageIO at no more than `maxPixelSize` on its long side, or `nil` when it cannot read it.
    func image(for data: Data) -> CGImage? {
        let key = data as NSData
        if let known = decoded.object(forKey: key) { return known.image }
        let image = Self.decode(data)
        decoded.setObject(Entry(image), forKey: key, cost: image.map { $0.bytesPerRow * $0.height } ?? 1)
        return image
    }

    /// The picture through ImageIO's thumbnail path, which decodes at the reduced size directly instead of decoding
    /// the full image and scaling it. Always from the image itself (never a JPEG's embedded preview), decoded now
    /// rather than on first draw, and with no EXIF orientation applied: the layout sized the rect from the stored
    /// pixel size (`ImageSniffer`), and Android's `BitmapFactory` and the PDF writer's embedded JPEG do not rotate
    /// either, so every renderer draws the same pixels into it.
    private static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
