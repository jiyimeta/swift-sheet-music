import SheetMusicBridgeCore
import SheetMusicFoundation
import SheetMusicLayout

/// Walks one page's draw commands into a PDF content stream — the walk `DrawCommandWalker` does onto Direct2D, read the
/// same way: commands in document millimetres with y down, glyphs and text in the score's bundled faces (the platform
/// UI face's labels in that face when the host gave its file), the weight and slant from the text style. The page
/// becomes PDF points with y up (72 / 25.4 points a millimetre, from the page's bottom edge), and strokes keep their
/// own width: a PDF is vector, so the screen's 1.5 px floor does not apply.
///
/// Text sits where the layout measured it: each character at the offset the installed `FontMetrics.provider` gives
/// for it — the provider the pages were laid out with — never at the font's own kerning. A character the face does
/// not have (neither Edwin nor Segoe UI has Japanese) draws in the font the host's text engine falls back to for it
/// (`ScorePDFFonts(fallback:)`); with none, it stays in the text as invisible text with its own code, so the PDF can
/// still be searched for it, and is drawn as the outline the host gives for it (`ScorePDFFonts(outlines:)`), if any.
///
/// A walker starts in the draw program's default state (black, opaque, solid, unrotated, no text style).
struct PDFPageWalker {
    /// PDF points per millimetre.
    static let pointsPerMM = 72 / 25.4

    let resources: PDFResources
    let pageHeight: Double
    private(set) var content = ""
    private var textStyle: UInt8 = DrawCommand.TextStyleFlag.none
    private var argb: UInt32 = 0xFF00_0000
    private var dash: (on: Double, off: Double) = (0, 0)
    private var isRotated = false

    init(resources: PDFResources, pageHeightMM: Double) {
        self.resources = resources
        pageHeight = pageHeightMM * Self.pointsPerMM
    }

    mutating func walk(_ commands: [DrawCommand]) {
        for command in commands {
            walk(command)
        }
        if isRotated { emit("Q") }
    }

    private mutating func walk(_ command: DrawCommand) {
        switch command {
        case let .moveTo(x, y): emit("\(point(x, y)) m")
        case let .lineTo(x, y): emit("\(point(x, y)) l")
        case let .cubicTo(cx1, cy1, cx2, cy2, x, y): emit("\(point(cx1, cy1)) \(point(cx2, cy2)) \(point(x, y)) c")
        case let .stroke(width): emit("\(Self.number(width * Self.pointsPerMM)) w S")
        case .fillPath: emit("f")
        case let .fillRect(x, y, w, h):
            let k = Self.pointsPerMM
            emit("\(point(x, y + h)) \(Self.number(w * k)) \(Self.number(h * k)) re f")
        case let .glyph(codepoint, x, y, size, fontId):
            glyph(codepoint, x: x, y: y, size: size, fontId: fontId)
        case let .text(text, x, y, size, fontId):
            self.text(text, x: x, y: y, size: size, fontId: fontId)
        case let .setTextStyle(flags): textStyle = flags
        case let .setColor(argb):
            self.argb = argb
            emitColor()
        case let .stretchedGlyph(codepoint, rightEdgeX, topY, bottomY, fontSize, xScale, fontId):
            stretchedGlyph(
                codepoint,
                right: rightEdgeX,
                top: topY,
                bottom: bottomY,
                size: fontSize,
                xScale: xScale,
                fontId: fontId,
            )
        case let .setRotation(radians, pivotX, pivotY): setRotation(radians, pivotX: pivotX, pivotY: pivotY)
        case let .setDash(onMM, offMM):
            dash = (onMM, offMM)
            emitDash()
        }
    }

    // MARK: - State

    /// The fill and stroke color, and through a graphics state its alpha.
    private mutating func emitColor() {
        let rgb = [argb >> 16 & 0xFF, argb >> 8 & 0xFF, argb & 0xFF].map { Self.number(Double($0) / 255) }
            .joined(separator: " ")
        emit("/\(resources.alphaState(UInt8(argb >> 24))) gs \(rgb) rg \(rgb) RG")
    }

    private mutating func emitDash() {
        let k = Self.pointsPerMM
        emit(dash == (0, 0) ? "[] 0 d" : "[\(Self.number(dash.on * k)) \(Self.number(dash.off * k))] 0 d")
    }

