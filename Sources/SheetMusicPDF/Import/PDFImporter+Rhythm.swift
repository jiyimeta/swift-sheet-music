import CoreGraphics
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Decode rhythm for a measure. Builds chords and rests by
    /// clustering noteheads on shared stems and applying flag/dot
    /// modifiers. Beam-based duration division is **not** yet
    /// implemented — only the flag-based path is wired up. Beamed
    /// eighth/sixteenth groups will currently fall back to their
    /// stem's base duration (typically `.quarter`). Task 9 follow-on
    /// work will introduce beam path detection.
    static func decodeRhythm(
        measure: ImportMeasure,
        decoded: [DecodedPitch],
        paths: [PathSegment],
    ) -> [RhythmElement] {
        var pitchByGlyph: [RawGlyph: DecodedPitch] = [:]
        for dp in decoded {
            pitchByGlyph[dp.glyph.raw] = dp
        }
        let glyphs = measure.glyphs.sorted {
            $0.raw.origin.x < $1.raw.origin.x
        }
        let stems = paths.filter { isStem(in: measure, $0) }

        var elements: [RhythmElement] = []
        var consumed = Set<Int>()

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
                    pitchByGlyph: pitchByGlyph,
                    consumed: &consumed,
                )
                elements.append(element)
            default:
                continue
            }
        }
        return elements.sorted { $0.x < $1.x }
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
        pitchByGlyph: [RawGlyph: DecodedPitch],
        consumed: inout Set<Int>,
    ) -> RhythmElement {
        let lead = glyphs[leadIndex]
        let cluster = stemCluster(
            startingAt: leadIndex, in: glyphs, stems: stems,
        )
        consumed.formUnion(cluster.indices)
        let notes = cluster.indices.compactMap { idx -> Note? in
            guard let dp = pitchByGlyph[glyphs[idx].raw] else { return nil }
            return Note(pitch: dp.midi, tpc: dp.tpc)
        }
        let base = baseDuration(for: lead.semantic)
        let withFlags = applyFlags(
            base: base, glyphs: glyphs, stem: cluster.stem,
        )
        let withDots = applyDots(
            duration: withFlags, glyphs: glyphs, lead: lead,
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
    private static func isStem(
        in measure: ImportMeasure, _ path: PathSegment,
    ) -> Bool {
        path.kind == .vertical
            && measure.xRange.contains(path.rect.midX)
            && path.lineWidth < 1
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
            if abs(g.raw.origin.x - stem.rect.midX) <= 2 {
                indices.append(j)
            }
        }
        return Cluster(indices: indices.sorted(), stem: stem)
    }

    private static func nearestStem(
        toX x: CGFloat, stems: [PathSegment],
    ) -> PathSegment? {
        let best = stems.min {
            abs($0.rect.midX - x) < abs($1.rect.midX - x)
        }
        guard let stem = best, abs(stem.rect.midX - x) <= 2 else {
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

    private static func applyFlags(
        base: NoteDuration,
        glyphs: [ClassifiedGlyph],
        stem: PathSegment?,
    ) -> NoteDuration {
        guard let stem else { return base }
        let stemX = stem.rect.midX
        let stemTopY = stem.rect.maxY
        let stemBottomY = stem.rect.minY
        var flagCount = 0
        for g in glyphs {
            guard abs(g.raw.origin.x - stemX) < 5 else { continue }
            switch g.semantic {
            case .flag8thUp, .flag16thUp, .flag32ndUp, .flag64thUp:
                if abs(g.raw.origin.y - stemTopY) < 10 { flagCount += 1 }
            case .flag8thDown, .flag16thDown, .flag32ndDown, .flag64thDown:
                if abs(g.raw.origin.y - stemBottomY) < 10 {
                    flagCount += 1
                }
            default:
                continue
            }
        }
        var d = base
        for _ in 0 ..< flagCount {
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
            if dx > 0, dx < 20, dy < 4 { dotCount += 1 }
        }
        return dotCount > 0 ? duration.dotted(dotCount) : duration
    }
}
