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

    // MARK: - E065 clef disambiguation (F8va vs plain F)

    /// MuseScore's MScore (legacy Emmentaler) and Bravura / Leland fonts both
    /// draw a bass clef carrying the figure "8" with the SAME private-use
    /// codepoint U+E065 (SMuFL `fClef8va`), yet on this corpus that one glyph
    /// stands for TWO different sounding clefs:
    ///   * F8va — the octave-up bass clef (君とParadiso part 4; content sits an
    ///     octave above the plain-bass register).
    ///   * plain F — an ordinary bass clef whose engraver happened to render
    ///     the "8"-decorated glyph (地球儀 part 5; content sits in the normal
    ///     bass register, an octave below F8va).
    /// The two readings differ by exactly 12 semitones, so picking the wrong
    /// one shifts the WHOLE staff an octave (地球儀 part 5 read 0% pitch under
    /// the unconditional F8va mapping). There is no separate "8" indicator
    /// glyph or path to key on (the digit is baked into E065 identically in
    /// both fonts), so we disambiguate by CONTENT: decode the staff's
    /// noteheads under the tentative F8va anchor and, if the resulting
    /// register sits implausibly HIGH for an octave-up bass clef (a real F8va
    /// part stays within a normal bass tessitura; a plain-F part forced up an
    /// octave overshoots it), downgrade to plain F.
    ///
    /// Scoped narrowly: only an F8va clef is ever rewritten, and only when the
    /// part's note content is decisively high. F8va parts whose content is
    /// genuinely in the octave-up register (君とParadiso part 4) are left
    /// untouched. E065 does not appear in the other corpus scores, so this is
    /// a no-op for them.
    ///
    /// `f8vaPitches` is the part's ENTIRE notehead population decoded under the
    /// tentative F8va anchor — aggregated across every system the part spans,
    /// not just one system. A per-system decision is noisy: a system that
    /// happens to hold only the part's lower notes can read below the
    /// threshold and keep F8va while a busier system downgrades, leaving the
    /// staff with mixed octaves. Deciding once from the whole part is stable.
    static func disambiguateF8vaClef(_ clef: Clef, f8vaPitches pitches: [Int]) -> Clef {
        guard clef.concertClefType == "F8va" else { return clef }
        // Need a few notes to judge a register; otherwise trust the glyph.
        guard pitches.count >= 8 else { return clef }
        let sorted = pitches.sorted()
        let mean = sorted.reduce(0, +) / sorted.count
        let p75 = sorted[sorted.count * 3 / 4]
        // Under the F8va anchor a genuine F8va part stays within a normal
        // bass tessitura (君とParadiso part 4: mean 55, p75 58); a plain-F part
        // mis-anchored an octave up overshoots it (地球儀 part 5: mean 59,
        // p75 65). Either signal crossing its threshold marks the part as too
        // high to be a real F8va, so the engraver's "8"-decorated glyph is an
        // ordinary bass clef → downgrade to plain F. The thresholds sit
        // between the two observed registers with a margin on both sides.
        if mean >= 58 || p75 >= 62 {
            return Clef(concertClefType: "F")
        }
        return clef
    }

    /// Decode every notehead of `staff` under the F8va anchor and return the
    /// resulting MIDI pitches (octave/register only — alteration is irrelevant
    /// to the tessitura test). Used to aggregate a part's content across
    /// systems for `disambiguateF8vaClef`.
    static func f8vaCandidatePitches(staff: ImportStaff) -> [Int] {
        let f8va = Clef(concertClefType: "F8va")
        var pitches: [Int] = []
        for measure in staff.measures where !measure.staffYLines.isEmpty {
            guard let anchor = staffAnchor(clef: f8va, yLines: measure.staffYLines)
            else { continue }
            for g in measure.glyphs where isNotehead(g.semantic) {
                let key = pitchKey(noteheadY: g.raw.origin.y, anchor: anchor)
                pitches.append(midiPitch(
                    step: key.diatonicStep, octave: key.octave, alteration: 0,
                ))
            }
        }
        return pitches
    }

    /// True when this staff's first-read clef is the ambiguous E065 (F8va).
    /// Used by the assembler's pre-pass to know which slots need the
    /// whole-part F8va-vs-plain-F content decision.
    static func staffInitialClefIsF8va(_ staff: ImportStaff) -> Bool {
        for measure in staff.measures {
            let sorted = measure.glyphs.sorted { $0.raw.origin.x < $1.raw.origin.x }
            if let clef = readClef(from: sorted) {
                return clef.concertClefType == "F8va"
            }
        }
        return false
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
