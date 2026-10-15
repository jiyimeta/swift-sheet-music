#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutEngine {
    /// A fret diagram centered on `x` (its beat's notehead), its bottom `fretY` 1 sp above the staff's top line, and
    /// the chord symbol nested in it centered 0.5 sp above its ink. Neither is lifted by autoplace: the symbol has to
    /// stay with its diagram, and MuseScore's own autoplace of the pair is not modeled.
    static func fretDiagramElements(
        _ diagram: FretDiagram, x: CGFloat, staffTopY: CGFloat, metrics: StaffMetrics,
        chordSymbolCase: ChordSymbolCaseStyle = .museScoreDefaults,
    ) -> [LayoutElement] {
        let sp = metrics.sp
        let built = FretDiagramGeometry.figure(diagram, sp: sp)
        let figure = built.figure.translated(
            dx: x - built.gridCenterX, dy: staffTopY - FretDiagramGeometry.staffGapSp * sp - built.bottomY,
        )
        let placement = TextPlacementMetadata(side: .above, autoplace: false)
        var elements: [LayoutElement] = [.figure(
            kind: .fretDiagram, figure: figure, color: diagram.elementProperties.color, placement: placement,
        )]
        if let harmony = diagram.harmony {
            let runs = HarmonyRendering.runs(for: harmony, metrics: metrics, style: chordSymbolCase)
            let width = HarmonyRendering.width(of: runs)
            let font = TextInkGeometry.font(for: harmony.styleType, overrides: harmony.properties, metrics: metrics)
            let height = FontMetrics.provider.ascent(font: font) + FontMetrics.provider.descent(font: font)
            let top = figure.ink.isEmpty ? staffTopY - FretDiagramGeometry.staffGapSp * sp : figure.ink.minY
            elements.append(.harmony(LayoutHarmony(
                harmony: harmony, anchorX: Double(x - CGFloat(width) / 2), y: Double(top - 0.5 * sp - height / 2),
                runs: runs, width: width, anchor: nil, placement: placement,
            )))
        }
        return elements
    }
}
