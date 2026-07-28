#if canImport(CoreGraphics)
    import CoreGraphics
#endif
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
        diagnostics: ((PDFImportDiagnostic) -> Void)? = nil,
        location: String = "",
    ) -> [ScoreStateEvent] {
        var events: [ScoreStateEvent] = []
        // Running clef across measures: a mid-piece key signature can sit on a
        // measure that declares no clef of its own, yet the canonical
        // key-accidental ladder (see `readKey`) is anchored to the clef in
        // force. Carry the last-seen clef forward so `readKey` always has the
        // right ladder. (F8va → plain-F downgrade happens later in
        // `buildMeasures`, but both share a bottom-line step so the ladder is
        // identical — no interaction.)
        var runningClef = Clef(concertClefType: "G")
        // Running key across measures: a mid-score change engraved as a
        // naturals-only cancellation is only recognizable relative to the
        // key it cancels, so `readKey` / `readTrailingKey` need the key in
        // force (see PDFImporter+KeyReader). Starts at C major (0).
        var runningKey = KeySignature(concertKey: 0)
        for (i, measure) in staff.measures.enumerated() {
            let sorted = measure.glyphs.sorted { $0.geometry.origin.x < $1.geometry.origin.x }
            if let clef = readClef(from: sorted) {
                runningClef = clef
                events.append(.clefChange(clef, atMeasureIndex: i))
            }
            if let key = readKey(
                sorted: sorted, clef: runningClef, yLines: measure.staffYLines,
                runningKey: runningKey,
            ) {
                runningKey = key
                events.append(.keySignature(key, atMeasureIndex: i))
            }
            if let timeSig = readTime(from: sorted) {
                // Validate before the signature enters the score state: a PDF
                // is hostile input, and stray digit glyphs (e.g. a horizontal
                // "90" from a metronome number engraved with SMuFL time-sig
                // digits) can decode as nonsense like 9/0. A non-positive
                // numerator or denominator would crash `Fraction` downstream
                // (bar-length math) — drop the event so the prevailing time
                // signature (else the 4/4 default) stays in force, and warn.
                if timeSig.numerator > 0, timeSig.denominator > 0 {
                    events.append(.timeSignature(timeSig, atMeasureIndex: i))
                } else {
                    diagnostics?(PDFImportDiagnostic(
                        severity: .warning,
                        location: "\(location), measure \(i)",
                        message: "ignoring invalid time signature "
                            + "\(timeSig.numerator)/\(timeSig.denominator) — "
                            + "keeping the prevailing time signature",
                    ))
                }
            }
            // A clef change engraved at the END of this measure (a trailing
            // courtesy clef, after all notes/rests) takes effect at the NEXT
            // measure — MuseScore's before-the-barline semantics. Emit it at
            // i+1 so a mid-system clef change is caught immediately rather
            // than a whole system late. Idempotent with the next system's
            // leading re-read. Also advance `runningClef` so measure i+1's
            // key ladder (A1) anchors to the clef now in force; a no-op for
            // same-family changes (カゲロウ G↔G8vb share a ladder shift) but
            // correct should a bass↔treble change ever coincide with a key.
            if i + 1 < staff.measures.count,
               let trailing = readTrailingClef(from: sorted)
            {
                events.append(.clefChange(trailing, atMeasureIndex: i + 1))
                runningClef = trailing
            }
            // A to-C key change on the next system's first measure is drawn
            // as a trailing courtesy cancellation here (naturals only) and —
            // unlike a clef — is NOT re-shown at the incoming system's start,
            // so read it now and apply at i+1, mirroring the trailing clef.
            // We emit even at the last index (i+1 == count): `appendSystem`
            // folds that boundary event into the key carried to the next
            // system. Mid-system (i+1 < count) it applies to measure i+1.
            if let trailingKey = readTrailingKey(
                sorted: sorted, clef: runningClef,
                yLines: measure.staffYLines, runningKey: runningKey,
            ) {
                runningKey = trailingKey
                events.append(.keySignature(trailingKey, atMeasureIndex: i + 1))
            }
        }
        // Tempo is a system-level marking → recovered separately into
        // `Score.systemMeasures`; see PDFImporter+Tempo.
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
    /// Scoped narrowly: only an F8va clef is ever rewritten. F8va parts whose
    /// content is genuinely in the octave-up register (君とParadiso part 4)
    /// are left untouched. E065 does not appear in the other curated corpus
    /// scores, so this is a no-op for them.
    ///
    /// The REAL corpus adds a third — and most common — source of E065: an
    /// octave-transposing electric bass (sounding −12) whose arranger set the
    /// written-mode clef to "bass clef 8va alta". The clef's +12 and the
    /// instrument's −12 cancel, so the staff SOUNDS at the plain-F reading
    /// (Magnetic_Short / Love Song / チャンカパーナ, each whole-part +12 under
    /// the kept F8va). Register alone cannot separate that from a genuine
    /// F8va vocal bass — the two populations are IDENTICAL under the F8va
    /// anchor (君とParadiso mean 55.5 / p75 58 vs Magnetic_Short 55.7 / 58) —
    /// so a second, ensemble-level signal decides:
    ///
    /// **Ensemble voicing.** System staves are ordered by register, top to
    /// bottom; the bass staff sounds BELOW the pitched staff above it. Read
    /// at F8va, a decorative-8 bass line rises INTO the upper neighbor's
    /// tessitura — the share of its notes at or above the neighbor's 25th
    /// percentile is large (Magnetic_Short 55%, Love Song 74%, 地球儀 69%),
    /// while a genuine F8va part still sits clearly below the voice above it
    /// (君とParadiso 9%, 魅惑のバニラ 25%). The threshold sits at 2/5 —
    /// midway between the two observed populations, 15 points of margin to
    /// the nearest member on either side. Overlap ≥ 2/5 ⇒ the "8" is
    /// decorative → downgrade to plain F.
    ///
    /// `f8vaPitches` is the part's ENTIRE notehead population decoded under the
    /// tentative F8va anchor — aggregated across every system the part spans,
    /// not just one system. A per-system decision is noisy: a system that
    /// happens to hold only the part's lower notes can read below the
    /// threshold and keep F8va while a busier system downgrades, leaving the
    /// staff with mixed octaves. Deciding once from the whole part is stable.
    /// `upperNeighborPitches` is the same-aggregated own-clef register profile
    /// of the nearest PITCHED staff slot above (nil when there is none —
    /// then only the absolute-register test applies).
    static func disambiguateF8vaClef(
        _ clef: Clef, f8vaPitches pitches: [Int],
        upperNeighborPitches: [Int]? = nil,
    ) -> Clef {
        guard clef.concertClefType == "F8va" else { return clef }
        // Need a few notes to judge a register; otherwise trust the glyph.
        guard pitches.count >= 8 else { return clef }
        let sorted = pitches.sorted()
        let mean = sorted.reduce(0, +) / sorted.count
        let p75 = sorted[sorted.count * 3 / 4]
        // Absolute register: under the F8va anchor a genuine F8va part stays
        // within a normal bass tessitura (君とParadiso part 4: mean 55,
        // p75 58); a plain-F part mis-anchored an octave up overshoots it
        // (地球儀 part 5: mean 59, p75 65). Either signal crossing its
        // threshold marks the part as too high to be a real F8va, so the
        // engraver's "8"-decorated glyph is an ordinary bass clef.
        if mean >= 58 || p75 >= 62 {
            return Clef(concertClefType: "F")
        }
        // Ensemble voicing (see the doc comment): a bass line whose F8va
        // reading seats ≥ 2/5 of its notes at or above the upper pitched
        // neighbor's tessitura floor (25th percentile) is not the system's
        // bottom voice under that reading — the "8" is decorative.
        if let neighbor = upperNeighborPitches, neighbor.count >= 8 {
            let tessituraFloor = neighbor.sorted()[neighbor.count / 4]
            let overlapping = sorted.count { $0 >= tessituraFloor }
            if overlapping * 5 >= sorted.count * 2 {
                return Clef(concertClefType: "F")
            }
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
                let key = pitchKey(noteheadY: g.geometry.origin.y, anchor: anchor)
                pitches.append(midiPitch(
                    step: key.diatonicStep, octave: key.octave, alteration: 0,
                ))
            }
        }
        return pitches
    }

    /// Decode every notehead of `staff` under the staff's OWN running clef
    /// (leading re-reads only, alteration-free) — the register profile a
    /// staff slot contributes as the upper-neighbor reference in
    /// `disambiguateF8vaClef`'s ensemble-voicing test. Returns nil for a
    /// percussion staff (its notehead positions are drum slots, not a
    /// register — never a voicing reference).
    static func registerProfilePitches(staff: ImportStaff) -> [Int]? {
        var runningClef = Clef(concertClefType: "G")
        var pitches: [Int] = []
        for measure in staff.measures {
            let sorted = measure.glyphs.sorted { $0.geometry.origin.x < $1.geometry.origin.x }
            if let clef = readClef(from: sorted) {
                runningClef = clef
            }
            if runningClef.concertClefType == "PERCUSSION" { return nil }
            guard !measure.staffYLines.isEmpty,
                  let anchor = staffAnchor(
                      clef: runningClef, yLines: measure.staffYLines,
                  )
            else { continue }
            for g in measure.glyphs where isNotehead(g.semantic) {
                let key = pitchKey(noteheadY: g.geometry.origin.y, anchor: anchor)
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
            let sorted = measure.glyphs.sorted { $0.geometry.origin.x < $1.geometry.origin.x }
            if let clef = readClef(from: sorted) {
                return clef.concertClefType == "F8va"
            }
        }
        return false
    }

    // MARK: - Leading-region boundary

    /// True for a glyph that is measure CONTENT — a notehead or a rest.
    ///
    /// Engraving order inside a measure is clef → key → time → content, so the
    /// first content glyph ends the LEADING region: any clef / key / time
    /// glyph past it is a courtesy signature announcing the NEXT measure's
    /// change, not this measure's own.
    ///
    /// The leading readers used to end that region at the first NOTEHEAD.
    /// That silently failed for a measure holding no noteheads at all — an
    /// empty bar drawn as a single rest. The scan then ran to the end of the
    /// cell and read the trailing courtesy signature as the measure's own, one
    /// measure early. `Now_is_the_time_ms3.pdf` is exactly that case: the top
    /// staff's bar 3 is empty and ends a system whose next system opens a 2/4
    /// + 2-flat change, so its courtesy landed on bar 3, while every other
    /// staff — which has notes there, so a notehead stopped the scan — took
    /// the change at bar 4. The staves then disagreed about that bar's length
    /// and playback desynced.
    static func isLeadingRegionTerminator(_ semantic: SMuFLSemantic) -> Bool {
        if isNotehead(semantic) { return true }
        if case .rest = semantic { return true }
        return false
    }

    // MARK: - Clef

    /// The LEADING clef of a measure — the first clef glyph, scanning
    /// left-to-right, before any notehead. Returns nil once a notehead is
    /// reached (anything past it belongs to the notes, not the opening clef).
    private static func readClef(from glyphs: [ClassifiedGlyph]) -> Clef? {
        for glyph in glyphs {
            if let clef = clef(for: glyph.semantic) { return clef }
            // NOTE: deliberately a NOTEHEAD boundary, not the
            // `isLeadingRegionTerminator` (notehead-or-rest) one the key /
            // time readers use. Clefs already have a dedicated courtesy path
            // (`readTrailingClef`, applied at i + 1), and narrowing this scan
            // to stop at a rest measured WORSE on the corpus (カゲロウ's clef
            // running-match 1339 → 1338/1536): a clef drawn after a rest in a
            // rest-only measure is more often that measure's own late-drawn
            // clef than a courtesy for the next one. Left as-is on evidence.
            if isNotehead(glyph.semantic) { return nil }
        }
        return nil
    }

    /// A clef glyph engraved AFTER this measure's last notehead / rest — the
    /// small courtesy clef MuseScore draws just before the barline when the
    /// clef changes at the FOLLOWING measure boundary. Returns the clef the
    /// change introduces (the caller applies it at measure `i + 1`), or nil
    /// when the measure carries no post-content clef.
    ///
    /// A mid-system clef change is drawn ONCE, as this trailing glyph in
    /// measure i's cell — it is NOT re-shown at the start of measure i+1
    /// (only system-leading clefs are re-shown). Without reading it every
    /// mid-system clef change was missed until the next system re-showed the
    /// clef, shifting a run of measures an octave (カゲロウ p0 m68 read G8vb
    /// where truth is G → the whole cell an octave low). Emitting the change
    /// at i+1 is idempotent with the next system's leading re-read: both set
    /// the same clef at the same measure index.
    private static func readTrailingClef(from sorted: [ClassifiedGlyph]) -> Clef? {
        // x of the last content glyph (notehead or rest). A clef strictly to
        // its right is a trailing courtesy clef; a clef to its left is the
        // measure's own leading clef (handled by `readClef`), not a change.
        var lastContentX: CGFloat?
        for g in sorted {
            let isRest = if case .rest = g.semantic { true } else { false }
            if isNotehead(g.semantic) || isRest {
                lastContentX = g.geometry.origin.x
            }
        }
        guard let lastContentX else { return nil }
        for g in sorted where g.geometry.origin.x > lastContentX {
            if let clef = clef(for: g.semantic) { return clef }
        }
        return nil
    }

    /// Map a clef glyph's semantic to its `Clef`. Returns nil for any
    /// non-clef semantic. Shared by the leading (`readClef`) and trailing
    /// (`readTrailingClef`) readers.
    private static func clef(for semantic: SMuFLSemantic) -> Clef? {
        switch semantic {
        case .clefG: Clef(concertClefType: "G")
        case .clefG8vb: Clef(concertClefType: "G8vb")
        case .clefG8va: Clef(concertClefType: "G8va")
        case .clefG15ma: Clef(concertClefType: "G15ma")
        case .clefG15mb: Clef(concertClefType: "G15mb")
        case .clefF: Clef(concertClefType: "F")
        case .clefF8va: Clef(concertClefType: "F8va")
        case .clefF8vb: Clef(concertClefType: "F8vb")
        case .clefF15ma: Clef(concertClefType: "F15ma")
        case .clefF15mb: Clef(concertClefType: "F15mb")
        case .clefC: Clef(concertClefType: "C")
        case .clefPercussion: Clef(concertClefType: "PERCUSSION")
        default: nil
        }
    }

    // Time-signature reading lives in PDFImporter+TimeReader (split for the
    // SwiftLint length cap), key-signature reading in PDFImporter+KeyReader.
}
