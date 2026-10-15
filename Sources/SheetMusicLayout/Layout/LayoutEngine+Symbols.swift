#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// A `<Symbol>` as a figure: its SMuFL glyph, baseline-left at `origin` (`TLayout::layoutSymbol` aligns it
    /// LEFT / BASELINE). With a score font of its own it is `4 sp × symbolsSize` and turned by `symbolAngle` degrees
    /// about its ink's center (`EngravingFont::draw`); without, the score font's normal 4 sp and upright
    /// (`TDraw::draw(Symbol)`). A name the by-name table lacks draws nothing.
    static func symbolFigure(for symbol: EngravingSymbol, origin: CGPoint, sp: CGFloat) -> LayoutFigure? {
        guard let codepoint = SMuFLCodepoint.byName(symbol.name) else { return nil }
        let ownFont = symbol.scoreFont != nil
        let size = 4 * sp * CGFloat(ownFont ? symbol.size ?? 1 : 1)
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: size)
        let run = LayoutRichTextPositionedRun(content: .symbol(codepoint: codepoint), font: font, baseline: origin)
        let rotation = ownFont ? CGFloat((symbol.angle ?? 0) * .pi / 180) : 0
        guard rotation != 0 else { return LayoutFigure(primitives: [.run(run, rotation: 0, pivot: origin)]) }
        let upright = LayoutFigure(primitives: [.run(run, rotation: 0, pivot: origin)]).ink
        let pivot = CGPoint(x: upright.midX, y: upright.midY)
        return LayoutFigure(primitives: [.run(run, rotation: rotation, pivot: pivot)])
    }

    /// The left edge of a notehead centered on `x`: where a segment's or a note's symbol starts.
    static func noteheadLeftEdge(_ x: CGFloat, sp: CGFloat) -> CGFloat {
        x - GuitarBendGeometry.noteheadWidthSp / 2 * sp
    }

    /// Each note's `<Symbol>`s, placed once the chords are final (after beaming and mirroring): baseline-left at the
    /// note's left edge on the note's own line, moved by the symbol's offset. Hidden ones are ghosts when the options
    /// ask for invisible elements.
    static func emitNoteAnnotations(
        voice: Voice, chordOutIndex: [Int: Int], metrics: StaffMetrics, options: ScoreViewOptions,
        out: inout [LayoutElement], invisibleOut: inout [LayoutElement],
    ) {
        let sp = metrics.sp
        for (elementIndex, outIndex) in chordOutIndex.sorted(by: { $0.key < $1.key }) {
            guard voice.elements.indices.contains(elementIndex),
                  case let .chord(chord) = voice.elements[elementIndex],
                  chord.notes.contains(where: { !$0.symbols.isEmpty }),
                  out.indices.contains(outIndex),
                  case let .chord(layoutNotes, _, _, _, _, _, _, _, _, _, _) = out[outIndex]
            else { continue }
            let notes = Array(chord.notes)
            for layoutNote in layoutNotes {
                let index = layoutNote.noteID.noteIndexInChord
                guard notes.indices.contains(index) else { continue }
                for symbol in notes[index].symbols where symbol.visible || options.showsInvisibleElements {
                    let offset = symbol.elementProperties.offset
                    let origin = CGPoint(
                        x: noteheadLeftEdge(layoutNote.origin.x, sp: sp) + CGFloat(offset?.x ?? 0) * sp,
                        y: layoutNote.origin.y + CGFloat(offset?.y ?? 0) * sp,
                    )
                    guard let figure = symbolFigure(for: symbol, origin: origin, sp: sp) else { continue }
                    let element = LayoutElement.figure(
                        kind: .symbol, figure: figure, color: symbol.elementProperties.color,
                    )
                    if symbol.visible { out.append(element) } else { invisibleOut.append(element) }
                }
            }
        }
    }
}
