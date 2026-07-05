// swiftlint:disable file_length
import CoreGraphics
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Decode rhythm for a measure. Builds chords and rests by
    /// clustering noteheads on shared stems, then assigns each beamed
    /// stem the duration implied by the beam lines crossing it
    /// (PDFImporter+Beams). Unbeamed short notes keep the flag-based
    /// path; augmentation dots apply on top of either.
    static func decodeRhythm(
        measure: ImportMeasure,
        decoded: [DecodedPitch],
        paths: [PathSegment],
        tieMarks: TieMarks = TieMarks(),
        graceSizeThreshold: CGFloat = 0,
    ) -> [RhythmElement] {
        var pitchByGlyph: [RawGlyph: DecodedPitch] = [:]
        for dp in decoded {
            pitchByGlyph[dp.glyph.raw] = dp
        }
        let glyphs = measure.glyphs.sorted {
            $0.raw.origin.x < $1.raw.origin.x
        }
        // Staff space (sp) for sizing geometry rects; derived from this
        // staff's five line y-coordinates. Only consumed by the geometry
        // side-car (noteRects / onsetRect); the value path ignores it.
        let spatium = staffSpatium(measure.staffYLines)
        // Stems and beams from OTHER staves stack at the same x as this
        // staff's notes (the systems are vertically aligned), so an x-only
        // match grabs a wrong-staff stem and the beam over it never lines
        // up. Restrict both to this staff's vertical band — the staff
        // height padded by ~2 staff-heights each side, which reaches the
        // stem ends and the beam above/below them without touching the
        // neighbouring staff (~3 staff-heights away centre-to-centre).
        let yBand = staffBeamBand(measure.staffYLines)
        let stems = paths.filter {
            isStem(in: measure, $0, noteheads: glyphs)
                && segmentOverlapsBand($0, yBand)
        }
        // Beam segments overlapping this measure cell (page-filtered
        // upstream). Gate on x so a beam belonging to a neighbouring
        // measure cannot bleed in, and on the staff band so a beam over a
        // vertically-aligned staff cannot be counted here.
        let beams = paths.filter {
            $0.kind == .beam
                && measure.xRange.contains($0.rect.midX)
                && segmentOverlapsBand($0, yBand)
        }
        // Grace noteheads render through a down-scaled matrix (~70% in
        // MuseScore). Marked so they're (a) never a main-chord lead and (b)
        // never absorbed into a neighbouring main chord's cluster; they're
        // re-attached below as `graceNotesBefore` (the same representation
        // Score A uses) and so consume no voice time — keeping the main-note
        // count and following-note x-onsets aligned with A.
        let graceIndices = graceNoteheadIndices(
            glyphs: glyphs, threshold: graceSizeThreshold,
        )

        // Beam-group geometry (① + ②): per-stem beam level computed ONCE
        // over the whole measure so union-find groups and interior
        // inheritance see every stem. Keyed by the stem's index in `stems`.
        // The notehead origins identify each stem's beam-attaching end so a
        // neighbour staff's beam grazing the notehead end isn't miscounted.
        let noteheadOrigins = glyphs
            .filter { isNotehead($0.semantic) }
            .map(\.raw.origin)
        let levelByStem = computeBeamLevels(
            stems: stems, beams: beams, noteheadOrigins: noteheadOrigins,
            spatium: spatium,
        )

        var elements: [RhythmElement] = []
        var consumed = graceIndices

        for (i, g) in glyphs.enumerated() where !consumed.contains(i) {
            switch g.semantic {
            case let .rest(dur):
                elements.append(makeRest(glyph: g, duration: dur, spatium: spatium))
                consumed.insert(i)
            case .noteheadBlack, .noteheadHalf,
                 .noteheadWhole, .noteheadDoubleWhole,
                 .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
                let element = assembleChord(
                    leadIndex: i,
                    glyphs: glyphs,
                    stems: stems,
                    levelByStem: levelByStem,
                    flagBand: yBand,
                    pitchByGlyph: pitchByGlyph,
                    tieMarks: tieMarks,
                    spatium: spatium,
                    consumed: &consumed,
                )
                elements.append(element)
            default:
                continue
            }
        }

        let graces = buildGraceChords(
            indices: graceIndices, glyphs: glyphs,
            pitchByGlyph: pitchByGlyph, tieMarks: tieMarks,
        )
        let sorted = elements.sorted { $0.x < $1.x }
        return attachGraces(graces, to: sorted)
    }
}