    /// A rotation about the pivot until the next `setRotation`; zero clears it. `q … Q` brackets it, and since `Q`
    /// also restores the color and dash of before the `q`, the current ones are set again after it.
    private mutating func setRotation(_ radians: Double, pivotX: Double, pivotY: Double) {
        if isRotated {
            emit("Q")
            isRotated = false
            emitColor()
            if dash != (0, 0) { emitDash() }
        }
        guard radians != 0 else { return }
        // Y up turns a clockwise rotation on the page (y down) into a negative angle.
        let cosine = cos(-radians)
        let sine = sin(-radians)
        let pivot = (x: pivotX * Self.pointsPerMM, y: pageHeight - pivotY * Self.pointsPerMM)
        let matrix = [
            cosine, sine, -sine, cosine,
            pivot.x - cosine * pivot.x + sine * pivot.y, pivot.y - sine * pivot.x - cosine * pivot.y,
        ]
        emit("q \(matrix.map(Self.number).joined(separator: " ")) cm")
        isRotated = true
    }

    // MARK: - Glyphs and text

    private mutating func glyph(_ codepoint: UInt32, x: Double, y: Double, size: Double, fontId: DrawProgram.FontID) {
        let font = resources.font(fontId, style: textStyle)
        let glyph = font.font.glyph(for: codepoint)
        guard glyph != 0 else { return }
        font.use(glyph, for: [codepoint])
        emit("BT /\(font.resourceName) \(Self.number(size * Self.pointsPerMM)) Tf \(point(x, y)) Td "
            + "<\(PDFString.hex4(UInt16(glyph)))> Tj ET")
    }

