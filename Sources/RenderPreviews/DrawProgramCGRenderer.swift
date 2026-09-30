#if os(macOS)
    import AppKit
    import CoreGraphics
    import CoreText
    import Foundation
    import SheetMusic
    import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicLayoutApple
    import SheetMusicUI

    /// A CoreGraphics interpreter of the draw-program stream — `canvas.ts`'s `drawCommandList`, in Swift, with
    /// the Apple renderer's font resolution. Coordinates arrive in document millimetres and are multiplied by
    /// `pxPerMM`; the context is flipped once so the walk stays Y-down like the stream, and glyph outlines are
    /// flipped back per glyph exactly as `StaffRenderer.smuflGlyphPath` does.
    @available(macOS 15.0, *)
    enum DrawProgramCGRenderer {
        /// Minimum stroke width in device pixels — the Kotlin renderer's `coerceAtLeast(1.5f)` and `canvas.ts`'s
        /// `MIN_STROKE_PX`. Kept here so this walk measures what those renderers ship, not an idealized version.
        static let minStrokePx: CGFloat = 1.5

        static func render(
            _ commands: [DrawCommand], widthPx: Int, heightPx: Int, pxPerMM: CGFloat, offsetPx: CGPoint,
        ) throws -> CGImage {
            guard widthPx > 0, heightPx > 0 else { throw RenderError.zeroSize }
            guard let ctx = CGContext(
                data: nil, width: widthPx, height: heightPx, bitsPerComponent: 8, bytesPerRow: widthPx * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else { throw RenderError.contextInitFailed }

            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

            // Y-down, like the stream: flip once, then offset by the margin.
            ctx.translateBy(x: 0, y: CGFloat(heightPx))
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: offsetPx.x, y: offsetPx.y)

            var walker = Walker(ctx: ctx, pxPerMM: pxPerMM)
            walker.applyColor()
            for command in commands {
                walker.paint(command)
            }
            walker.finish()

            guard let image = ctx.makeImage() else { throw RenderError.makeImageFailed }
            return image
        }

        private struct Walker {
            let ctx: CGContext
            let pxPerMM: CGFloat
            var argb: UInt32 = 0xFF00_0000
            var dashOn: CGFloat = 0
            var dashOff: CGFloat = 0
            var rotationOpen = false
            var textStyleFlags: UInt8 = DrawCommand.TextStyleFlag.none

            init(ctx: CGContext, pxPerMM: CGFloat) {
                self.ctx = ctx
                self.pxPerMM = pxPerMM
            }

            var color: CGColor {
                CGColor(
                    red: CGFloat((argb >> 16) & 0xFF) / 255,
                    green: CGFloat((argb >> 8) & 0xFF) / 255,
                    blue: CGFloat(argb & 0xFF) / 255,
                    alpha: CGFloat((argb >> 24) & 0xFF) / 255,
                )
            }

            func applyColor() {
                ctx.setFillColor(color)
                ctx.setStrokeColor(color)
            }

            func px(_ mm: Double) -> CGFloat {
                CGFloat(mm) * pxPerMM
            }

            var isBold: Bool {
                textStyleFlags & DrawCommand.TextStyleFlag.bold != 0
            }

            var isItalic: Bool {
                textStyleFlags & DrawCommand.TextStyleFlag.italic != 0
            }

            var isSemibold: Bool {
                textStyleFlags & DrawCommand.TextStyleFlag.semibold != 0
            }

            // swiftlint:disable:next cyclomatic_complexity function_body_length
            mutating func paint(_ command: DrawCommand) {
                switch command {
                case let .moveTo(x, y):
                    ctx.move(to: CGPoint(x: px(x), y: px(y)))
                case let .lineTo(x, y):
                    ctx.addLine(to: CGPoint(x: px(x), y: px(y)))
                case let .cubicTo(cx1, cy1, cx2, cy2, x, y):
                    ctx.addCurve(
                        to: CGPoint(x: px(x), y: px(y)),
                        control1: CGPoint(x: px(cx1), y: px(cy1)),
                        control2: CGPoint(x: px(cx2), y: px(cy2)),
                    )
                case let .stroke(width):
                    ctx.setLineWidth(max(px(width), DrawProgramCGRenderer.minStrokePx))
                    if dashOn > 0, dashOff > 0 {
                        ctx.setLineDash(phase: 0, lengths: [dashOn, dashOff])
                    } else {
                        ctx.setLineDash(phase: 0, lengths: [])
                    }
                    ctx.strokePath()
                case let .fillRect(x, y, w, h):
                    ctx.fill(CGRect(x: px(x), y: px(y), width: px(w), height: px(h)))
                case let .glyph(codepoint, x, y, size, fontId):
                    fillGlyph(codepoint: codepoint, at: CGPoint(x: px(x), y: px(y)), fontSize: px(size), fontId: fontId)
                case let .text(text, x, y, size, fontId):
                    fillText(
                        text, at: CGPoint(x: px(x), y: px(y)), fontSize: px(size), fontId: fontId, italic: isItalic,
                    )
                case .fillPath:
                    // Nonzero winding, closing each open subpath — what every reader of `fillPath` does.
                    ctx.fillPath()
                case let .setTextStyle(flags):
                    textStyleFlags = flags
                case let .setColor(newARGB):
                    argb = newARGB
                    applyColor()
                case let .stretchedGlyph(codepoint, rightEdgeX, topY, bottomY, fontSize, xScale, fontId):
                    fillStretchedGlyph(
                        codepoint: codepoint, rightEdgeX: px(rightEdgeX), topY: px(topY), bottomY: px(bottomY),
                        fontSize: px(fontSize), xScale: CGFloat(xScale), fontId: fontId,
                    )
                case let .setRotation(radians, pivotX, pivotY):
                    if radians != 0 {
                        ctx.saveGState()
                        ctx.translateBy(x: px(pivotX), y: px(pivotY))
                        ctx.rotate(by: CGFloat(radians))
                        ctx.translateBy(x: -px(pivotX), y: -px(pivotY))
                        rotationOpen = true
                    } else if rotationOpen {
                        ctx.restoreGState()
                        rotationOpen = false
                    }
                case let .setDash(onMM, offMM):
                    dashOn = px(onMM)
                    dashOff = px(offMM)
                }
            }

            mutating func finish() {
                if rotationOpen {
                    ctx.restoreGState()
                    rotationOpen = false
                }
            }

            // MARK: Fonts

            /// The Apple renderer's own resolution (`TextCTFontCache`): the named face, with bold / italic as
            /// symbolic traits when a face has them. SMuFL glyphs always come from Bravura; the system face is the
            /// Apple provider's `systemFont(for:)` — the weight from the style flags (bold before semibold).
            func font(fontId: DrawProgram.FontID, size: CGFloat, italic: Bool) -> CTFont {
                if fontId == .system {
                    let weight: NSFont.Weight = isBold ? .bold : isSemibold ? .semibold : .regular
                    let base = NSFont.systemFont(ofSize: size, weight: weight)
                    guard italic,
                          let slanted = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size)
                    else { return base as CTFont }
                    return slanted as CTFont
                }
                let face = fontId == .smufl ? SMuFLFamily.bravura : "Edwin"
                let base = CTFontCreateWithName(face as CFString, size, nil)
                var traits: CTFontSymbolicTraits = []
                if isBold { traits.insert(.boldTrait) }
                if italic { traits.insert(.italicTrait) }
                guard !traits.isEmpty else { return base }
                return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
            }

            func glyphPath(codepoint: UInt32, font: CTFont) -> CGPath? {
                guard let scalar = UnicodeScalar(codepoint) else { return nil }
                var units = Array(String(Character(scalar)).utf16)
                var glyphs = [CGGlyph](repeating: 0, count: units.count)
                guard CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count) else { return nil }
                return CTFontCreatePathForGlyph(font, glyphs[0], nil)
            }

            /// `StaffRenderer.smuflGlyphPath`: the outline flipped to Y-down and anchored at its origin.
            func fillGlyph(codepoint: UInt32, at origin: CGPoint, fontSize: CGFloat, fontId: DrawProgram.FontID) {
                let font = font(fontId: fontId, size: fontSize, italic: isItalic)
                guard let path = glyphPath(codepoint: codepoint, font: font) else { return }
                var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x, ty: origin.y)
                ctx.addPath(path.copy(using: &transform) ?? path)
                ctx.fillPath()
            }

            /// `StaffRenderer.smuflGlyphPathStretched`: the outline's own bounding box spans `[topY, bottomY]`,
            /// its right edge sits at `rightEdgeX`, x is scaled by `xScale`.
            func fillStretchedGlyph(
                codepoint: UInt32, rightEdgeX: CGFloat, topY: CGFloat, bottomY: CGFloat,
                fontSize: CGFloat, xScale: CGFloat, fontId: DrawProgram.FontID,
            ) {
                let font = font(fontId: fontId, size: fontSize, italic: false)
                guard let path = glyphPath(codepoint: codepoint, font: font) else { return }
                let bbox = path.boundingBox
                guard bbox.width > 0, bbox.height > 0 else { return }
                let scaleY = (bottomY - topY) / bbox.height
                var transform = CGAffineTransform(
                    a: xScale, b: 0, c: 0, d: -scaleY,
                    tx: rightEdgeX - bbox.maxX * xScale,
                    ty: topY + bbox.maxY * scaleY,
                )
                ctx.addPath(path.copy(using: &transform) ?? path)
                ctx.fillPath()
            }

            /// Fills text outlines at the baseline origin the way `ScoreLayerBuilder.textPath` does, so the
            /// draw-program parity renderer compares the same glyph geometry instead of CoreText rasterization.
            func fillText(
                _ text: String, at origin: CGPoint, fontSize: CGFloat, fontId: DrawProgram.FontID, italic: Bool,
            ) {
                let font = font(fontId: fontId, size: fontSize, italic: italic)
                let attributedString = NSAttributedString(string: text, attributes: [.font: font])
                let line = CTLineCreateWithAttributedString(attributedString)
                let path = CGMutablePath()

                guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
                for run in runs {
                    let count = CTRunGetGlyphCount(run)
                    guard count > 0 else { continue }
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    let range = CFRange(location: 0, length: count)
                    CTRunGetGlyphs(run, range, &glyphs)
                    CTRunGetPositions(run, range, &positions)

                    let runFont: CTFont
                    if let attributes = CTRunGetAttributes(run) as? [String: Any],
                       let runFontValue = attributes[kCTFontAttributeName as String]
                    {
                        runFont = unsafeBitCast(runFontValue as AnyObject, to: CTFont.self)
                    } else {
                        runFont = font
                    }

                    for index in 0 ..< count {
                        guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyphs[index], nil) else { continue }
                        let position = positions[index]
                        let transform = CGAffineTransform(
                            a: 1, b: 0, c: 0, d: -1,
                            tx: origin.x + position.x,
                            ty: origin.y - position.y,
                        )
                        path.addPath(glyphPath, transform: transform)
                    }
                }

                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }

    /// Pixel comparison of two same-sized bitmaps.
    @available(macOS 15.0, *)
    enum BitmapDiff {
        struct Result {
            let image: CGImage
            let total: Int
            let differing: Int
            let meanDelta: Double
            let maxDelta: Int
            let bestShift: (dx: Int, dy: Int, share: Double)
        }

        /// `threshold` is the max-channel absolute difference (0–255) above which a pixel counts as differing.
        /// The returned image keeps the first bitmap's ink in light gray and paints every differing pixel red, so
        /// the eye lands on the disagreement rather than on the score.
        static func compare(_ a: CGImage, _ b: CGImage, threshold: UInt8) throws -> Result {
            guard a.width == b.width, a.height == b.height else { throw RenderError.zeroSize }
            let width = a.width
            let height = a.height
            let bytesA = try rgba(of: a)
            let bytesB = try rgba(of: b)

            var out = [UInt8](repeating: 255, count: width * height * 4)
            var differing = 0
            var sum = 0
            var maxDelta = 0
            for index in 0 ..< (width * height) {
                let offset = index * 4
                var delta = 0
                for channel in 0 ..< 3 {
                    delta = max(delta, abs(Int(bytesA[offset + channel]) - Int(bytesB[offset + channel])))
                }
                sum += delta
                maxDelta = max(maxDelta, delta)
                if delta > Int(threshold) {
                    differing += 1
                    out[offset] = 220
                    out[offset + 1] = 30
                    out[offset + 2] = 30
                } else {
                    // A's ink, faded: 255 - (255 - v) * 0.25.
                    let v = Int(bytesA[offset])
                    let faded = UInt8(255 - (255 - v) / 4)
                    out[offset] = faded
                    out[offset + 1] = faded
                    out[offset + 2] = faded
                }
                out[offset + 3] = 255
            }

            let provider = CGDataProvider(data: Data(out) as CFData)
            guard let provider, let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent,
            ) else { throw RenderError.makeImageFailed }

            let total = width * height
            return Result(
                image: image, total: total, differing: differing,
                meanDelta: total == 0 ? 0 : Double(sum) / Double(total), maxDelta: maxDelta,
                bestShift: bestShift(bytesA, bytesB, width: width, height: height, threshold: Int(threshold)),
            )
        }

        /// The integer pixel offset of `b` against `a` (within ±3 px) that minimizes the differing share, with that
        /// share. A near-total diff that collapses under a 1 px shift is a coordinate-rounding disagreement, not a
        /// missing command — the two failure modes need very different fixes, and the raw share cannot tell them
        /// apart.
        private static func bestShift(
            _ a: [UInt8], _ b: [UInt8], width: Int, height: Int, threshold: Int,
        ) -> (dx: Int, dy: Int, share: Double) {
            var best = (dx: 0, dy: 0, share: 1.0)
            for dy in -3 ... 3 {
                for dx in -3 ... 3 {
                    var differing = 0
                    var counted = 0
                    for y in 0 ..< height {
                        let sy = y + dy
                        guard sy >= 0, sy < height else { continue }
                        for x in 0 ..< width {
                            let sx = x + dx
                            guard sx >= 0, sx < width else { continue }
                            counted += 1
                            let oa = (y * width + x) * 4
                            let ob = (sy * width + sx) * 4
                            var delta = 0
                            for channel in 0 ..< 3 {
                                delta = max(delta, abs(Int(a[oa + channel]) - Int(b[ob + channel])))
                            }
                            if delta > threshold { differing += 1 }
                        }
                    }
                    let share = counted == 0 ? 1 : Double(differing) / Double(counted)
                    if share < best.share { best = (dx, dy, share) }
                }
            }
            return best
        }

        /// Redraws `image` into a fresh premultiplied-RGBA context so both inputs are read in one known layout,
        /// whatever backing store they were made with.
        private static func rgba(of image: CGImage) throws -> [UInt8] {
            let width = image.width
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
                ) else { throw RenderError.contextInitFailed }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return bytes
        }
    }

#endif
