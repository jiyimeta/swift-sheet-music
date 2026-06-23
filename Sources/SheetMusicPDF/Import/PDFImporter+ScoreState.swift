import CoreGraphics
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Walk a staff's measures left-to-right and emit score-state
    /// events (clef changes, key signatures, time signatures, tempos).
    ///
    /// Per measure we scan glyphs in left-to-right x-order and emit at
    /// most one clef, one key signature, and one time signature event.
    /// Tempos are extracted from the page's text glyphs and tied to
    /// measure 0 of the staff (best-effort).
    static func scoreStateEvents(
        staff: ImportStaff, texts: [TextGlyph],
    ) -> [ScoreStateEvent] {
        var events: [ScoreStateEvent] = []
        for (i, measure) in staff.measures.enumerated() {
            let sorted = measure.glyphs.sorted { $0.raw.origin.x < $1.raw.origin.x }
            if let clef = readClef(from: sorted) {
                events.append(.clefChange(clef, atMeasureIndex: i))
            }
            if let key = readKey(from: sorted) {
                events.append(.keySignature(key, atMeasureIndex: i))
            }
            if let timeSig = readTime(from: sorted) {
                events.append(.timeSignature(timeSig, atMeasureIndex: i))
            }
        }
        for tempo in extractTempos(texts: texts) {
            events.append(.tempo(tempo, atMeasureIndex: 0))
        }
        return events
    }

    // MARK: - Clef

    private static func readClef(from glyphs: [ClassifiedGlyph]) -> Clef? {
        for glyph in glyphs {
            switch glyph.semantic {
            case .clefG: return Clef(concertClefType: "G")
            case .clefG8vb: return Clef(concertClefType: "G8vb")
            case .clefG8va: return Clef(concertClefType: "G8va")
            case .clefG15ma: return Clef(concertClefType: "G15ma")
            case .clefG15mb: return Clef(concertClefType: "G15mb")
            case .clefF: return Clef(concertClefType: "F")
            case .clefF8va: return Clef(concertClefType: "F8va")
            case .clefF8vb: return Clef(concertClefType: "F8vb")
            case .clefF15ma: return Clef(concertClefType: "F15ma")
            case .clefF15mb: return Clef(concertClefType: "F15mb")
            case .clefC: return Clef(concertClefType: "C")
            case .clefPercussion: return Clef(concertClefType: "PERCUSSION")
            case .noteheadBlack, .noteheadHalf, .noteheadWhole, .noteheadDoubleWhole,
                 .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
                return nil
            default: continue
            }
        }
        return nil
    }

    // MARK: - Key signature

    /// Read the leading key signature, if any. Only accidentals that
    /// belong to the key-signature BLOCK count — an accidental tightly
    /// bound to a following notehead (a local accidental: same y, just to
    /// the left of the note) is excluded.
    ///
    /// Without this exclusion a measure that simply STARTS on a flatted
    /// melodic note read as a spurious one-flat key change, which then
    /// flattened every diatonic note for the rest of the measure (observed
    /// on the Gibbs score: 25 measures flipped A's `key=1` to `B=-1`,
    /// dragging F♯→F♮, B→B♭ etc. and tanking the per-note pitch metric).
    private static func readKey(from glyphs: [ClassifiedGlyph]) -> KeySignature? {
        let sorted = glyphs.sorted { $0.raw.origin.x < $1.raw.origin.x }
        var sharps = 0
        var flats = 0
        for (i, glyph) in sorted.enumerated() {
            switch glyph.semantic {
            case .accidentalSharp:
                if !pairsWithFollowingNotehead(at: i, in: sorted) { sharps += 1 }
            case .accidentalFlat, .accidentalNatural:
                if !pairsWithFollowingNotehead(at: i, in: sorted) {
                    if case .accidentalFlat = glyph.semantic { flats += 1 }
                    // A leading natural in the key block (cancellation) is
                    // not counted toward sharps/flats — it neither adds nor
                    // removes here; key inference is by net sharps/flats.
                }
            case .noteheadBlack, .noteheadHalf, .noteheadWhole, .noteheadDoubleWhole,
                 .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
                // Stop at the first notehead — anything after is a note,
                // not part of the leading key signature.
                return finalize(sharps: sharps, flats: flats)
            default: continue
            }
        }
        return finalize(sharps: sharps, flats: flats)
    }

    /// True when the accidental at `index` is a LOCAL accidental: a
    /// notehead follows it at (near) the same y and close in x — the
    /// visual signature of an accidental modifying that single note,
    /// rather than a key-signature accidental (which sits at a canonical
    /// staff position with the notes spaced well to its right).
    private static func pairsWithFollowingNotehead(
        at index: Int, in sorted: [ClassifiedGlyph],
    ) -> Bool {
        let acc = sorted[index]
        guard index + 1 < sorted.count else { return false }
        for j in (index + 1) ..< sorted.count {
            let g = sorted[j]
            switch g.semantic {
            case .noteheadBlack, .noteheadHalf,
                 .noteheadWhole, .noteheadDoubleWhole,
                 .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
                let dx = g.raw.origin.x - acc.raw.origin.x
                let dy = abs(g.raw.origin.y - acc.raw.origin.y)
                // Local accidental: notehead is just to the right (≤ ~14pt)
                // at essentially the same y (≤ ~2pt, i.e. same staff line).
                return dx >= 0 && dx <= 14 && dy <= 2
            default:
                continue
            }
        }
        return false
    }

    private static func finalize(sharps: Int, flats: Int) -> KeySignature? {
        if sharps > 0 { return KeySignature(concertKey: sharps) }
        if flats > 0 { return KeySignature(concertKey: -flats) }
        return nil
    }

    // MARK: - Time signature

    private static func readTime(from glyphs: [ClassifiedGlyph]) -> TimeSignature? {
        for glyph in glyphs {
            switch glyph.semantic {
            case .timeSignatureCommon:
                return TimeSignature(numerator: 4, denominator: 4)
            case .timeSignatureCutTime:
                return TimeSignature(numerator: 2, denominator: 2)
            case .timeSignatureDigit:
                return parseStackedDigits(from: glyphs)
            case .noteheadBlack, .noteheadHalf, .noteheadWhole, .noteheadDoubleWhole,
                 .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
                return nil
            default: continue
            }
        }
        return nil
    }

    /// Group digit glyphs by x-cluster (within 3pt). Within a cluster
    /// the higher-y glyph is the numerator and the lower-y glyph is
    /// the denominator. Side-by-side digits (two distinct x-clusters)
    /// are read as `num / denom`.
    private static func parseStackedDigits(
        from glyphs: [ClassifiedGlyph],
    ) -> TimeSignature? {
        let digits = collectDigits(from: glyphs)
        guard !digits.isEmpty else { return nil }
        let clusters = clusterDigitsByX(digits)
        let firstCluster = clusters[0]
        if firstCluster.count >= 2 {
            let sortedByY = firstCluster.sorted { $0.y > $1.y }
            return TimeSignature(
                numerator: sortedByY[0].n,
                denominator: sortedByY[1].n,
            )
        }
        if clusters.count >= 2 {
            return TimeSignature(
                numerator: firstCluster[0].n,
                denominator: clusters[1][0].n,
            )
        }
        return TimeSignature(numerator: firstCluster[0].n, denominator: 4)
    }

    private struct DigitGlyph {
        var x: CGFloat
        var y: CGFloat
        var n: Int
    }

    private static func collectDigits(
        from glyphs: [ClassifiedGlyph],
    ) -> [DigitGlyph] {
        glyphs.compactMap { g in
            if case let .timeSignatureDigit(n) = g.semantic {
                return DigitGlyph(x: g.raw.origin.x, y: g.raw.origin.y, n: n)
            }
            return nil
        }
    }

    private static func clusterDigitsByX(
        _ digits: [DigitGlyph],
    ) -> [[DigitGlyph]] {
        let sorted = digits.sorted { $0.x < $1.x }
        var clusters: [[DigitGlyph]] = []
        for digit in sorted {
            if let lastDigit = clusters.last?.last,
               abs(digit.x - lastDigit.x) < 3
            {
                clusters[clusters.count - 1].append(digit)
            } else {
                clusters.append([digit])
            }
        }
        return clusters
    }

    // MARK: - Tempo

    /// Best-effort tempo extraction. Looks for `= NN` anywhere in the
    /// text and emits `Tempo(beatsPerSecond: NN/60)`. Text-only tempo
    /// markings without a numeric equation are skipped.
    private static func extractTempos(texts: [TextGlyph]) -> [Tempo] {
        var out: [Tempo] = []
        for text in texts {
            if let bpm = parseBpm(from: text.text) {
                out.append(Tempo(beatsPerSecond: Double(bpm) / 60.0))
            }
        }
        return out
    }

    private static func parseBpm(from text: String) -> Int? {
        guard let equalsIdx = text.lastIndex(of: "=") else { return nil }
        let after = text[text.index(after: equalsIdx)...]
            .trimmingCharacters(in: .whitespaces)
        let numericPrefix = after.prefix { $0.isNumber }
        guard !numericPrefix.isEmpty,
              let bpm = Int(numericPrefix), bpm > 0 else { return nil }
        return bpm
    }
}
