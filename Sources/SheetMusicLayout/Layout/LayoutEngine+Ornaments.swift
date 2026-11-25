#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

// A chord's ornaments (`Chord.ornaments`), placed once every voice of the bar is laid out and beamed.
//
// MuseScore's `ChordLayout::layoutArticulations2` (`rendering/score/chordlayout.cpp`) puts every mark that does not hug
// the note outside the chord's heads, stem and close marks and outside the staff, `articulationMinDistance` apart, and
// `Autoplace::autoplaceSegmentElement` then clears whatever else its ink overlaps. Ornaments are the outermost here:
// the model keeps them apart from `Chord.articulations`, so their order among those is not known. The slur pass
// (`layoutArticulations3`) has no counterpart — a slur clears the chords' own extents, as it does for articulations.

/// A chord that carries ornaments, as the ornament pass finds it.
struct OrnamentHost {
    let ornaments: [ChordOrnament]
    /// The chord's own slot, which every ornament it carries names (`ScoreElementID.ornament`).
    let anchor: VoiceElementID
    /// The chord's column: the x its unmirrored heads stand at.
    let columnX: CGFloat
    /// The chord as first placed — what a hidden chord, which is in no buffer, is measured by.
    let element: LayoutElement
    /// Where the chord stands in the elements, its stem final; `nil` for a hidden one.
    let outIndex: Int?
    /// The indices of the chord's articulations in the elements.
    let articulations: Range<Int>
    /// Whether another voice sounds under the chord (`Measure::hasVoices`).
    let hasVoices: Bool
    /// Whether the chord is drawn on a sibling staff, and so placed in that staff's frame (`MovedChordPlacement`).
    let isMoved: Bool
}

extension LayoutEngine {
    /// `articulationMinDistance`, `propertyDistance`, `propertyDistanceHead` and `propertyDistanceStem`: 0.4 sp each.
    static let ornamentDistanceSp: CGFloat = 0.4
    /// `layoutOrnament`'s `vertMargin` between the ornament and its accidental.
    static let ornamentAccidentalMarginSp: CGFloat = 0.35
    /// `layoutOrnament`'s `ornamentAccidentalMag`.
    static let ornamentAccidentalMag: CGFloat = 0.6

    /// Which side of the chord an ornament goes: the side the author stored, else MuseScore's automatic one
    /// (`ChordLayout::layoutArticulations`) — with several voices under the chord the stem's side, else above for an
    /// upper voice and below for a lower one.
    static func ornamentSide(
        _ ornament: ChordOrnament, stem: StemDirection, voiceIndex: Int, hasVoices: Bool,
    ) -> Placement {
        switch ornament.anchor {
        case .top: return .above
        case .bottom: return .below
        case .auto, nil: break
        }
        if let placement = ornament.elementProperties.placement { return placement }
        if hasVoices { return stem == .up ? .above : .below }
        return voiceIndex.isMultiple(of: 2) ? .above : .below
    }