// MARK: - Cluster assembly

extension PDFImporter {
    private static func makeRest(
        glyph: ClassifiedGlyph, duration: NoteDuration, spatium: CGFloat,
    ) -> RhythmElement {
        RhythmElement(
            chord: Chord(duration: duration, notes: []),
            x: glyph.raw.origin.x,
            y: glyph.raw.origin.y,
            stemDirection: nil,
            beamGroup: nil,
            onsetRect: PDFGeometryRects.glyphBox(
                origin: glyph.raw.origin,
                advance: glyph.raw.advance,
                spatium: spatium,
                pageIndex: glyph.raw.pageIndex,
            ),
        )
    }

    private static func assembleChord(
        leadIndex: Int,
        glyphs: [ClassifiedGlyph],
        stems: [PathSegment],
        levelByStem: [Int: Int],
        flagBand: ClosedRange<CGFloat>?,
        pitchByGlyph: [RawGlyph: DecodedPitch],
        tieMarks: TieMarks,
        spatium: CGFloat,
        consumed: inout Set<Int>,
    ) -> RhythmElement {
        let lead = glyphs[leadIndex]
        let cluster = stemCluster(
            startingAt: leadIndex, in: glyphs, stems: stems,
        )
        consumed.formUnion(cluster.indices)
        let (notes, noteRects) = buildChordNotes(
            clusterIndices: cluster.indices, glyphs: glyphs,
            pitchByGlyph: pitchByGlyph, tieMarks: tieMarks, spatium: spatium,
        )
        let base = baseDuration(for: lead.semantic)
        // Beam lines take precedence over flags. Only black noteheads
        // (quarter base) are beamable; half / whole notes are never beamed,
        // so a spurious beam overlap can't shorten them. The level is the
        // group-aware count computed up front (① + ②): sloped-quad
        // membership + interior inheritance + owned partial stubs.
        let beamLevels: Int
        if base == .quarter, let si = cluster.stemIndex {
            // Direct index lookup — the cluster carries the exact `stems`
            // index it chose, so two stems sharing an x can't be confused
            // (an x-only reverse lookup would mis-resolve them).
            beamLevels = levelByStem[si] ?? 0
        } else {
            beamLevels = 0
        }
        let withBeamsOrFlags: NoteDuration
        let flagShortened: Bool
        if beamLevels > 0 {
            withBeamsOrFlags = durationForBeamLevels(beamLevels, base: base)
            flagShortened = false
        } else {
            withBeamsOrFlags = applyFlags(
                base: base, glyphs: glyphs, stem: cluster.stem, lead: lead,
                flagBand: flagBand,
            )
            // A flag actually fired only when the result is shorter than the
            // base — i.e. this group-size-1 note's value HINGES on a flag
            // glyph the geometry could have mis-read (the q↔8 ambiguity). An
            // unbeamed, unflagged base note (plain quarter / half / whole) is
            // high-confidence in its value and is never a repair candidate.
            flagShortened = withBeamsOrFlags != base
        }
        let withDots = applyDots(
            duration: withBeamsOrFlags, glyphs: glyphs, lead: lead,
        )
        let dir = cluster.stem.map { stem in
            stem.rect.midY > lead.raw.origin.y
                ? StemDirection.up : .down
        }
        return RhythmElement(
            chord: Chord(duration: withDots, notes: ChordNotes(notes)),
            x: lead.raw.origin.x,
            y: lead.raw.origin.y,
            stemDirection: dir,
            beamGroup: nil,
            lowConfidenceDuration: flagShortened,
            noteRects: noteRects,
            onsetRect: PDFGeometryRects.union(noteRects),
        )
    }

