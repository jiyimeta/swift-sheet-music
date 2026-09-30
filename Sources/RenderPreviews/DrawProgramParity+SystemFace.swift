#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicBridgeCore

    /// Keeping text drawn in the platform system face out of the cross-platform (Windows) comparison.
    ///
    /// The pages come from the Apple provider, so notation labels are `.text` in `DrawProgram.FontID.system` — SF on
    /// the Mac, Segoe UI on Windows. Different fonts by design: diffing them measures the fonts, not the renderer, and
    /// it took the Windows-vs-walk share from 0.007% to 0.639%. Where Windows puts those labels is checked elsewhere
    /// (a Windows-only anchor test), so here they are taken out of both comparisons:
    ///
    /// - against the walk, by exporting a page without them (`portableCommands`) and diffing the Windows drawing of it
    ///   against the walk of that same page (`<name>-drawprogram-portable.png`);
    /// - against the Apple renderer, which cannot be given a different page, by whiting out the pixels the system-face
    ///   text covers (`systemFaceMask`, written as `<name>-systemmask.png`) in both images before the diff.
    @available(macOS 15.0, *)
    extension DrawProgramParity {
        /// How far the system-face mask reaches past SF's ink, in pixels (4 pt at the probe's 2x): the margin for
        /// Segoe UI's ink, which sits off SF's by the two faces' advance and height differences. Square rather than a
        /// disk: it is separable, and the corners it adds are only more exclusion. A chosen margin, not a measured one
        /// — widen it if `<name>-systemmask.png` shows the Windows label ink reaching past the blue.
        static let systemMaskRadius = 8

        /// `commands` with every `.text` drawn in the system face removed. Everything else stays, `setTextStyle`
        /// included: a style opcode with no text after it draws nothing.
        static func portableCommands(_ commands: [DrawCommand]) -> [DrawCommand] {
            commands.filter { command in
                if case let .text(_, _, _, _, fontId) = command { return fontId != .system }
                return true
            }
        }

        /// Writes what the Windows renderer draws from — the portable page as `<name>-page.bin` and the canvas the
        /// walk drew with as `<name>-page.txt` ("widthPx heightPx pxPerMM offsetX offsetY") — and the walk of that
        /// same page on that same canvas as `<name>-drawprogram-portable.png`, the like-for-like reference for it.
        static func exportPortablePage(
            _ page: EncodablePage, name: String, outDir: URL,
            widthPx: Int, heightPx: Int, pxPerMM: CGFloat, offsetPx: CGPoint,
        ) throws {
            let portable = EncodablePage(
                widthMM: page.widthMM, heightMM: page.heightMM, commands: portableCommands(page.commands),
            )
            try DrawProgramCodec.encode(pages: [portable])
                .write(to: outDir.appendingPathComponent("\(name)-page.bin"))
            try "\(widthPx) \(heightPx) \(Double(pxPerMM)) \(Double(offsetPx.x)) \(Double(offsetPx.y))\n"
                .write(to: outDir.appendingPathComponent("\(name)-page.txt"), atomically: true, encoding: .utf8)
            let walk = try DrawProgramCGRenderer.render(
                portable.commands, widthPx: widthPx, heightPx: heightPx, pxPerMM: pxPerMM, offsetPx: offsetPx,
            )
            try writePNG(walk, to: outDir.appendingPathComponent("\(name)-drawprogram-portable.png"))
        }

        struct SystemFaceMask {
            /// One flag per pixel, row-major, in the walks' (and so the Apple render's) coordinate space.
            let bits: [Bool]
            let count: Int
            /// For inspection: the full walk faded to gray, the masked area in blue with its ink solid.
            let image: CGImage
        }

        /// The system-face text's ink: every pixel where the full walk and the portable walk differ at all, dilated
        /// by `systemMaskRadius`. Exact inequality rather than the diff threshold: the two are the same rasterizer
        /// over the same commands bar the removed text, so every other pixel is bit-identical, and a threshold would
        /// only drop the text's faint anti-aliased fringe — which differs between fonts as much as the stems do.
        static func systemFaceMask(full: CGImage, portable: CGImage) throws -> SystemFaceMask {
            guard full.width == portable.width, full.height == portable.height else { throw RenderError.zeroSize }
            let width = full.width
            let height = full.height
            let fullBytes = try BitmapDiff.rgba(of: full)
            let portableBytes = try BitmapDiff.rgba(of: portable)
            var ink = [Bool](repeating: false, count: width * height)
            for index in ink.indices {
                let offset = index * 4
                ink[index] = fullBytes[offset] != portableBytes[offset]
                    || fullBytes[offset + 1] != portableBytes[offset + 1]
                    || fullBytes[offset + 2] != portableBytes[offset + 2]
            }
            let bits = dilate(ink, width: width, height: height, radius: systemMaskRadius)

            var out = [UInt8](repeating: 255, count: width * height * 4)
            var count = 0
            for index in bits.indices {
                let offset = index * 4
                let value = Int(fullBytes[offset])
                if bits[index] {
                    count += 1
                    out[offset] = UInt8(value / 2)
                    out[offset + 1] = UInt8(value * 3 / 4)
                } else {
                    let faded = UInt8(255 - (255 - value) / 4)
                    out[offset] = faded
                    out[offset + 1] = faded
                    out[offset + 2] = faded
                }
            }
            return try SystemFaceMask(bits: bits, count: count, image: image(rgba: out, width: width, height: height))
        }

        /// Square dilation by `radius`, as two separable passes: every set pixel sets its row neighbours, then every
        /// pixel set by that sets its column neighbours.
        static func dilate(_ bits: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
            var rows = [Bool](repeating: false, count: bits.count)
            for y in 0 ..< height {
                for x in 0 ..< width where bits[y * width + x] {
                    for nx in max(0, x - radius) ... min(width - 1, x + radius) {
                        rows[y * width + nx] = true
                    }
                }
            }
            var out = [Bool](repeating: false, count: bits.count)
            for y in 0 ..< height {
                for x in 0 ..< width where rows[y * width + x] {
                    for ny in max(0, y - radius) ... min(height - 1, y + radius) {
                        out[ny * width + x] = true
                    }
                }
            }
            return out
        }

        /// `image` with every pixel `mask` sets painted opaque white. The mask is in `image`'s own coordinate space —
        /// the Apple render, the walks and the Windows render share one canvas by construction — and is applied
        /// before `BitmapDiff.compare`, so its best-shift search sees the masked images too.
        static func whitened(_ image: CGImage, mask: [Bool]) throws -> CGImage {
            guard mask.count == image.width * image.height else { throw RenderError.zeroSize }
            var bytes = try BitmapDiff.rgba(of: image)
            for index in mask.indices where mask[index] {
                let offset = index * 4
                for channel in 0 ..< 4 {
                    bytes[offset + channel] = 255
                }
            }
            return try Self.image(rgba: bytes, width: image.width, height: image.height)
        }

        /// A CGImage over premultiplied-RGBA bytes, the layout `BitmapDiff.rgba(of:)` reads into.
        static func image(rgba bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
            guard let provider = CGDataProvider(data: Data(bytes) as CFData), let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
            ) else { throw RenderError.makeImageFailed }
            return image
        }
    }
#endif
