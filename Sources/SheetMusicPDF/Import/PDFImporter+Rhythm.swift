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

        var elements: [RhythmElement] = []
        var consumed = graceIndices

        for (i, g) in glyphs.enumerated() where !consumed.contains(i) {
            switch g.semantic {
            case let .rest(dur):
                elements.append(makeRest(glyph: g, duration: dur))
                consumed.insert(i)
            case .noteheadBlack, .noteheadHalf,
                 .noteheadWhole, .noteheadDoubleWhole:
                let element = assembleChord(
                    leadIndex: i,
                    glyphs: glyphs,
                    stems: stems,
                    beams: beams,
                    pitchByGlyph: pitchByGlyph,
                    tieMarks: tieMarks,
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
        glyph: ClassifiedGlyph, duration: NoteDuration,
    ) -> RhythmElement {
        RhythmElement(
            chord: Chord(duration: duration, notes: []),
            x: glyph.raw.origin.x,
            y: glyph.raw.origin.y,
            stemDirection: nil,
            beamGroup: nil,
        )
    }

    private static func assembleChord(
        leadIndex: Int,
        glyphs: [ClassifiedGlyph],
        stems: [PathSegment],
        beams: [PathSegment],
        pitchByGlyph: [RawGlyph: DecodedPitch],
        tieMarks: TieMarks,
        consumed: inout Set<Int>,
    ) -> RhythmElement {
        let lead = glyphs[leadIndex]
        let cluster = stemCluster(
            startingAt: leadIndex, in: glyphs, stems: stems,
        )
        consumed.formUnion(cluster.indices)
        let notes = cluster.indices.compactMap { idx -> Note? in
            guard let dp = pitchByGlyph[glyphs[idx].raw] else { return nil }
            // Stamp ties: a notehead identified as a tie endpoint carries
            // tieForward (earlier note) and / or tieBack (later note).
            let id = NoteheadID(glyphs[idx].raw)
            return Note(
                pitch: dp.midi,
                tpc: dp.tpc,
                tieForward: tieMarks.forward.contains(id) ? 1 : nil,
                tieBack: tieMarks.back.contains(id) ? 1 : nil,
            )
        }
        let base = baseDuration(for: lead.semantic)
        // Beam lines take precedence over flags. Only black noteheads
        // (quarter base) are beamable; half / whole notes are never beamed,
        // so a spurious beam overlap can't shorten them.
        let beamLevels: Int
        if base == .quarter, let stem = cluster.stem {
            beamLevels = beamLevelCount(stem: stem, beams: beams)
        } else {
            beamLevels = 0
        }
        let withBeamsOrFlags: NoteDuration
        if beamLevels > 0 {
            withBeamsOrFlags = durationForBeamLevels(beamLevels, base: base)
        } else {
            let flagged = applyFlags(
                base: base, glyphs: glyphs, stem: cluster.stem, lead: lead,
            )
            // Beam-group-membership rescue: a quarter with no own beam and
            // no flag, but whose stem is strictly interior to a
            // group-spanning beam, is a beamed eighth whose own stem
            // vertical was mis-detected off-row. Only fires for an
            // otherwise-bare black notehead (still `base`), so it can never
            // contradict a detected flag or shorten a half / whole note.
            if flagged == base, base == .quarter, let stem = cluster.stem {
                let rescue = primaryBeamRescueLevel(
                    stemX: stem.rect.midX,
                    noteY: lead.raw.origin.y,
                    beams: beams,
                )
                withBeamsOrFlags = rescue > 0
                    ? durationForBeamLevels(rescue, base: base)
                    : flagged
            } else {
                withBeamsOrFlags = flagged
            }
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
        )
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
        if abs(x - measure.xRange.lowerBound) < edgeSlop
            || abs(x - measure.xRange.upperBound) < edgeSlop
        { return false }
        // A stem abuts a notehead's right edge (stem-up) or left edge
        // (stem-down), offset by roughly the notehead width (~4–6pt here).
        return noteheads.contains { g in
            isNoteheadSemantic(g.semantic)
                && abs(g.raw.origin.x - x) <= 7
        }
    }

    fileprivate struct Cluster {
        var indices: [Int]
        var stem: PathSegment?
    }

    fileprivate static func stemCluster(
        startingAt i: Int,
        in glyphs: [ClassifiedGlyph],
        stems: [PathSegment],
    ) -> Cluster {
        let lead = glyphs[i]
        guard let stem = nearestStem(toX: lead.raw.origin.x, stems: stems)
        else {
            return Cluster(indices: [i], stem: nil)
        }
        var indices = [i]
        for (j, g) in glyphs.enumerated() where j != i {
            guard isNoteheadSemantic(g.semantic) else { continue }
            // Chord noteheads share the lead's x (and thus its stem
            // offset). Match against the lead's x rather than the stem's
            // midX so a stem-down note's left-side stem doesn't widen the
            // window into the neighbour to its right.
            if abs(g.raw.origin.x - lead.raw.origin.x) <= 2.5 {
                indices.append(j)
            }
        }
        return Cluster(indices: indices.sorted(), stem: stem)
    }

    /// The stem abutting a notehead at `x`. A stem sits ~4–6pt to the
    /// side of the notehead (its right edge for stem-up, left for
    /// stem-down), so accept the nearest vertical within ~7pt — under
    /// the ~10pt note-to-note spacing, so it can't grab a neighbour.
    private static func nearestStem(
        toX x: CGFloat, stems: [PathSegment],
    ) -> PathSegment? {
        let best = stems.min {
            abs($0.rect.midX - x) < abs($1.rect.midX - x)
        }
        guard let stem = best, abs(stem.rect.midX - x) <= 7 else {
            return nil
        }
        return stem
    }

    private static func isNoteheadSemantic(_ s: SMuFLSemantic) -> Bool {
        switch s {
        case .noteheadBlack, .noteheadHalf,
             .noteheadWhole, .noteheadDoubleWhole:
            true
        default:
            false
        }
    }
}

// MARK: - Duration helpers

extension PDFImporter {
    private static func baseDuration(
        for sem: SMuFLSemantic,
    ) -> NoteDuration {
        switch sem {
        case .noteheadDoubleWhole, .noteheadWhole: .whole
        case .noteheadHalf: .half
        case .noteheadBlack: .quarter
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
    ) -> NoteDuration {
        guard let stem else { return base }
        let stemX = stem.rect.midX
        let noteY = lead.raw.origin.y
        // On-correct-side vertical window from the notehead. Up-flags sit
        // above (positive Δ), down-flags below (negative Δ); |Δ| ≈ 10–14pt.
        let near: ClosedRange<CGFloat> = 4 ... 22
        var level = 0
        for g in glyphs {
            guard abs(g.raw.origin.x - stemX) < 5,
                  let lvl = flagLevel(g.semantic) else { continue }
            let dy = g.raw.origin.y - noteY
            let isUp: Bool
            switch g.semantic {
            case .flag8thUp, .flag16thUp, .flag32ndUp, .flag64thUp: isUp = true
            default: isUp = false
            }
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
            // A note's own dot sits ~7–10pt to its right (measured: owner
            // dx clusters at 7.1/7.2/9.7/9.8pt). The previous `< 20`pt
            // window also caught the dot of the FOLLOWING note ~15pt away,
            // dotting a note that A leaves plain (the phantom `3/32` at the
            // tail of beamed 16th runs). 12pt keeps every real owner dot
            // with headroom and rejects the ~15pt neighbour.
            if dx > 0, dx < 12, dy < 4 { dotCount += 1 }
        }
        return dotCount > 0 ? duration.dotted(dotCount) : duration
    }
}