    /// Build a chord's deduped notes and their geometry rects in LOCKSTEP,
    /// applying the same pitch-dedup `ChordNotes.init` would — first
    /// occurrence of a pitch wins, order preserved. This keeps `noteRects[k]`
    /// aligned with the final `chord.notes[k]` (i.e. `noteIndexInChord`),
    /// which follows the deduped survivor order, NOT raw `clusterIndices`. A
    /// notehead identified as a tie endpoint stamps `tieForward` (earlier
    /// note) and / or `tieBack` (later note).
    private static func buildChordNotes(
        clusterIndices: [Int],
        glyphs: [ClassifiedGlyph],
        pitchByGlyph: [RawGlyph: DecodedPitch],
        tieMarks: TieMarks,
        spatium: CGFloat,
    ) -> (notes: [Note], noteRects: [PDFElementRect]) {
        var notes: [Note] = []
        var noteRects: [PDFElementRect] = []
        var seenPitches = Set<Int>()
        for idx in clusterIndices {
            guard let dp = pitchByGlyph[glyphs[idx].raw] else { continue }
            let id = NoteheadID(glyphs[idx].raw)
            let note = Note(
                pitch: dp.midi,
                tpc: dp.tpc,
                accidental: dp.accidental,
                tieForward: tieMarks.forward.contains(id) ? 1 : nil,
                tieBack: tieMarks.back.contains(id) ? 1 : nil,
            )
            guard seenPitches.insert(note.pitch).inserted else { continue }
            notes.append(note)
            noteRects.append(PDFGeometryRects.glyphBox(
                origin: glyphs[idx].raw.origin,
                advance: glyphs[idx].raw.advance,
                spatium: spatium,
                pageIndex: glyphs[idx].raw.pageIndex,
            ))
        }
        return (notes, noteRects)
    }

    /// Staff space (sp) = one inter-line gap, derived from the staff's five
    /// line y-coordinates (`span / 4`). Falls back to a nominal 8pt when
    /// fewer than two lines were detected. Geometry-only.
    static func staffSpatium(_ yLines: [CGFloat]) -> CGFloat {
        guard let lo = yLines.min(), let hi = yLines.max(), hi > lo else {
            return 8
        }
        return (hi - lo) / 4
    }
}

// MARK: - Stem detection / clustering

extension PDFImporter {
    /// A stem is a vertical inside the measure cell that touches a
    /// notehead and is not the measure's edge barline.
    ///
    /// The earlier `lineWidth < 1` gate was tuned for a fixture whose
    /// stems were hairlines; MuseScore's real export strokes stems and
    /// barlines at the same `w` (here ~3.57pt), so a width gate either
    /// rejected every stem (observed: 0 stems → no chord clustering, no
    /// beam attachment) or admitted barlines. We instead require a
    /// notehead within ~3.5pt of the vertical's x and exclude verticals
    /// sitting on the cell's left / right edge (where barlines live).
    private static func isStem(
        in measure: ImportMeasure,
        _ path: PathSegment,
        noteheads: [ClassifiedGlyph],
    ) -> Bool {
        guard path.kind == .vertical,
              measure.xRange.contains(path.rect.midX)
        else { return false }
        let x = path.rect.midX
        let edgeSlop: CGFloat = 4
        let nearEdge = abs(x - measure.xRange.lowerBound) < edgeSlop
            || abs(x - measure.xRange.upperBound) < edgeSlop
        // A cell-edge vertical that spans the FULL staff line span is a
        // barline — reject it. But a bar-FINAL note's stem can also sit within
        // `edgeSlop` of the edge; such a stem spans only ~an octave and is
        // OFFSET from the staff (it does not reach both outer lines), so it is
        // kept rather than swallowed as a barline (ロビンソン 16→q at bar ends).
        if nearEdge, isFullStaffHeight(path, staffYLines: measure.staffYLines) {
            return false
        }
        // A stem abuts a notehead's right edge (stem-up) or left edge
        // (stem-down), offset by roughly the notehead width (~4–6pt here).
        return noteheads.contains { g in
            isNoteheadSemantic(g.semantic)
                && abs(g.raw.origin.x - x) <= 7
        }
    }

    /// Whether `path`'s y-span reaches BOTH outer staff lines (within ~1.5pt)
    /// — the signature of a barline as opposed to a note stem. With no usable
    /// staff geometry, treats a near-edge vertical as a barline (preserving
    /// the previous unconditional edge reject).
    private static func isFullStaffHeight(
        _ path: PathSegment, staffYLines: [CGFloat],
    ) -> Bool {
        guard let lo = staffYLines.min(), let hi = staffYLines.max(), hi > lo
        else { return true }
        let tol: CGFloat = 1.5
        return path.rect.minY <= lo + tol && path.rect.maxY >= hi - tol
    }

