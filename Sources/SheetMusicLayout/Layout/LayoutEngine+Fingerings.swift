#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

// The fingerings of one chord (`TLayout::layoutFingering`, `tlayout.cpp:2232-2384`), placed once the chord is final.
// Chord-relative ones are centered on the chord's column and stacked outward from the chord's extreme note, the staff
// and — when beamed on that side — the stem tip, `fingeringMinDistance` 0.5 sp clear; a lone unbeamed note among other
// voices instead takes its fingering 1.5 sp from the note and 0.8 sp off its stem. A left-hand guitar fingering is
// right-aligned 0.5 sp left of its note. The stack is arithmetic from the chord's own extremes rather than MuseScore's
// skyline, so a tie or articulation on the same side is not cleared (`autoplace: false`: an obstacle, never lifted).

extension LayoutEngine {
    /// What the note-annotation pass needs about the measure and staff a voice stands in.
    struct NoteAnnotationContext {
        let measure: Measure
        let measureDuration: Fraction
        let division: Int
        let staffIndexInPart: Int
        let staffCountInPart: Int
        let lineGeometry: StaffLineGeometry
        /// Each emitted chord's measure-relative tick, keyed by its index in `out`.
        let chordTickByOutIndex: [Int: Int]
    }

    /// `Fingering::layoutType` CHORD styles stack above or below the chord; a left-hand guitar fingering stands beside
    /// its note; any other style is not drawn.
    private static func fingeringStyle(_ role: Fingering.Role) -> TextStyleType? {
        switch role {
        case .fingering: .fingering
        case .rightHandGuitar: .rhGuitarFingering
        case .stringNumber: .stringNumber
        case .leftHandGuitar: .lhGuitarFingering
        case .other: nil
        }
    }

    /// One fingering, typeset: its text block's size and first-line ascent.
    private struct FingeringBlock {
        let fingering: Fingering
        let note: LayoutChordNote
        let style: TextStyleType
        let rich: LayoutRichText?
        let font: LayoutFont
        let width: CGFloat
        let height: CGFloat
        let ascent: CGFloat

        init(_ fingering: Fingering, note: LayoutChordNote, style: TextStyleType, metrics: StaffMetrics) {
            self.fingering = fingering
            self.note = note
            self.style = style
            let overrides = fingering.fontOverrides
            rich = fingering.richText.map { LayoutRichText($0, style: style, overrides: overrides, metrics: metrics) }
            font = TextInkGeometry.font(for: style, overrides: overrides, metrics: metrics)
            let size = rich?.size ?? TextInkGeometry.typographicSize(text: fingering.text, font: font)
            width = size.width
            height = size.height
            ascent = rich?.lines.first?.ascent ?? FontMetrics.provider.ascent(font: font)
        }

        /// The height a stack reserves: a string number's circle adds its padding top and bottom.
        func stackHeight(sp: CGFloat) -> CGFloat {
            height + (style == .stringNumber ? 0.4 * sp : 0)
        }

        /// The block's `.staffText` origin (its bottom-left, `TextInkGeometry.rects` anchor (0, 1)) for a block
        /// centered vertically on `centerY`, left edge at `left`.
        func origin(left: CGFloat, centerY: CGFloat) -> CGPoint {
            // The first baseline lies one ascent below the block's top, so the origin lands on its bottom edge.
            let baseline = CGPoint(x: left, y: centerY - height / 2 + ascent)
            return rich.map { LayoutEngine.textPlacementOrigin(rich: $0, baseline: baseline, center: false) }
                ?? LayoutEngine.textPlacementOrigin(
                    text: fingering.text, font: font, baseline: baseline, center: false,
                )
        }
    }

    /// The facts of the emitted chord a fingering is placed against.
    private struct FingeringChord {
        let notes: [LayoutChordNote]
        let column: CGFloat
        let up: Bool
        let hasStem: Bool
        let isBeamed: Bool
        let stemTipY: CGFloat
        let hasVoices: Bool
        let topLimit: CGFloat
        let bottomLimit: CGFloat
    }

    static func emitFingerings(
        chord: Chord, outIndex: Int, context: NoteAnnotationContext, metrics: StaffMetrics,
        options: ScoreViewOptions, out: inout [LayoutElement], invisibleOut: inout [LayoutElement],
    ) {
        guard case let .chord(layoutNotes, duration, stem, stemOrigin, _, _, isBeamed, _, _, _, _) = out[outIndex]
        else { return }
        let sp = metrics.sp
        let sourceNotes = Array(chord.notes)
        // Low to high, MuseScore's chord note order.
        let notes = layoutNotes.filter { sourceNotes.indices.contains($0.noteID.noteIndexInChord) }
            .sorted { sourceNotes[$0.noteID.noteIndexInChord].pitch < sourceNotes[$1.noteID.noteIndexInChord].pitch }
        let blocks = notes.flatMap { note in
            sourceNotes[note.noteID.noteIndexInChord].fingerings.compactMap { fingering -> FingeringBlock? in
                guard fingering.elementProperties.visible || options.showsInvisibleElements,
                      let style = fingeringStyle(fingering.role)
                else { return nil }
                return FingeringBlock(fingering, note: note, style: style, metrics: metrics)
            }
        }
        guard !blocks.isEmpty else { return }

        let topLine = 2 * sp
        let hasStem = switch duration {
        case .whole, .measure: false
        default: true
        }
        let facts = FingeringChord(
            notes: notes, column: notes.first { !$0.mirror }?.origin.x ?? notes[0].origin.x, up: stem == .up,
            hasStem: hasStem, isBeamed: isBeamed, stemTipY: stemOrigin.y,
            hasVoices: FingeringGeometry.hasVoices(
                in: context.measure, chordTick: context.chordTickByOutIndex[outIndex] ?? 0,
                chordTicks: chord.duration.resolved(in: context.measureDuration).ticks(division: context.division),
                division: context.division, measureDuration: context.measureDuration,
            ),
            topLimit: min(topLine, (notes.map(\.origin.y).min() ?? topLine) - 0.5 * sp),
            bottomLimit: max(
                topLine + context.lineGeometry.height(sp: sp), (notes.map(\.origin.y).max() ?? topLine) + 0.5 * sp,
            ),
        )
        var elements = placeLeftHand(blocks.filter { $0.style == .lhGuitarFingering }, chord: facts, sp: sp)
        for side in [Placement.above, .below] {
            let sideBlocks = blocks.filter { block in
                block.style != .lhGuitarFingering && FingeringGeometry.side(
                    explicit: block.fingering.elementProperties.placement, chordUp: facts.up,
                    hasVoices: facts.hasVoices, staffIndexInPart: context.staffIndexInPart,
                    staffCountInPart: context.staffCountInPart,
                ) == side
            }
            elements += placeChordRelative(sideBlocks, side: side, chord: facts, sp: sp)
        }
        for (block, origin, side) in elements {
            emitFingering(block, origin: origin, side: side, sp: sp, out: &out, invisibleOut: &invisibleOut)
        }
    }

