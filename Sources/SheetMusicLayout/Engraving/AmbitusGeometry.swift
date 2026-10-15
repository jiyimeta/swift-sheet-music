#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// An `<Ambitus>`: two noteheads on the rows of the range's pitches, the accidentals the key calls for hanging to their
/// left, a line between them and the ledger lines each head needs (`TLayout::layoutAmbitus`, `tlayout.cpp:629-761`;
/// `TDraw::draw(Ambitus)`, `tdraw.cpp:451-498`).
///
/// The horizontal arrangement depends on the heads, the mirror and the accidentals only — the rows' difference decides
/// whether the accidentals collide, and that difference is the same under every clef — so the header column it takes
/// (`columnWidth`) is known before the clef in force is. Like MuseScore's bbox, the column leaves out the ledger lines'
/// overhang.
enum AmbitusGeometry {
    /// `Ambitus::LINEOFFSET_DEFAULT`: the line stops this many spatiums short of each head's center.
    static let lineOffsetSp: CGFloat = 0.8
    /// `Ambitus::LINEWIDTH_DEFAULT`.
    static let defaultLineWidthSp: CGFloat = 0.12
    /// `Sid::ledgerLineLength` / `Sid::ledgerLineWidth` (`styledef.cpp:238-239`): the style values the ambitus draws
    /// its ledger lines with, not a chord's.
    static let ledgerLengthSp: CGFloat = 0.33
    static let ledgerWidthSp: CGFloat = 0.16
    /// `Sid::accidentalNoteDistance`.
    static let accidentalNoteDistanceSp: CGFloat = 0.25
    /// `Sid::ambitusMargin`: the padding MuseScore puts on each side of the ambitus segment.
    static let marginSp: CGFloat = 0.5

    /// Where the parts go, x from the leftmost head's left edge, y as the difference of rows.
    private struct Arrangement {
        let headCodepoint: UInt32
        let headWidth: CGFloat
        let topHeadX: CGFloat
        let bottomHeadX: CGFloat
        let topAccidental: (codepoint: UInt32, x: CGFloat)?
        let bottomAccidental: (codepoint: UInt32, x: CGFloat)?

        /// The heads' and accidentals' horizontal extent — MuseScore's bbox.
        var span: ClosedRange<CGFloat> {
            let lefts = [topHeadX, bottomHeadX] + [topAccidental?.x, bottomAccidental?.x].compactMap(\.self)
            let right = max(topHeadX, bottomHeadX) + headWidth
            return (lefts.min() ?? 0) ... right
        }
    }

    /// The header room an ambitus takes: its heads and accidentals plus `ambitusMargin` before what follows.
    static func columnWidth(_ ambitus: Ambitus, key: Int, sp: CGFloat) -> CGFloat {
        let span = arrangement(ambitus, key: key, rowDifference: rowDifference(ambitus), sp: sp).span
        return span.upperBound - span.lowerBound + marginSp * sp
    }

