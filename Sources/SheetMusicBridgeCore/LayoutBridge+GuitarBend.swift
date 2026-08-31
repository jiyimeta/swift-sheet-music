#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation
import SheetMusicLayout

extension LayoutBridge {
    // MARK: - Guitar bend

    /// Android counterpart of `GuitarBendRenderer` / `drawGuitarBend`.
    ///
    /// The angular bend becomes `.moveTo` + two `.lineTo` + `.stroke`;
    /// the slight bend becomes `.moveTo` + `.cubicTo` + `.stroke` with
    /// the start anchor as the FIRST control point, matching
    /// `layoutSlightBend`'s `path.cubicTo(PointF(0, 0), curve, pos2())`
    /// (`rendering/score/guitarbendlayout.cpp:379-381`).
    ///
    /// No cap/join opcode is emitted: `DrawCommand.stroke` has none, and
    /// Compose's `Stroke` already defaults to `StrokeCap.Butt` /
    /// `StrokeJoin.Miter` — the pen `TDraw::draw(const
    /// GuitarBendSegment*)` sets (`tdraw.cpp:1637-1638`).
    ///
    /// Every point arrives already in the same absolute point frame, so
    /// this only scales to document mm.
    static func encodeGuitarBend(
        fromXPt: Double, fromYPt: Double,
        vertexXPt: Double, vertexYPt: Double,
        toXPt: Double, toYPt: Double,
        slight: Bool,
        spPt: Double,
        into out: inout [DrawCommand],
    ) {
        out.append(.moveTo(
            x: fromXPt * ptToMMScale, y: fromYPt * ptToMMScale,
        ))
        if slight {
            out.append(.cubicTo(
                cx1: fromXPt * ptToMMScale,
                cy1: fromYPt * ptToMMScale,
                cx2: vertexXPt * ptToMMScale,
                cy2: vertexYPt * ptToMMScale,
                x: toXPt * ptToMMScale,
                y: toYPt * ptToMMScale,
            ))
        } else {
            out.append(.lineTo(
                x: vertexXPt * ptToMMScale, y: vertexYPt * ptToMMScale,
            ))
            out.append(.lineTo(
                x: toXPt * ptToMMScale, y: toYPt * ptToMMScale,
            ))
        }
        let lineWidth = spPt * Double(GuitarBendGeometry.lineThicknessSp)
        out.append(.stroke(width: lineWidth * ptToMMScale))
    }
}
