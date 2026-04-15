#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum StemRenderer {
    static func draw(
        context: inout GraphicsContext,
        notes: [LayoutChordNote],
        direction: StemDirection,
        duration: NoteDuration,
        isBeamed: Bool,
        metrics: StaffMetrics
    ) {
        guard !notes.isEmpty else { return }
        // Whole notes are stemless.
        if case .whole = duration { return }
        // Use one canonical note origin for the x anchor; stem y-range
        // is derived from min/max notehead y.
        let xs = notes.map(\.origin.x)
        let ys = notes.map(\.origin.y)
        let headRadius = metrics.sp * 0.65
        let xMin = xs.min() ?? 0
        let xMax = xs.max() ?? 0
        let yTop = ys.min() ?? 0  // higher on screen (smaller y)
        let yBot = ys.max() ?? 0
        let xStem: CGFloat
        let startY: CGFloat
        let endY: CGFloat
        switch direction {
        case .up:
            xStem = xMax + headRadius
            startY = yTop - metrics.defaultStemLength
            endY = yBot
        case .down:
            xStem = xMin - headRadius
            startY = yTop
            endY = yBot + metrics.defaultStemLength
        }
        var path = Path()
        path.move(to: CGPoint(x: xStem, y: startY))
        path.addLine(to: CGPoint(x: xStem, y: endY))
        context.stroke(
            path,
            with: .color(.primary),
            lineWidth: metrics.stemThickness
        )
        // Beamed chords get their flag replaced by a BeamRenderer bar —
        // skip the flag glyph here.
        if isBeamed { return }
        // Flag for isolated short notes.
        if let flag = flagGlyph(for: duration, direction: direction) {
            let flagY = direction == .up ? startY : endY
            context.drawGlyph(
                flag,
                at: CGPoint(x: xStem, y: flagY),
                size: metrics.glyphFontSize
            )
        }
    }

    private static func flagGlyph(
        for dur: NoteDuration, direction: StemDirection
    ) -> Character? {
        switch (dur, direction) {
        case (.eighth, .up): return SMuFLGlyph.flag8thUp
        case (.eighth, .down): return SMuFLGlyph.flag8thDown
        case (.sixteenth, .up): return SMuFLGlyph.flag16thUp
        case (.sixteenth, .down): return SMuFLGlyph.flag16thDown
        case (.thirtySecond, .up): return SMuFLGlyph.flag32ndUp
        case (.thirtySecond, .down): return SMuFLGlyph.flag32ndDown
        case (.sixtyFourth, .up): return SMuFLGlyph.flag64thUp
        case (.sixtyFourth, .down): return SMuFLGlyph.flag64thDown
        default: return nil
        }
    }
}
#endif
