import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    // Same clash as in `LayoutBridge.swift`: on Android, Foundation's
    // CoreGraphics shims export `CGPoint` / `CGFloat` alongside
    // SheetMusicLayout's stubs. Anchor to the Layout definitions so the
    // `LegacyBendShape` associated values match.
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

extension LayoutBridge {
    // MARK: - Legacy bend

    /// Android counterpart of `LegacyBendRenderer` /
    /// `ScoreLayerBuilder.drawLegacyBend` — the pre-4.2 MuseScore bend,
    /// `TDraw::draw(const Bend*)` (`rendering/score/tdraw.cpp:939`).
    ///
    /// The shape arrives fully resolved from `LegacyBendGeometry`, in the
    /// same absolute point frame every other element uses, so this only
    /// lowers it to opcodes and scales to document mm:
    ///
    /// * **Lines and curves** become ONE running path stroked once with
    ///   the bend pen (`Sid::bendLineWidth`, `tdraw.cpp:951`). The
    ///   geometry emits the legs contiguously, so a `moveTo` goes in only
    ///   where a piece does not start where the previous one ended —
    ///   otherwise a phantom connector would be stroked across the staff.
    ///   No cap/join opcode exists in `DrawCommand`; C++ uses round for
    ///   both, Compose defaults to butt/miter. At 0.15 sp the difference
    ///   is under a tenth of a point.
    /// * **Arrowheads** are `aw`-wide, `aw`-tall triangles pointing off
    ///   the leg they close (`tdraw.cpp:963-966`).
    /// * **Labels** ("full", "1/2", …) sit above the arrow tip, centered
    ///   horizontally with their bottom on the tip (`AlignHCenter |
    ///   AlignBottom`, `tdraw.cpp:967`).
    ///
    /// Outline first, then the arrows and labels in piece order — the
    /// same two passes as the Apple renderers, so the single outline
    /// stroke cannot be split by an arrow's own stroke.
    static func encodeLegacyBend(
        shape: LegacyBendShape,
        spPt: Double,
        into out: inout [DrawCommand],
    ) {
        encodeLegacyBendOutline(shape: shape, spPt: spPt, into: &out)
        let arrowWidth = spPt * Double(LegacyBendGeometry.arrowWidthSp)
        for piece in shape.pieces {
            switch piece {
            case let .arrow(tip, up):
                encodeLegacyBendArrow(
                    tip: tip, up: up, arrowWidth: arrowWidth,
                    spPt: spPt, into: &out,
                )
            case let .label(text, anchor):
                encodeLegacyBendLabel(
                    text, anchor: anchor, spPt: spPt, into: &out,
                )
            case .line, .curve:
                continue
            }
        }
    }

    /// Every `.line` / `.curve` piece as one path plus a single stroke.
    private static func encodeLegacyBendOutline(
        shape: LegacyBendShape,
        spPt: Double,
        into out: inout [DrawCommand],
    ) {
        var current: CGPoint?
        var emitted = false

        func moveIfNeeded(to start: CGPoint) {
            if current != start {
                out.append(.moveTo(
                    x: Double(start.x) * ptToMMScale,
                    y: Double(start.y) * ptToMMScale,
                ))
            }
            emitted = true
        }

        for piece in shape.pieces {
            switch piece {
            case let .line(from, to):
                moveIfNeeded(to: from)
                out.append(.lineTo(
                    x: Double(to.x) * ptToMMScale,
                    y: Double(to.y) * ptToMMScale,
                ))
                current = to
            case let .curve(from, control1, control2, to):
                moveIfNeeded(to: from)
                out.append(.cubicTo(
                    cx1: Double(control1.x) * ptToMMScale,
                    cy1: Double(control1.y) * ptToMMScale,
                    cx2: Double(control2.x) * ptToMMScale,
                    cy2: Double(control2.y) * ptToMMScale,
                    x: Double(to.x) * ptToMMScale,
                    y: Double(to.y) * ptToMMScale,
                ))
                current = to
            case .arrow, .label:
                // An arrow or label does not break the running path: the
                // next leg still starts where the last one ended.
                continue
            }
        }
        guard emitted else { return }
        out.append(.stroke(width: legacyBendLineWidthMM(spPt: spPt)))
    }

    /// One arrowhead: apex at the leg's end point, base `arrowWidth`
    /// behind it — up-arrows put the base BELOW the tip (positive y in
    /// the layout's Y-down frame), down-arrows above
    /// (`tdraw.cpp:963-966`).
    ///
    /// DrawCommand has no filled-polygon opcode; a closed stroked
    /// triangle at bend line width approximates TDraw's filled arrow.
    /// Revisit if a fill opcode lands.
    private static func encodeLegacyBendArrow(
        tip: CGPoint,
        up: Bool,
        arrowWidth: Double,
        spPt: Double,
        into out: inout [DrawCommand],
    ) {
        let tipX = Double(tip.x)
        let tipY = Double(tip.y)
        let baseY = tipY + (up ? arrowWidth : -arrowWidth)
        out.append(.moveTo(x: tipX * ptToMMScale, y: tipY * ptToMMScale))
        out.append(.lineTo(
            x: (tipX + arrowWidth / 2) * ptToMMScale,
            y: baseY * ptToMMScale,
        ))
        out.append(.lineTo(
            x: (tipX - arrowWidth / 2) * ptToMMScale,
            y: baseY * ptToMMScale,
        ))
        out.append(.lineTo(x: tipX * ptToMMScale, y: tipY * ptToMMScale))
        out.append(.stroke(width: legacyBendLineWidthMM(spPt: spPt)))
    }

    /// Bend amount above the arrow tip: `TextStyleType.bend` (Edwin 8 pt
    /// normal, spatium-dependent), centered on the tip's x with the
    /// text's bottom on the tip's y. Unlike the glissando label there is
    /// no width gate — MuseScore always draws it.
    private static func encodeLegacyBendLabel(
        _ text: String,
        anchor: CGPoint,
        spPt: Double,
        into out: inout [DrawCommand],
    ) {
        guard !text.isEmpty else { return }
        let fontSize = TextRoleStyle.fontSize(
            for: .bend, sp: CGFloat(spPt),
        )
        let font = LayoutFont(face: "Edwin", pointSize: fontSize)
        let textWidth = FontMetrics.provider.typographicWidth(
            text: text, font: font,
        )
        let descent = FontMetrics.provider.descent(font: font)
        // Canvas anchors text at its baseline-leading corner, so shift by
        // half the width and by the descent to land bottom-center on the
        // anchor.
        out.append(.text(
            text: text,
            x: Double(anchor.x - textWidth / 2) * ptToMMScale,
            y: Double(anchor.y - descent) * ptToMMScale,
            size: Double(fontSize) * ptToMMScale,
            fontId: .textRoman,
        ))
    }

    private static func legacyBendLineWidthMM(spPt: Double) -> Double {
        spPt * Double(LegacyBendGeometry.lineThicknessSp) * ptToMMScale
    }
}
