import CDirect2D
import SheetMusicBridgeCore

/// A Direct2D interpreter of the draw-program stream: the walk `DrawProgramCGRenderer` (RenderPreviews) does on the
/// Mac, over Direct2D and DirectWrite, so the two can be compared pixel for pixel.
///
/// Like that walk, and like `canvas.ts` and the Kotlin `ScoreCanvas` it was ported from, it takes commands in
/// document millimetres, multiplies them by `pxPerMM`, clamps strokes to `minStrokePx`, and fills glyphs and text as
/// outlines. Direct2D is Y-down like the stream, so unlike the CoreGraphics walk nothing is flipped. Fonts come from
/// the files given — Bravura for SMuFL, Edwin for text — with bold and italic taken from the family's own faces and
/// never synthesized, which is what CoreText's symbolic traits do on the Mac.
public enum Direct2DPageRenderer {
    /// The Kotlin renderer's `coerceAtLeast(1.5f)`, `canvas.ts`'s `MIN_STROKE_PX`, `DrawProgramCGRenderer.minStrokePx`.
    public static let minStrokePx = 1.5

    public struct Failure: Error, CustomStringConvertible {
        public let step: String
        public let hresult: Int32

        public var description: String {
            "\(step) failed (HRESULT 0x\(String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)))"
        }
    }

    /// Renders `commands` onto a white `widthPx` x `heightPx` canvas, offset by `offsetPx`, and writes it to
    /// `pngPath`.
    public static func renderPNG(
        _ commands: [DrawCommand], widthPx: Int, heightPx: Int, pxPerMM: Double, offsetPx: (x: Double, y: Double),
        fontFiles: [String], to pngPath: String,
    ) throws {
        var created: OpaquePointer?
        try check(cd2d_create(&created, UInt32(widthPx), UInt32(heightPx)), "creating the canvas")
        guard let canvas = created else { throw Failure(step: "creating the canvas", hresult: -1) }
        defer { cd2d_destroy(canvas) }
        for file in fontFiles {
            try check(withWide(file) { cd2d_add_font_file(canvas, $0) }, "adding the font \(file)")
        }
        try check(cd2d_fonts_ready(canvas), "building the font collection")

        var walker = Walker(canvas: canvas, pxPerMM: pxPerMM, offset: offsetPx)
        for command in commands {
            walker.paint(command)
        }
        try check(withWide(pngPath) { cd2d_write_png(canvas, $0) }, "writing \(pngPath)")
    }

    private struct Walker {
        let canvas: OpaquePointer
        let pxPerMM: Double
        let offset: (x: Double, y: Double)
        var dashOn: Float = 0
        var dashOff: Float = 0
        var textStyleFlags: UInt8 = DrawCommand.TextStyleFlag.none

        init(canvas: OpaquePointer, pxPerMM: Double, offset: (x: Double, y: Double)) {
            self.canvas = canvas
            self.pxPerMM = pxPerMM
            self.offset = offset
            cd2d_set_color(canvas, 0xFF00_0000)
            setRotation(radians: 0, pivotX: 0, pivotY: 0)
        }

        func px(_ mm: Double) -> Float {
            Float(mm * pxPerMM)
        }

        var isBold: Bool {
            textStyleFlags & DrawCommand.TextStyleFlag.bold != 0
        }

        var isItalic: Bool {
            textStyleFlags & DrawCommand.TextStyleFlag.italic != 0
        }

        mutating func paint(_ command: DrawCommand) {
            switch command {
            case let .moveTo(x, y):
                cd2d_move_to(canvas, px(x), px(y))
            case let .lineTo(x, y):
                cd2d_line_to(canvas, px(x), px(y))
            case let .cubicTo(cx1, cy1, cx2, cy2, x, y):
                cd2d_cubic_to(canvas, px(cx1), px(cy1), px(cx2), px(cy2), px(x), px(y))
            case let .stroke(width):
                cd2d_stroke(canvas, max(px(width), Float(Direct2DPageRenderer.minStrokePx)), dashOn, dashOff)
            case let .fillRect(x, y, w, h):
                cd2d_fill_rect(canvas, px(x), px(y), px(w), px(h))
            case let .glyph(codepoint, x, y, size, fontId):
                withWide(family(fontId)) { family in
                    cd2d_fill_glyph(
                        canvas, family, codepoint, px(x), px(y), px(size), isBold ? 1 : 0, isItalic ? 1 : 0,
                    )
                }
            case let .text(text, x, y, size, fontId):
                fillText(text, x: x, y: y, size: size, fontId: fontId, italic: isItalic)
            case let .italicText(text, x, y, size, fontId):
                fillText(text, x: x, y: y, size: size, fontId: fontId, italic: true)
            case let .setTextStyle(flags):
                textStyleFlags = flags
            case let .setColor(argb):
                cd2d_set_color(canvas, argb)
            case let .stretchedGlyph(codepoint, rightEdgeX, topY, bottomY, fontSize, xScale, fontId):
                withWide(family(fontId)) { family in
                    cd2d_fill_stretched_glyph(
                        canvas, family, codepoint, px(rightEdgeX), px(topY), px(bottomY), px(fontSize),
                        Float(xScale),
                    )
                }
            case let .setRotation(radians, pivotX, pivotY):
                setRotation(radians: radians, pivotX: pivotX, pivotY: pivotY)
            case let .setDash(onMM, offMM):
                dashOn = px(onMM)
                dashOff = px(offMM)
            }
        }

        /// The page offset, then a rotation about the pivot — zero clears it, as the stream's own reset does.
        func setRotation(radians: Double, pivotX: Double, pivotY: Double) {
            cd2d_set_transform(
                canvas, Float(offset.x), Float(offset.y), Float(radians * 180 / Double.pi), px(pivotX), px(pivotY),
            )
        }

        func fillText(_ text: String, x: Double, y: Double, size: Double, fontId: DrawProgram.FontID, italic: Bool) {
            let units = Array(text.utf16)
            guard !units.isEmpty else { return }
            withWide(family(fontId)) { family in
                units.withUnsafeBufferPointer { buffer in
                    cd2d_fill_text(
                        canvas, family, buffer.baseAddress, UInt32(buffer.count), px(x), px(y), px(size),
                        isBold ? 1 : 0, italic ? 1 : 0,
                    )
                }
            }
        }

        /// `DrawProgramCGRenderer.font`: SMuFL glyphs always come from Bravura, everything else from Edwin.
        func family(_ fontId: DrawProgram.FontID) -> String {
            fontId == .smufl ? "Bravura" : "Edwin"
        }
    }
}

/// Calls `body` with `string` as a NUL-terminated UTF-16 buffer.
private func withWide<Result>(_ string: String, _ body: (UnsafePointer<UInt16>) -> Result) -> Result {
    string.withCString(encodedAs: UTF16.self, body)
}

private func check(_ hresult: Int32, _ step: String) throws {
    guard hresult == 0 else { throw Direct2DPageRenderer.Failure(step: step, hresult: hresult) }
}