    /// An ornament's glyphs and accidentals, its own ink centered on x 0 with the baseline at y 0; `nil` for a kind
    /// that is not drawn. The accidentals are the ones the model carries: MuseScore writes an ornament's accidentals
    /// into the file, so none is derived from the key or the bar here.
    static func ornamentFigure(_ ornament: ChordOrnament, sp: CGFloat, mag: CGFloat) -> LayoutFigure? {
        guard let codepoints = OrnamentGlyph.codepoints(ornament.kind) else { return nil }
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4 * sp * mag)
        var pen: CGFloat = 0
        var primitives: [LayoutFigure.Primitive] = []
        for codepoint in codepoints {
            primitives.append(ornamentRun(codepoint, font: font, baseline: CGPoint(x: pen, y: 0)))
            guard let scalar = Unicode.Scalar(codepoint) else { continue }
            pen += FontMetrics.provider.typographicWidth(text: String(Character(scalar)), font: font)
        }
        let glyphs = LayoutFigure(primitives: primitives)
        let centered = glyphs.translated(dx: -glyphs.ink.midX, dy: 0)
        var all = centered.primitives
        let accidentalFont = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: 4 * sp * mag * ornamentAccidentalMag,
        )
        let margin = ornamentAccidentalMarginSp * sp
        for (accidental, above) in [(ornament.accidentalAbove, true), (ornament.accidentalBelow, false)] {
            guard let accidental else { continue }
            let mark = LayoutFigure(primitives: [
                ornamentRun(AccidentalGlyph.codepoint(accidental), font: accidentalFont, baseline: .zero),
            ])
            let dy = above
                ? centered.ink.minY - margin - mark.ink.maxY
                : centered.ink.maxY + margin - mark.ink.minY
            all += mark.translated(dx: -mark.ink.midX, dy: dy).primitives
        }
        return LayoutFigure(primitives: all)
    }

    private static func ornamentRun(
        _ codepoint: UInt32, font: LayoutFont, baseline: CGPoint,
    ) -> LayoutFigure.Primitive {
        .run(
            LayoutRichTextPositionedRun(content: .symbol(codepoint: codepoint), font: font, baseline: baseline),
            rotation: 0, pivot: baseline,
        )
    }

    /// Places every host's ornaments, appending each as a `.figure` to `out` — to `invisibleOut`, where they take no
    /// room, when hidden — and lifts the fermatas and tuplet markings they would run into, which MuseScore lays out
    /// after them. A chord drawn on a sibling staff takes its ornaments along, as it does its articulations: each names
    /// the chord (`ownerSlot`).
    static func emitOrnaments(
        _ hosts: [OrnamentHost], movedChords: [VoiceSlot: MovedChordPlacement], lineGeometry: StaffLineGeometry,
        metrics: StaffMetrics, options: ScoreViewOptions,
        out: inout [LayoutElement], invisibleOut: inout [LayoutElement],
    ) {
        guard !hosts.isEmpty else { return }
        let obstacles = ornamentObstacles(in: out, movedChords: movedChords)
        for host in hosts {
            for placed in ornamentFigures(
                of: host, elements: out, obstacles: host.isMoved ? [] : obstacles,
                lineGeometry: lineGeometry, metrics: metrics, options: options,
            ) {
                let element = LayoutElement.figure(
                    kind: .ornament(anchor: host.anchor, kind: placed.ornament.kind), figure: placed.figure,
                    color: placed.ornament.elementProperties.color,
                )
                guard placed.ornament.elementProperties.visible else {
                    invisibleOut.append(element)
                    continue
                }
                out.append(element)
                clearOrnament(placed.figure.ink, side: placed.side, metrics: metrics, elements: &out)
            }
        }
    }

    private struct PlacedOrnament {
        let ornament: ChordOrnament
        let figure: LayoutFigure
        let side: Placement
    }

    private static func ornamentFigures(
        of host: OrnamentHost, elements: [LayoutElement], obstacles: [LayoutElement], lineGeometry: StaffLineGeometry,
        metrics: StaffMetrics, options: ScoreViewOptions,
    ) -> [PlacedOrnament] {
        let sp = metrics.sp
        let chord = host.outIndex.map { elements[$0] } ?? host.element
        guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, mag) = chord, !notes.isEmpty else { return [] }
        let distance = ornamentDistanceSp * sp * mag
        var limits = ornamentLimits(
            chord: chord, articulations: host.articulations.map { elements[$0] }, lineGeometry: lineGeometry,
            metrics: metrics,
        )
        var placed: [PlacedOrnament] = []
        for ornament in host.ornaments {
            let properties = ornament.elementProperties
            guard properties.visible || options.showsInvisibleElements,
                  let figure = ornamentFigure(ornament, sp: sp, mag: mag)
            else { continue }
            let side = ornamentSide(
                ornament, stem: stem, voiceIndex: host.anchor.voiceIndex, hasVoices: host.hasVoices,
            )
            let above = side == .above
            let dy = above ? limits.top - distance - figure.ink.maxY : limits.bottom + distance - figure.ink.minY
            var at = figure.translated(
                dx: host.columnX + CGFloat(properties.offset?.x ?? 0) * sp,
                dy: dy + CGFloat(properties.offset?.y ?? 0) * sp,
            )
            if properties.autoplace != false {
                // Autoplace lifts an ornament pushed into its chord back out, so an offset shows only away from it.
                let own = above ? limits.top - distance - at.ink.maxY : limits.bottom + distance - at.ink.minY
                at = at.translated(dx: 0, dy: above ? min(0, own) : max(0, own))
                at = at.translated(
                    dx: 0,
                    dy: ornamentShift(at.ink, side: side, obstacles: obstacles, distance: distance, metrics: metrics),
                )
            }
            placed.append(PlacedOrnament(ornament: ornament, figure: at, side: side))
            // A hidden ornament takes no room (`layoutArticulations2` advances for a visible one only).
            guard properties.visible else { continue }
            if above {
                limits.top = min(limits.top, at.ink.minY)
            } else {
                limits.bottom = max(limits.bottom, at.ink.maxY)
            }
        }
        return placed
    }

    /// How far out the chord reaches on each side: the staff, the heads, the stem with its flag or beam, and the marks
    /// already on it.
    private static func ornamentLimits(
        chord: LayoutElement, articulations: [LayoutElement], lineGeometry: StaffLineGeometry, metrics: StaffMetrics,
    ) -> (top: CGFloat, bottom: CGFloat) {
        let sp = metrics.sp
        var top = 2 * sp
        var bottom = 2 * sp + lineGeometry.height(sp: sp)
        guard case let .chord(notes, duration, stem, _, _, _, isBeamed, _, _, _, mag) = chord
        else { return (top, bottom) }
        let headHalf = 0.5 * sp * mag
        top = min(top, (notes.map(\.origin.y).min() ?? top) - headHalf)
        bottom = max(bottom, (notes.map(\.origin.y).max() ?? bottom) + headHalf)
        let base = DurationInterpretation.splitNote(duration).base
        if let geometry = ornamentChordStem(chord, metrics: metrics) {
            let flag = isBeamed ? nil : FlagGlyph.codepoint(duration: base, stem: stem).flatMap {
                FontMetrics.provider.glyphPathBoundingBox(
                    font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 4 * sp * mag),
                    codepoint: UInt16(truncatingIfNeeded: $0),
                )
            }
            switch stem {
            case .up: top = min(top, geometry.startY - max(0, flag?.maxY ?? 0))
            case .down: bottom = max(bottom, geometry.endY + max(0, -(flag?.minY ?? 0)))
            }
        }
        for case let .articulation(kind, origin, isAbove, _) in articulations where kind != .chokeCymbal {
            let ink = LayoutElementShape.smuflGlyphRect(
                codepoint: ArticulationGlyph.codepoint(kind: kind, isAbove: isAbove), center: origin, sp: sp,
            )
            if isAbove { top = min(top, ink.minY) } else { bottom = max(bottom, ink.maxY) }
        }
        return (top, bottom)
    }

    /// The stem a chord is drawn with, to its beam when it has one; `nil` for a stemless value.
    private static func ornamentChordStem(_ chord: LayoutElement, metrics: StaffMetrics) -> StemGeometry.Result? {
        guard case let .chord(notes, duration, stem, stemOrigin, _, _, isBeamed, _, stemExtension, _, mag) = chord
        else { return nil }
        switch DurationInterpretation.splitNote(duration).base {
        case .breve, .whole, .measure: return nil
        default: break
        }
        return StemGeometry.compute(
            noteOrigins: notes.map(\.origin), direction: stem, beamY: isBeamed ? stemOrigin.y : nil,
            defaultStemLength: metrics.defaultStemLength * mag, stemExtension: stemExtension, sp: metrics.sp * mag,
        )
    }

    /// What an ornament must not be drawn over: the chords, grace chords, rests, beams, articulations and fingerings of
    /// the bar. Those of a chord drawn on a sibling staff are placed in that staff's frame, so they are left out.
    private static func ornamentObstacles(
        in elements: [LayoutElement], movedChords: [VoiceSlot: MovedChordPlacement],
    ) -> [LayoutElement] {
        elements.filter { element in
            if !movedChords.isEmpty, let slot = ownerSlot(of: element), movedChords[slot] != nil { return false }
            switch element {
            case .chord, .graceChord, .rest, .beam, .articulation: return true
            case let .staffText(_, _, _, style, _, _, _, _, _):
                return [.fingering, .rhGuitarFingering, .lhGuitarFingering, .stringNumber].contains(style)
            case let .figure(kind, _, _, _): return kind == .stringNumber
            default: return false
            }
        }
    }

    /// How far an ornament whose ink is `ink` still has to move to clear every obstacle its ink overlaps horizontally —
    /// no horizontal clearance, as MuseScore gives articulations.
    private static func ornamentShift(
        _ ink: CGRect, side: Placement, obstacles: [LayoutElement], distance: CGFloat, metrics: StaffMetrics,
    ) -> CGFloat {
        var shift: CGFloat = 0
        for rect in obstacles.flatMap({ ornamentObstacleRects($0, overlapping: ink, metrics: metrics) }) {
            guard rect.maxX > ink.minX, rect.minX < ink.maxX else { continue }
            shift = side == .above
                ? min(shift, rect.minY - distance - ink.maxY)
                : max(shift, rect.maxY + distance - ink.minY)
        }
        return shift
    }

    /// The rects of one obstacle: its skyline shape, except for a chord, whose skyline shape gives every chord an
    /// unbeamed stem — a whole note included — and a beam, whose skyline rect is its whole slope's box.
    private static func ornamentObstacleRects(
        _ element: LayoutElement, overlapping ink: CGRect, metrics: StaffMetrics,
    ) -> [CGRect] {
        switch element {
        case .chord: ornamentChordRects(element, metrics: metrics)
        case .beam: ornamentBeamRects(element, overlapping: ink, metrics: metrics)
        default: LayoutElementShape.shape(for: element, id: 0, xOffset: 0, metrics: metrics)?.rects.map(\.rect) ?? []
        }
    }

    /// A chord's heads, accidentals and ties as its skyline shape has them, with the stem it is drawn with.
    private static func ornamentChordRects(_ chord: LayoutElement, metrics: StaffMetrics) -> [CGRect] {
        guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, mag) = chord else { return [] }
        let sp = metrics.sp
        var rects: [CGRect] = []
        for note in notes {
            rects.append(LayoutElementShape.noteheadRect(
                center: CGPoint(x: note.origin.x + note.mirrorDx(stem: stem, sp: sp * mag), y: note.origin.y),
                mag: mag, sp: sp,
            ))
            if note.accidental != nil {
                rects.append(CGRect(
                    x: note.origin.x - sp * 2.2, y: note.origin.y - sp * 1.5, width: sp * 1.4, height: sp * 3,
                ))
            }
        }
        if let geometry = ornamentChordStem(chord, metrics: metrics) {
            rects.append(CGRect(
                x: geometry.xStem - sp * 0.1, y: geometry.startY,
                width: sp * 0.2, height: geometry.endY - geometry.startY,
            ))
        }
        if let apex = LayoutElementShape.aboveTieApexY(notes: notes, stem: stem, sp: sp),
           let left = notes.map(\.origin.x).min(), let right = notes.map(\.origin.x).max()
        {
            rects.append(CGRect(x: left, y: apex, width: max(sp, right - left), height: sp * 0.6))
        }
        return rects
    }

    /// A beam where it passes the ornament.
    private static func ornamentBeamRects(
        _ beam: LayoutElement, overlapping ink: CGRect, metrics: StaffMetrics,
    ) -> [CGRect] {
        guard case let .beam(from, to, direction, level, _) = beam else { return [] }
        let left = max(ink.minX, min(from.x, to.x))
        let right = min(ink.maxX, max(from.x, to.x))
        guard left < right, to.x != from.x else { return [] }
        let edge = BeamGeometry.levelOffsetDy(level: level, stemDirection: direction, sp: metrics.sp)
        let thickness = BeamGeometry.beamThicknessSp * metrics.sp * (direction == .up ? 1 : -1)
        let ys = [left, right].flatMap { x -> [CGFloat] in
            let y = from.y + (to.y - from.y) * (x - from.x) / (to.x - from.x) + edge
            return [y, y + thickness]
        }
        guard let minY = ys.min(), let maxY = ys.max() else { return [] }
        return [CGRect(x: left, y: minY, width: right - left, height: maxY - minY)]
    }

    /// Moves the fermatas and tuplet markings on `side` that an ornament's ink runs into out beyond it.
    private static func clearOrnament(
        _ ink: CGRect, side: Placement, metrics: StaffMetrics, elements: inout [LayoutElement],
    ) {
        let sp = metrics.sp
        let distance = ornamentDistanceSp * sp
        let above = side == .above
        let staffMidY = metrics.staffHeight / 2 + 2 * sp
        func shift(_ rect: CGRect) -> CGFloat {
            guard rect.maxX > ink.minX, rect.minX < ink.maxX else { return 0 }
            return above ? min(0, ink.minY - distance - rect.maxY) : max(0, ink.maxY + distance - rect.minY)
        }
        for index in elements.indices {
            switch elements[index] {
            case let .fermata(subtype, origin, anchor) where (origin.y < staffMidY) == above:
                let dy = shift(LayoutElementShape.smuflGlyphRect(
                    codepoint: FermataGlyph.codepoint(forSubtype: subtype), center: origin, sp: sp,
                ))
                guard dy != 0 else { continue }
                elements[index] = .fermata(
                    subtype: subtype, origin: CGPoint(x: origin.x, y: origin.y + dy), anchor: anchor,
                )
            case let .tupletLabel(from, to, text, hasBracket, isAbove, tupletID) where isAbove == above:
                let dy = shift(tupletRect(from: from, to: to, hasBracket: hasBracket, ink: ink, sp: sp))
                guard dy != 0 else { continue }
                elements[index] = .tupletLabel(
                    fromOrigin: CGPoint(x: from.x, y: from.y + dy), toOrigin: CGPoint(x: to.x, y: to.y + dy),
                    text: text, hasBracket: hasBracket, isAbove: isAbove, tupletID: tupletID,
                )
            default:
                continue
            }
        }
    }

    /// The part of a tuplet marking an ornament can run into: where it passes the ornament for a bracket, its number
    /// alone without one. 1.5 sp tall, as its skyline shape is.
    private static func tupletRect(
        from: CGPoint, to: CGPoint, hasBracket: Bool, ink: CGRect, sp: CGFloat,
    ) -> CGRect {
        let minX = min(from.x, to.x), maxX = max(from.x, to.x)
        let half = 0.75 * sp
        guard hasBracket, maxX > minX else {
            let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
            return CGRect(x: mid.x - half, y: mid.y - half, width: 2 * half, height: 2 * half)
        }
        let x = min(max(ink.midX, minX), maxX)
        let y = from.y + (to.y - from.y) * (x - from.x) / (to.x - from.x)
        return CGRect(x: minX, y: y - half, width: maxX - minX, height: 2 * half)
    }
}
