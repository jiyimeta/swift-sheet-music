import CDirect2D
import SheetMusicBridgeCore

/// Walks draw commands onto a CDirect2D canvas: the walk `DrawProgramCGRenderer` (RenderPreviews) does on the Mac, over
/// Direct2D and DirectWrite, so the two can be compared pixel for pixel. Shared by the PNG path
/// (`Direct2DPageRenderer`) and the onscreen surface (`ScoreSurface`, which walks one `SystemSpan` at a time into a
/// band).
///
/// Like that walk, and like `canvas.ts` and the Kotlin `ScoreCanvas` it was ported from, it takes commands in
/// document millimetres, multiplies them by `pxPerMM`, clamps strokes to `minStrokePx`, and fills glyphs and text as
/// outlines. Direct2D is Y-down like the stream, so unlike the CoreGraphics walk nothing is flipped. SMuFL glyphs come
/// from Bravura and everything else from Edwin, with bold and italic taken from the family's own faces and never
/// synthesized, which is what CoreText's symbolic traits do on the Mac.
///
/// A walker starts in the draw program's default state (black, solid, no rotation, no text style), which is also the
/// state at every `SystemSpan` boundary.
struct DrawCommandWalker {
    /// The Kotlin renderer's `coerceAtLeast(1.5f)`, `canvas.ts`'s `MIN_STROKE_PX`, `DrawProgramCGRenderer.minStrokePx`.
    static let minStrokePx = 1.5

    let canvas: OpaquePointer
    let pxPerMM: Double
    let offset: (x: Double, y: Double)
    /// Canvas pixels outside which a fill cannot show (a band's own rectangle): glyphs, text and rectangles that
    /// certainly miss it are skipped. Paths are always walked — a path's extent is only known at its stroke.
    let cull: DrawRect?
    private var dashOn: Float = 0
    private var dashOff: Float = 0
    private var textStyleFlags: UInt8 = DrawCommand.TextStyleFlag.none
    private var isRotated = false

    init(canvas: OpaquePointer, pxPerMM: Double, offset: (x: Double, y: Double), cull: DrawRect? = nil) {
        self.canvas = canvas
        self.pxPerMM = pxPerMM
        self.offset = offset
        self.cull = cull
        cd2d_set_color(canvas, 0xFF00_0000)
        setRotation(radians: 0, pivotX: 0, pivotY: 0)
    }

    mutating func paint(_ commands: ArraySlice<DrawCommand>) {
        for command in commands {
            paint(command)
        }
    }

    mutating func paint(_ command: DrawCommand) {
        if isCulled(command) { return }
        switch command {
        case let .moveTo(x, y):
            cd2d_move_to(canvas, px(x), px(y))
        case let .lineTo(x, y):
            cd2d_line_to(canvas, px(x), px(y))
        case let .cubicTo(cx1, cy1, cx2, cy2, x, y):
            cd2d_cubic_to(canvas, px(cx1), px(cy1), px(cx2), px(cy2), px(x), px(y))
        case let .stroke(width):
            cd2d_stroke(canvas, max(px(width), Float(Self.minStrokePx)), dashOn, dashOff)
        case let .fillRect(x, y, w, h):
            cd2d_fill_rect(canvas, px(x), px(y), px(w), px(h))
        case let .glyph(codepoint, x, y, size, fontId):
            withWide(family(fontId)) { family in
                cd2d_fill_glyph(canvas, family, codepoint, px(x), px(y), px(size), isBold ? 1 : 0, isItalic ? 1 : 0)
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
                    canvas, family, codepoint, px(rightEdgeX), px(topY), px(bottomY), px(fontSize), Float(xScale),
                )
            }
        case let .setRotation(radians, pivotX, pivotY):
            setRotation(radians: radians, pivotX: pivotX, pivotY: pivotY)
        case let .setDash(onMM, offMM):
            dashOn = px(onMM)
            dashOff = px(offMM)
        }
    }

    private func px(_ mm: Double) -> Float {
        Float(mm * pxPerMM)
    }

    private var isBold: Bool {
        textStyleFlags & DrawCommand.TextStyleFlag.bold != 0
    }

    private var isItalic: Bool {
        textStyleFlags & DrawCommand.TextStyleFlag.italic != 0
    }

    /// Whether `command` is a fill that certainly misses `cull`. Under a rotation nothing is culled.
    private func isCulled(_ command: DrawCommand) -> Bool {
        guard let cull, !isRotated else { return false }
        switch command {
        case .glyph, .text, .italicText, .fillRect, .stretchedGlyph:
            var bounds = DrawCommandBounds()
            bounds.add(command)
            guard let mm = bounds.bounds else { return false }
            let painted = DrawRect(
                x: mm.x * pxPerMM + offset.x, y: mm.y * pxPerMM + offset.y,
                width: mm.width * pxPerMM, height: mm.height * pxPerMM,
            )
            return !painted.intersects(cull)
        default:
            return false
        }
    }

    /// The page offset, then a rotation about the pivot — zero clears it, as the stream's own reset does.
    private mutating func setRotation(radians: Double, pivotX: Double, pivotY: Double) {
        isRotated = radians != 0
        cd2d_set_transform(
            canvas, Float(offset.x), Float(offset.y), Float(radians * 180 / Double.pi), px(pivotX), px(pivotY),
        )
    }

    private func fillText(
        _ text: String, x: Double, y: Double, size: Double, fontId: DrawProgram.FontID, italic: Bool,
    ) {
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
    private func family(_ fontId: DrawProgram.FontID) -> String {
        fontId == .smufl ? "Bravura" : "Edwin"
    }
}

/// Calls `body` with `string` as a NUL-terminated UTF-16 buffer.
func withWide<Result>(_ string: String, _ body: (UnsafePointer<UInt16>) -> Result) -> Result {
    string.withCString(encodedAs: UTF16.self, body)
}