    /// Right-aligned left of the chord's leftmost note (with its accidental), each on its own note's line.
    private static func placeLeftHand(
        _ blocks: [FingeringBlock], chord: FingeringChord, sp: CGFloat,
    ) -> [(FingeringBlock, CGPoint, Placement)] {
        guard !blocks.isEmpty else { return [] }
        let leftmost = chord.notes.map { note in
            noteheadLeftEdge(note.origin.x, sp: sp) - (note.accidental == nil ? 0 : sp)
        }.min() ?? chord.column
        let rightEdge = leftmost - 0.5 * sp
        return blocks.map { block in
            (block, block.origin(left: rightEdge - block.width, centerY: block.note.origin.y), .above)
        }
    }

    /// One side's chord-relative fingerings: the tight ones beside their note, the rest stacked from the chord.
    private static func placeChordRelative(
        _ blocks: [FingeringBlock], side: Placement, chord: FingeringChord, sp: CGFloat,
    ) -> [(FingeringBlock, CGPoint, Placement)] {
        guard !blocks.isEmpty else { return [] }
        let above = side == .above
        // Above in note order, below reversed: the first is the one nearest the chord.
        let ordered = above ? blocks : blocks.reversed()
        let tight = chord.hasVoices && chord.notes.count == 1 && !chord.isBeamed
        var placed: [(FingeringBlock, CGPoint, Placement)] = []
        var stackable: [FingeringBlock] = []
        for block in ordered {
            guard tight, block.style != .stringNumber else {
                stackable.append(block)
                continue
            }
            let x = chord.column + (chord.hasStem ? (above ? -0.8 : 0.8) * sp : 0)
            let centerY = block.note.origin.y + (above ? -1.5 : 1.5) * sp
            placed.append((block, block.origin(left: x - block.width / 2, centerY: centerY), side))
        }
        guard !stackable.isEmpty else { return placed }
        let limit: CGFloat = if above {
            min(chord.topLimit, chord.isBeamed && chord.up ? chord.stemTipY : .infinity)
        } else {
            max(chord.bottomLimit, chord.isBeamed && !chord.up ? chord.stemTipY : -.infinity)
        }
        let centers = FingeringGeometry.stackedCenters(
            heights: stackable.map { $0.stackHeight(sp: sp) }, side: side, limit: limit, minDistance: 0.5 * sp,
        )
        for (block, centerY) in zip(stackable, centers) {
            placed.append((block, block.origin(left: chord.column - block.width / 2, centerY: centerY), side))
        }
        return placed
    }

    /// The fingering's `.staffText` (and a string number's circle) at `origin` plus its offset, visible or ghost.
    private static func emitFingering(
        _ block: FingeringBlock, origin: CGPoint, side: Placement, sp: CGFloat,
        out: inout [LayoutElement], invisibleOut: inout [LayoutElement],
    ) {
        let offset = block.fingering.elementProperties.offset
        let placed = CGPoint(x: origin.x + CGFloat(offset?.x ?? 0) * sp, y: origin.y + CGFloat(offset?.y ?? 0) * sp)
        let color = block.fingering.elementProperties.color
        let placement = TextPlacementMetadata(side: side, autoplace: false)
        var elements: [LayoutElement] = [.staffText(
            text: block.fingering.text, origin: placed, color: color, style: block.style, anchor: nil,
            placement: placement, properties: block.fingering.fontOverrides.fontOverrides, identity: nil,
            richText: block.rich,
        )]
        if block.style == .stringNumber {
            // `STRING_NUMBER`'s circle frame: padding 0.2 sp, line 0.1 sp (`styledef.cpp:996-1003`).
            var box = CGRect(x: placed.x, y: placed.y - block.height, width: block.width, height: block.height)
                .insetBy(dx: -0.2 * sp, dy: -0.2 * sp)
            if box.width < box.height { box = box.insetBy(dx: -(box.height - box.width) / 2, dy: 0) }
            elements.append(.figure(
                kind: .stringNumber,
                figure: LayoutFigure(primitives: [.ellipse(rect: box, fill: false, width: 0.1 * sp)]),
                color: color, placement: placement,
            ))
        }
        if block.fingering.elementProperties.visible {
            out.append(contentsOf: elements)
        } else {
            invisibleOut.append(contentsOf: elements)
        }
    }
}
