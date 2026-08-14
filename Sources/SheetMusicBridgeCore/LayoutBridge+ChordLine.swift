#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation
import SheetMusicLayout

extension LayoutBridge {
    // MARK: - Chord line (fall / doit / plop / scoop)

    /// Android counterpart of `ChordLineRenderer` / `drawChordLine`.
    /// The path variants become `.moveTo` / `.lineTo` / `.cubicTo` +
    /// `.stroke`; the wavy variants become one centre-anchored glyph
    /// wrapped in a `.setRotation` pair.
    ///
    /// Geometry comes from `ChordLineGeometry`, shared with Apple, so
    /// the two renderers cannot drift.
    static func encodeChordLine(
        shape: ChordLineShape,
        originXPt: Double,
        originYPt: Double,
        thicknessPt: Double,
        glyphSizePt: Double,
        into out: inout [DrawCommand],
    ) {
        switch shape {
        case let .path(segments):
            guard !segments.isEmpty else { return }
            out.append(.moveTo(
                x: originXPt * ptToMMScale, y: originYPt * ptToMMScale,
            ))
            for segment in segments {
                switch segment {
                case let .move(to):
                    out.append(.moveTo(
                        x: (originXPt + Double(to.x)) * ptToMMScale,
                        y: (originYPt + Double(to.y)) * ptToMMScale,
                    ))
                case let .line(to):
                    out.append(.lineTo(
                        x: (originXPt + Double(to.x)) * ptToMMScale,
                        y: (originYPt + Double(to.y)) * ptToMMScale,
                    ))
                case let .curve(control1, control2, to):
                    out.append(.cubicTo(
                        cx1: (originXPt + Double(control1.x)) * ptToMMScale,
                        cy1: (originYPt + Double(control1.y)) * ptToMMScale,
                        cx2: (originXPt + Double(control2.x)) * ptToMMScale,
                        cy2: (originYPt + Double(control2.y)) * ptToMMScale,
                        x: (originXPt + Double(to.x)) * ptToMMScale,
                        y: (originYPt + Double(to.y)) * ptToMMScale,
                    ))
                }
            }
            out.append(.stroke(width: thicknessPt * ptToMMScale))

        case let .glyph(codepoint, rotationDegrees):
            let radians = Double(rotationDegrees) * .pi / 180
            out.append(.setRotation(
                radians: radians,
                pivotX: originXPt * ptToMMScale,
                pivotY: originYPt * ptToMMScale,
            ))
            emitCenterAnchoredGlyph(
                codepoint: codepoint,
                cxPt: originXPt,
                cyPt: originYPt,
                sizePt: glyphSizePt,
                into: &out,
            )
            out.append(.setRotation(radians: 0, pivotX: 0, pivotY: 0))
        }
    }
}
