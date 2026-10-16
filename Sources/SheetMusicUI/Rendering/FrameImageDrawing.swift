import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import SheetMusicLayout
import SwiftUI

/// The pictures of a box (`LayoutFrameImage`, already sized and placed by the layout): an image layer each on screen,
/// and drawn into a `GraphicsContext` for the PDF. Both read the bytes through `FrameImageCache`, so a picture is
/// decoded once however often it is drawn. A picture ImageIO cannot read draws nothing.
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
/// read by ImageIO once. Bounded: past `limit` distinct pictures it starts over. `@unchecked Sendable` because its one
/// piece of mutable state is only touched under `lock`.
final class FrameImageCache: @unchecked Sendable {
    static let shared = FrameImageCache()

    private let lock = NSLock()
    private var decoded: [Data: CGImage] = [:]
    private let limit = 64

    /// `data` decoded by ImageIO, or `nil` when it cannot read it (not remembered, so such a file costs a retry).
    func image(for data: Data) -> CGImage? {
        if let known = lock.withLock({ decoded[data] }) { return known }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        lock.withLock {
            if decoded.count >= limit { decoded.removeAll() }
            decoded[data] = image
        }
        return image
    }
}