    fileprivate struct Cluster {
        var indices: [Int]
        var stem: PathSegment?
        /// Index of `stem` in the measure's `stems` array (nil when no stem).
        /// Carried so the precomputed `levelByStem` can be read directly,
        /// without an ambiguous x-only reverse lookup.
        var stemIndex: Int?
    }

    fileprivate static func stemCluster(
        startingAt i: Int,
        in glyphs: [ClassifiedGlyph],
        stems: [PathSegment],
    ) -> Cluster {
        let lead = glyphs[i]
        guard let chosen = nearestStem(
            toX: lead.raw.origin.x, noteY: lead.raw.origin.y, stems: stems,
        )
        else {
            return Cluster(indices: [i], stem: nil, stemIndex: nil)
        }
        var indices = [i]
        for (j, g) in glyphs.enumerated() where j != i {
            guard isNoteheadSemantic(g.semantic) else { continue }
            // Chord noteheads share the lead's x. Match the lead's x (not the
            // stem midX) so a stem-down note's left-side stem doesn't widen
            // the window into the neighbour to its right.
            guard abs(g.raw.origin.x - lead.raw.origin.x) <= 2.5 else { continue }
            // …but a shared x is NOT sufficient: a drum downbeat stacks two
            // VOICES at one x — a crash (stem-up) over a kick (stem-down), each
            // on its OWN stem — and the old x-only rule fused them into one
            // chord, hiding the crash onset behind the kick's lead (the 群青/
            // 君と drum loss). Admit a same-x notehead only when it attaches to
            // the SAME stem as the lead; the other splits off in assignVoices.
            // Single-voice chords share one stem (mates still cluster); a
            // notehead with no detected stem still joins.
            let gStem = nearestStem(
                toX: g.raw.origin.x, noteY: g.raw.origin.y, stems: stems,
            )
            if let gStem, gStem.index != chosen.index { continue }
            indices.append(j)
        }
        return Cluster(
            indices: indices.sorted(), stem: chosen.stem, stemIndex: chosen.index,
        )
    }

    private static func isNoteheadSemantic(_ s: SMuFLSemantic) -> Bool {
        isNotehead(s)
    }
}

// MARK: - Duration helpers

extension PDFImporter {
    private static func baseDuration(
        for sem: SMuFLSemantic,
    ) -> NoteDuration {
        switch sem {
        case .noteheadDoubleWhole, .noteheadWhole, .noteheadXWhole: .whole
        case .noteheadHalf, .noteheadXHalf: .half
        case .noteheadBlack, .noteheadXBlack: .quarter
        default: .quarter
        }
    }

    /// Subdivision level a flag glyph encodes: a combined SMuFL flag glyph
    /// carries the FULL level (flag16thUp is a single glyph meaning two
    /// halvings), so map by glyph type, not by counting glyphs.
    private static func flagLevel(_ s: SMuFLSemantic) -> Int? {
        switch s {
        case .flag8thUp, .flag8thDown: 1
        case .flag16thUp, .flag16thDown: 2
        case .flag32ndUp, .flag32ndDown: 3
        case .flag64thUp, .flag64thDown: 4
        default: nil
        }
    }

