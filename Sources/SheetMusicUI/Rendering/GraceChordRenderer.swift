import CoreGraphics
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, iOS 16.0, *)
extension ScoreLayerBuilder {
    // swiftlint:disable:next function_parameter_count
    /// Draw a `LayoutElement.graceChord` by recursively reusing the
    /// main-chord renderers at a `mag`-scaled `StaffMetrics`.
    /// Acciaccatura adds a stroked slash line across the stem.
    static func drawGraceChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        hasSlash: Bool,
        mag: CGFloat,
        base: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer
    ) {
        // Build a scaled `StaffMetrics` so notehead / stem / flag
        // widths follow `mag`. Every dimension on `StaffMetrics`
        // derives from `sp = staffSize/4`, so feeding `staffSize *
        // mag` shrinks every glyph proportionally. The grace's
        // y-positions (already in parent-staff coordinates from the
        // layout step) are passed through untouched, so the glyphs
        // sit on the parent staff — only the GLYPH sizes shrink.
        let scaled = StaffMetrics(staffSize: metrics.staffHeight * mag)
        drawChord(
            notes: notes, duration: duration, stem: stem,
            stemOrigin: stemOrigin, isBeamed: false,
            base: base, metrics: scaled, height: height,
            context: &context, into: parent
        )
        guard hasSlash else { return }
        drawAcciaccaturaSlash(
            notes: notes, stem: stem,
            base: base, scaled: scaled, height: height,
            into: parent
        )
    }

    /// Acciaccatura slash. Mirrors `TLayout::layoutStemSlash`
    /// (`engraving/rendering/score/tlayout.cpp:5249`): a stroked line
    /// crossing the stem at `stemSlashAngle = 40°`, starting
    /// `stemSlashPosition = 2 sp` from the stem tip, with thickness
    /// `stemSlashThickness = 0.125 sp`. We use the no-hook geometry
    /// from MuseScore's `else` branch: span the slash one notehead
    /// width across the stem, optically centred by subtracting the
    /// stem width from the right hang.
    private static func drawAcciaccaturaSlash(
        notes: [LayoutChordNote],
        stem: StemDirection,
        base: CGPoint,
        scaled: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        guard let xMin = notes.map(\.origin.x).min(),
              let xMax = notes.map(\.origin.x).max(),
              let yTop = notes.map(\.origin.y).min(),
              let yBot = notes.map(\.origin.y).max()
        else { return }
        // Mirror `StemRenderer.draw` for stem geometry so the slash
        // anchors on the same line the stem renderer drew.
        let stemAttachDx = scaled.sp * 0.59
        let up: CGFloat = stem == .up ? -1 : 1
        let stemX: CGFloat
        let stemTipY: CGFloat
        switch stem {
        case .up:
            stemX = xMax + stemAttachDx
            stemTipY = yTop - scaled.defaultStemLength
        case .down:
            stemX = xMin - stemAttachDx
            stemTipY = yBot + scaled.defaultStemLength
        }
        // Style values from MuseScore Sid::stemSlash* (defaults at
        // `style/styledef.cpp:242-244`).
        let slashPosition = scaled.sp * 2.0
        let slashAngle = 40.0 * .pi / 180.0
        let slashThickness = scaled.sp * 0.125
        let stemWidth = scaled.sp * 0.12
        // `noteHeadWidth() * mag / 2` in MuseScore. Bravura's
        // `noteheadBlack` is 1.18 sp wide; halved gives 0.59 sp in
        // scaled-sp units (`scaled.sp = parentSp * mag`).
        let leftHang = scaled.sp * 0.59
        // `(noteHeadWidth() * mag / 2) - stemWidth`. Pulling rightHang
        // inward by stemWidth keeps the slash optically centred ON
        // the stem instead of on the geometric column axis.
        let rightHang = leftHang - stemWidth
        // `stem.bbox().right()` ≈ `stemX + stemWidth/2`.
        let stemRight = stemX + stemWidth / 2
        let startX = stemRight - leftHang
        let startY = stemTipY - up * slashPosition
        let endX = stemRight + rightHang
        let endY = startY + up * (endX - startX) * tan(slashAngle)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: base.x + startX, y: base.y + startY))
        path.addLine(to: CGPoint(x: base.x + endX, y: base.y + endY))
        parent.addSublayer(strokeLayer(
            path: path, height: height, lineWidth: slashThickness
        ))
    }
}