    /// The ambitus drawn with its bbox's left edge at `columnX`; `staffTopY` is the staff's top line.
    static func figure(
        _ ambitus: Ambitus, clef: NotatedClef, key: Int, columnX: CGFloat, staffTopY: CGFloat, lineCount: Int,
        sp: CGFloat,
    ) -> LayoutFigure {
        let topY = row(pitch: ambitus.topPitch, tpc: ambitus.topTpc, clef: clef, staffTopY: staffTopY, sp: sp)
            ?? staffTopY
        let bottomY = row(pitch: ambitus.bottomPitch, tpc: ambitus.bottomTpc, clef: clef, staffTopY: staffTopY, sp: sp)
            ?? staffTopY + CGFloat(lineCount - 1) * sp
        let parts = arrangement(ambitus, key: key, rowDifference: (bottomY - topY) / sp, sp: sp)
        let dx = columnX - parts.span.lowerBound
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4 * sp)
        func glyph(_ codepoint: UInt32, x: CGFloat, y: CGFloat) -> LayoutFigure.Primitive {
            let baseline = CGPoint(x: x + dx, y: y)
            let run = LayoutRichTextPositionedRun(
                content: .symbol(codepoint: codepoint), font: font, baseline: baseline,
            )
            return .run(run, rotation: 0, pivot: baseline)
        }
        var primitives = [
            glyph(parts.headCodepoint, x: parts.topHeadX, y: topY),
            glyph(parts.headCodepoint, x: parts.bottomHeadX, y: bottomY),
        ]
        if let accidental = parts.topAccidental {
            primitives.append(glyph(accidental.codepoint, x: accidental.x, y: topY))
        }
        if let accidental = parts.bottomAccidental {
            primitives.append(glyph(accidental.codepoint, x: accidental.x, y: bottomY))
        }
        let half = parts.headWidth / 2
        if ambitus.hasLine {
            let from = CGPoint(x: parts.topHeadX + half + dx, y: topY)
            let to = CGPoint(x: parts.bottomHeadX + half + dx, y: bottomY)
            let width = CGFloat(ambitus.lineWidth.map { CGFloat($0) } ?? defaultLineWidthSp) * sp
            primitives.append(shortenedLine(from: from, to: to, by: lineOffsetSp * sp, width: width))
        }
        primitives += ledgerLines(
            headX: parts.topHeadX + dx, headWidth: parts.headWidth, headY: topY, above: true,
            staffTopY: staffTopY, lineCount: lineCount, sp: sp,
        )
        primitives += ledgerLines(
            headX: parts.bottomHeadX + dx, headWidth: parts.headWidth, headY: bottomY, above: false,
            staffTopY: staffTopY, lineCount: lineCount, sp: sp,
        )
        return LayoutFigure(primitives: primitives)
    }

    /// `Ambitus::staffLine` as a y: `nil` for a pitch or tpc MuseScore treats as unset.
    private static func row(pitch: Int, tpc: Int, clef: NotatedClef, staffTopY: CGFloat, sp: CGFloat) -> CGFloat? {
        guard (0 ... 127).contains(pitch), (-1 ... 33).contains(tpc) else { return nil }
        let step = PitchStaffPosition.step(midiPitch: pitch, tpc: tpc, clef: clef).step
        return staffTopY + CGFloat(4 - step) * sp / 2
    }

    /// The bottom row minus the top one, in spatiums, clef-independent; an unset end falls back to the top or bottom
    /// line of a five-line staff, which is all the collision rule reads it for.
    private static func rowDifference(_ ambitus: Ambitus) -> CGFloat {
        let top = row(pitch: ambitus.topPitch, tpc: ambitus.topTpc, clef: .treble, staffTopY: 0, sp: 1) ?? 0
        let bottom = row(pitch: ambitus.bottomPitch, tpc: ambitus.bottomTpc, clef: .treble, staffTopY: 0, sp: 1) ?? 4
        return bottom - top
    }

    /// `Ambitus::noteHead` (`ambitus.cpp:243-258`): the `<head>` group's up-stem column at the head type, a quarter
    /// head when the type is auto, the normal group's when the cell is empty or the group unknown.
    private static func headCodepoint(_ ambitus: Ambitus) -> UInt32 {
        let kind: NoteHeadKind = switch ambitus.noteHeadType {
        case .half: .half
        case .whole: .whole
        case .brevis: .doubleWhole
        default: .quarter
        }
        let group = ambitus.noteHeadGroup.flatMap(headGroup) ?? .normal
        return SMuFLCodepoint.byName(NoteHeadGroup.symName(group: group, kind: kind, stemUp: true))
            ?? SMuFLCodepoint.byName(NoteHeadGroup.symName(group: .normal, kind: kind, stemUp: true))
            ?? SMuFLCodepoint.noteheadBlack
    }

    /// MuseScore's `NoteHeadGroup` in ordinal order (`types/types.h:470-499`), which a 4.6 file writes in `<head>`.
    private static let headGroupsByOrdinal: [NoteHeadGroup] = [
        .normal, .cross, .plus, .xcircle, .withX, .triangleUp, .triangleDown, .slashed1, .slashed2, .diamond,
        .diamondOld, .circled, .circledLarge, .largeArrow, .brevisAlt, .slash, .largeDiamond, .sol, .la, .fa, .mi,
        .doShape, .reShape, .tiShape, .heavyCross, .heavyCrossHat,
    ]

    /// `<head>` as a 4.6 ordinal or a name token.
    private static func headGroup(_ token: String) -> NoteHeadGroup? {
        if let ordinal = Int(token) {
            return headGroupsByOrdinal.indices.contains(ordinal) ? headGroupsByOrdinal[ordinal] : nil
        }
        return NoteHeadGroup.from(token: token)
    }

    /// A glyph's ink box at the staff's glyph size, Y-up from the baseline; `nil` when the provider has none.
    private static func glyphBox(_ codepoint: UInt32, sp: CGFloat) -> CGRect? {
        guard let scalar = Unicode.Scalar(codepoint) else { return nil }
        return FontMetrics.provider.textInkBounds(
            text: String(Character(scalar)), font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 4 * sp),
        )
    }

    /// The heads, left-aligned or side by side by the mirror, and the accidentals the key calls for hanging left of
    /// them — the bottom one pushed further left when the top one reaches down past its top (`tlayout.cpp:686-731`).
    /// The accidental type is MuseScore's: computed from the tpc and the key at layout, whatever the file stored.
    private static func arrangement(_ ambitus: Ambitus, key: Int, rowDifference: CGFloat, sp: CGFloat) -> Arrangement {
        let head = headCodepoint(ambitus)
        let headWidth = glyphBox(head, sp: sp)?.width ?? GuitarBendGeometry.noteheadWidthSp * sp
        let topAccidental = PitchSpelling.displayedAccidental(forTpc: ambitus.topTpc, in: key)
        let bottomAccidental = PitchSpelling.displayedAccidental(forTpc: ambitus.bottomTpc, in: key)
        let topCode = topAccidental.map(AccidentalGlyph.codepoint)
        let bottomCode = bottomAccidental.map(AccidentalGlyph.codepoint)
        let topBox = topCode.flatMap { glyphBox($0, sp: sp) }
        let bottomBox = bottomCode.flatMap { glyphBox($0, sp: sp) }
        let distance = accidentalNoteDistanceSp * sp
        let topOffset = (topBox?.width ?? 0) + distance
        var bottomOffset = (bottomBox?.width ?? 0) + distance
        // The top accidental's lowest ink against the bottom one's highest, rows measured from the top head.
        let topAccidentalBottom = -(topBox?.minY ?? 0)
        let bottomAccidentalTop = rowDifference * sp - (bottomBox?.maxY ?? 0)
        let collision = ambitus.mirror != .right && topAccidentalBottom > bottomAccidentalTop
        if collision {
            // Undercut a flat, a double flat or a natural by half its width.
            let undercuts = [.flat, .doubleFlat, .natural].contains(bottomAccidental)
            bottomOffset = topOffset + (bottomBox?.width ?? 0) * (undercuts ? 0.5 : 1)
        }
        let topHeadX: CGFloat
        let bottomHeadX: CGFloat
        let topAccidentalX: CGFloat
        let bottomAccidentalX: CGFloat
        switch ambitus.mirror {
        case .left:
            topHeadX = 0
            bottomHeadX = headWidth
            topAccidentalX = -topOffset
            bottomAccidentalX = collision ? -bottomOffset : headWidth - bottomOffset
        case .right:
            topHeadX = headWidth
            bottomHeadX = 0
            topAccidentalX = headWidth - topOffset
            bottomAccidentalX = -bottomOffset
        default:
            topHeadX = 0
            bottomHeadX = 0
            topAccidentalX = -topOffset
            bottomAccidentalX = -bottomOffset
        }
        return Arrangement(
            headCodepoint: head, headWidth: headWidth, topHeadX: topHeadX, bottomHeadX: bottomHeadX,
            topAccidental: topCode.map { ($0, topAccidentalX) },
            bottomAccidental: bottomCode.map { ($0, bottomAccidentalX) },
        )
    }

    /// The center-to-center line, `offset` short at each end measured along y (`LineF::pointAt(off / yDelta)`).
    private static func shortenedLine(
        from: CGPoint, to: CGPoint, by offset: CGFloat, width: CGFloat,
    ) -> LayoutFigure.Primitive {
        let dy = to.y - from.y
        guard dy != 0 else { return .line(from: from, to: to, width: width, cap: .flat) }
        func point(at t: CGFloat) -> CGPoint {
            CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + dy * t)
        }
        return .line(from: point(at: offset / dy), to: point(at: 1 - offset / dy), width: width, cap: .flat)
    }

    /// A head above the staff gets a ledger line at every line from the first one above the staff to its row; one
    /// below likewise from the first line below.
    private static func ledgerLines(
        headX: CGFloat, headWidth: CGFloat, headY: CGFloat, above: Bool, staffTopY: CGFloat, lineCount: Int,
        sp: CGFloat,
    ) -> [LayoutFigure.Primitive] {
        let tolerance = 0.1 * sp
        let length = ledgerLengthSp * sp
        let xMin = headX - length
        let xMax = headX + headWidth + length
        var lines: [LayoutFigure.Primitive] = []
        var y = above ? staffTopY - sp : staffTopY + CGFloat(lineCount) * sp
        while above ? y >= headY - tolerance : y <= headY + tolerance {
            lines.append(.line(
                from: CGPoint(x: xMin, y: y), to: CGPoint(x: xMax, y: y), width: ledgerWidthSp * sp, cap: .flat,
            ))
            y += above ? -sp : sp
        }
        return lines
    }
}
