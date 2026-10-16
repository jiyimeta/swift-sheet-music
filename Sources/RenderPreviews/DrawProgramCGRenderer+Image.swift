#if os(macOS)
    import CoreGraphics
    import Foundation
    import ImageIO

    @available(macOS 15.0, *)
    extension DrawProgramCGRenderer {
        /// The pictures of one render, decoded once per distinct file: a picture drawn on a page twice, or a page's
        /// every picture, is read by `ImageIO` the first time its bytes come up. A file `ImageIO` cannot read is
        /// remembered as unreadable.
        final class ImageCache {
            private var decoded: [Data: CGImage?] = [:]

            func image(for data: Data) -> CGImage? {
                if let known = decoded[data] { return known }
                let image = CGImageSourceCreateWithData(data as CFData, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
                decoded[data] = .some(image)
                return image
            }
        }

        /// `drawImage`: the picture filling `rect` (pixels, y down — the context's space). `CGContext.draw` puts an
        /// image upright in a y-up space, so the rectangle is flipped about its own bottom edge first, the way a glyph
        /// outline is flipped back in `fillGlyph`.
        static func drawImage(_ data: Data, in rect: CGRect, ctx: CGContext, cache: ImageCache) {
            guard let image = cache.image(for: data) else { return }
            ctx.saveGState()
            ctx.interpolationQuality = .high
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
            ctx.restoreGState()
        }
    }

#endif