    /// Shorten `base` by the flag attached to this note's stem.
    ///
    /// MuseScore positions a flag glyph at the notehead-side stem x, offset
    /// vertically by roughly one stem length from the notehead: a stem-UP
    /// flag origin sits ~10–14pt ABOVE the notehead, a stem-DOWN flag
    /// ~14pt BELOW it (measured empirically on this corpus; tight cluster).
    /// We anchor the y-test on the NOTEHEAD, not the detected stem's end —
    /// the nearest-vertical stem match can grab a fragment that doesn't
    /// reach the flag, so a stem-end-anchored gate dropped real flags
    /// (observed: 12 eighths/measure-part mis-read as quarters in part 0).
    /// The x-gate (`< 5`pt of the stem x, well under ~10pt note spacing)
    /// keeps an adjacent note's flag from matching. A combined flag glyph
    /// carries its whole level, so we take the MAX matched level.
    private static func applyFlags(
        base: NoteDuration,
        glyphs: [ClassifiedGlyph],
        stem: PathSegment?,
        lead: ClassifiedGlyph,
        flagBand: ClosedRange<CGFloat>?,
    ) -> NoteDuration {
        guard let stem else { return base }
        let stemX = stem.rect.midX
        let noteY = lead.raw.origin.y
        // The stem's bare (flag-attaching) end is the one FARTHER from the
        // notehead: a stem whose bare end sits above the notehead points up
        // (takes an up-flag), one whose bare end sits below points down. A
        // flag must agree with this orientation; a neighbour's flag that lands
        // in the correct dy window but belongs to an oppositely-stemmed note
        // is rejected (the 君と kick 8→16 flag theft).
        let stemPointsUp =
            abs(stem.rect.maxY - noteY) >= abs(stem.rect.minY - noteY)
        // On-correct-side vertical window from the notehead. Up-flags sit
        // above (positive Δ), down-flags below (negative Δ); |Δ| ≈ 10–14pt.
        let near: ClosedRange<CGFloat> = 4 ... 22
        var level = 0
        for g in glyphs {
            // Staff-scope the flag match: a vertically-aligned adjacent-staff
            // flag sits at the same x but outside this staff's y-band, so
            // restricting to the band stops it from being grabbed (fixes the
            // q→8 over-read).
            if let flagBand, !flagBand.contains(g.raw.origin.y) { continue }
            // Tight x-gate: MuseScore anchors a flag glyph at its stem's x, so
            // a note's own flag sits within ~0.3pt of the stem; the nearest
            // neighbour flag is ≥ ~5pt away. A ≤2pt window keeps every own flag
            // and rejects a neighbour's (the 君と cross-note flag theft).
            guard abs(g.raw.origin.x - stemX) <= 2,
                  let lvl = flagLevel(g.semantic) else { continue }
            let dy = g.raw.origin.y - noteY
            let isUp: Bool
            switch g.semantic {
            case .flag8thUp, .flag16thUp, .flag32ndUp, .flag64thUp: isUp = true
            default: isUp = false
            }
            // Flag orientation must match the stem's pointing direction.
            guard isUp == stemPointsUp else { continue }
            let onSide = isUp ? near.contains(dy) : near.contains(-dy)
            if onSide { level = max(level, lvl) }
        }
        var d = base
        for _ in 0 ..< level {
            d = halve(d)
        }
        return d
    }

    private static func halve(_ d: NoteDuration) -> NoteDuration {
        switch d {
        case .whole: .half
        case .half: .quarter
        case .quarter: .eighth
        case .eighth: .sixteenth
        case .sixteenth: .thirtySecond
        case .thirtySecond: .sixtyFourth
        case .sixtyFourth: .oneTwentyEighth
        case .oneTwentyEighth: .twoFiftySixth
        case .twoFiftySixth: .twoFiftySixth
        case .measure: .measure
        case let .fraction(f):
            .fraction(Fraction(
                numerator: f.numerator,
                denominator: f.denominator * 2,
            ))
        }
    }

    private static func applyDots(
        duration: NoteDuration,
        glyphs: [ClassifiedGlyph],
        lead: ClassifiedGlyph,
    ) -> NoteDuration {
        var dotCount = 0
        let leadX = lead.raw.origin.x
        let leadY = lead.raw.origin.y
        for g in glyphs {
            guard case .augmentationDot = g.semantic else { continue }
            let dx = g.raw.origin.x - leadX
            let dy = abs(g.raw.origin.y - leadY)
            // A note's own dot sits ~7–10pt to its right (measured). The
            // previous `< 20`pt window also caught the FOLLOWING note's dot
            // ~15pt away (a phantom `3/32` at the tail of beamed 16th runs);
            // 12pt keeps every owner dot and rejects the ~15pt neighbour.
            if dx > 0, dx < 12, dy < 4 { dotCount += 1 }
        }
        return dotCount > 0 ? duration.dotted(dotCount) : duration
    }
}