    /// Each line from `y` down by the face's line height, each character at the provider's offset for it — in the
    /// line's face, or for a character it lacks in the font the host falls back to for that part of the line. A
    /// character no font covers stays invisible text, and when the host has its outline that outline is filled at the
    /// same pen position after the text object (a path cannot be built inside one).
    private mutating func text(_ text: String, x: Double, y: Double, size: Double, fontId: DrawProgram.FontID) {
        let font = resources.font(fontId, style: textStyle)
        let measured = layoutFont(fontId, size: size)
        let provider = FontMetrics.provider
        let lineHeight = Double(provider.ascent(font: measured) + provider.descent(font: measured)
            + provider.leading(font: measured))
        let fontSize = Self.number(size * Self.pointsPerMM)
        let systemStyle = PDFResources.SystemStyle(style: textStyle)
        let outlineStyle = ScorePDFTextStyle(
            isSystemFace: fontId == .system, weight: systemStyle.weight, isItalic: systemStyle.isItalic,
        )
        var current = font
        var shown = "BT /\(font.resourceName) \(fontSize) Tf"
        var filled: [String] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let offsets = provider.caretOffsets(text: String(line), font: measured).map { Double($0) }
            let fallbacks = resources.fallbacks(String(line), drawnIn: font, fontId: fontId, style: textStyle)
            var unit = 0
            for scalar in line.unicodeScalars {
                let dx = unit < offsets.count ? offsets[unit] : 0
                var face = font
                if font.font.glyph(for: scalar.value) == 0, let fallback = fallbacks.first(where: {
                    $0.range.contains(unit) && $0.font.font.glyph(for: scalar.value) != 0
                }) {
                    face = fallback.font
                }
                unit += scalar.utf16.count
                if face !== current {
                    shown += " /\(face.resourceName) \(fontSize) Tf"
                    current = face
                }
                let lineY = y + Double(index) * lineHeight
                let code = face.code(for: scalar.value)
                let pen = point(x + dx, lineY)
                shown += " 1 0 0 1 \(pen) Tm"
                shown += code.isMissing ? " 3 Tr <\(code.hex)> Tj 0 Tr" : " <\(code.hex)> Tj"
                if code.isMissing, let outline = resources.outline(scalar, style: outlineStyle) {
                    filled.append("q \(fontSize) 0 0 \(fontSize) \(pen) cm \(Self.pathOperators(outline)) f Q")
                }
            }
        }
        emit(shown + " ET")
        for fill in filled {
            emit(fill)
        }
    }

    /// An outline's contours as path operators in its own units, a quadratic curve raised to the cubic a PDF draws.
    static func pathOperators(_ outline: ScorePDFGlyphOutline) -> String {
        var operators: [String] = []
        var pen = (x: 0.0, y: 0.0)
        var start = pen
        func pair(_ x: Double, _ y: Double) -> String {
            "\(number(x)) \(number(y))"
        }
        for element in outline.elements {
            switch element {
            case let .move(x, y):
                operators.append("\(pair(x, y)) m")
                pen = (x, y)
                start = pen
            case let .line(x, y):
                operators.append("\(pair(x, y)) l")
                pen = (x, y)
            case let .quad(cx, cy, x, y):
                let first = (x: pen.x + 2 * (cx - pen.x) / 3, y: pen.y + 2 * (cy - pen.y) / 3)
                let second = (x: x + 2 * (cx - x) / 3, y: y + 2 * (cy - y) / 3)
                operators.append("\(pair(first.x, first.y)) \(pair(second.x, second.y)) \(pair(x, y)) c")
                pen = (x, y)
            case let .cubic(c1x, c1y, c2x, c2y, x, y):
                operators.append("\(pair(c1x, c1y)) \(pair(c2x, c2y)) \(pair(x, y)) c")
                pen = (x, y)
            case .close:
                operators.append("h")
                pen = start
            }
        }
        return operators.joined(separator: " ")
    }

    /// The glyph's box at `size` stretched to span `top`…`bottom`, `xScale` wide, its right edge at `right` — the
    /// transform `cd2d_fill_stretched_glyph` applies, from the box the layout measured the glyph by.
    private mutating func stretchedGlyph(
        _ codepoint: UInt32, right: Double, top: Double, bottom: Double, size: Double, xScale: Double,
        fontId: DrawProgram.FontID,
    ) {
        let font = resources.font(fontId, style: textStyle)
        let glyph = font.font.glyph(for: codepoint)
        guard glyph != 0, codepoint <= UInt32(UInt16.max),
              let box = FontMetrics.provider.glyphPathBoundingBox(
                  font: layoutFont(fontId, size: size), codepoint: UInt16(codepoint),
              ), box.height > 0
        else { return }
        font.use(glyph, for: [codepoint])
        let k = Self.pointsPerMM
        let scaleY = (bottom - top) / Double(box.height)
        let matrix = [
            k * xScale * size, 0, 0, k * scaleY * size,
            k * (right - xScale * Double(box.maxX)), pageHeight - k * (top + scaleY * Double(box.maxY)),
        ]
        emit("BT /\(font.resourceName) 1 Tf \(matrix.map(Self.number).joined(separator: " ")) Tm "
            + "<\(PDFString.hex4(UInt16(glyph)))> Tj ET")
    }

    /// The face the layout measured a font id in, at `size` millimetres (the provider's answers scale with it): the
    /// platform UI face (`face: ""`) at the style's weight for `.system` text, which only a provider that measures it
    /// ever emits — whichever face the PDF then draws it in.
    private func layoutFont(_ fontId: DrawProgram.FontID, size: Double) -> LayoutFont {
        let bold = textStyle & DrawCommand.TextStyleFlag.bold != 0
        let italic = textStyle & DrawCommand.TextStyleFlag.italic != 0
        switch fontId {
        case .smufl: return LayoutFont(face: SMuFLFamily.bravura, pointSize: CGFloat(size))
        case .textRoman:
            return LayoutFont(
                face: "Edwin", pointSize: CGFloat(size), weight: bold ? .bold : .regular, isItalic: italic,
            )
        case .system:
            let style = PDFResources.SystemStyle(style: textStyle)
            return LayoutFont(face: "", pointSize: CGFloat(size), weight: style.weight, isItalic: style.isItalic)
        }
    }

    // MARK: - Output

    /// A page point (millimetres, y down) in PDF points, y up.
    private func point(_ x: Double, _ y: Double) -> String {
        "\(Self.number(x * Self.pointsPerMM)) \(Self.number(pageHeight - y * Self.pointsPerMM))"
    }

    private mutating func emit(_ operators: String) {
        content += operators
        content += "\n"
    }

    /// A number as a content stream writes it: to a thousandth, without trailing zeros.
    static func number(_ value: Double) -> String {
        let thousandths = Int((value * 1000).rounded())
        let magnitude = abs(thousandths)
        let sign = thousandths < 0 ? "-" : ""
        let fraction = magnitude % 1000
        guard fraction != 0 else { return sign + String(magnitude / 1000) }
        var digits = String(fraction)
        digits = String(repeating: "0", count: 3 - digits.count) + digits
        while digits.hasSuffix("0") {
            digits.removeLast()
        }
        return "\(sign)\(magnitude / 1000).\(digits)"
    }
}
