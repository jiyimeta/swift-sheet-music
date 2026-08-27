#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Staff-step tables and spacing used when laying out a key signature.
///
/// "Step" is a half-staff-space ordinal: the middle line is 0, the
/// space above it is +1, the line above that is +2, and so on. Sharp
/// and flat key signatures use distinct, fixed step sequences chosen
/// to keep the accidental cluster tightly inside the staff.
///
/// **The sequence depends on the clef in force.** MuseScore keeps one
/// 14-entry line table per clef (`ClefInfo::lines`, `dom/clef.cpp`),
/// the first 7 for sharps and the last 7 for flats, and
/// `TLayout::layoutKeySig` looks up the clef that precedes the key
/// signature before placing a single glyph. Most clefs are the treble
/// table shifted by whole steps — F clefs by −2, C3 by −1 — but the
/// tenor (C4) and soprano (C1) tables also raise individual
/// accidentals by an octave to keep the cluster off ledger lines, so
/// a uniform offset per clef is NOT enough.
public enum KeySignatureSteps {
    /// Steps for each sharp in canonical engraving order
    /// (F♯, C♯, G♯, D♯, A♯, E♯, B♯) under `clef`. Middle line = 0,
    /// positive = up.
    public static func sharps(for clef: NotatedClef) -> [Int] {
        table(for: clef).sharps
    }

    /// Steps for each flat in canonical engraving order
    /// (B♭, E♭, A♭, D♭, G♭, C♭, F♭) under `clef`.
    public static func flats(for clef: NotatedClef) -> [Int] {
        table(for: clef).flats
    }

    /// The steps a `.keySignature` layout element should draw, in
    /// left-to-right order. Exactly one of `sharps` / `flats` is
    /// non-zero in a standard key signature; a zero-accidental key
    /// yields an empty array.
    public static func steps(
        sharps: Int, flats: Int, clef: NotatedClef,
    ) -> [Int] {
        let count = max(0, sharps) + max(0, flats)
        guard count > 0 else { return [] }
        let table = sharps > 0 ? self.sharps(for: clef) : self.flats(for: clef)
        return Array(table.prefix(count))
    }

    /// Steps for the naturals that cancel `priorKey` — the positions of
    /// the OUTGOING key's own accidentals, in that key's own engraving
    /// order, so D→C draws naturals at F♯ and C♯. A key with no
    /// accidentals has nothing to cancel and yields an empty array.
    ///
    /// This is deliberately the outgoing key's table and not the
    /// incoming one: a natural belongs where the accidental it retires
    /// used to sit. MuseScore does the same in `KeySig::layout`, which
    /// walks the old key's `KeySigEvent` when building the naturals it
    /// draws ahead of the new signature.
    public static func naturalSteps(
        cancelling priorKey: Int, clef: NotatedClef,
    ) -> [Int] {
        steps(
            sharps: max(0, priorKey), flats: max(0, -priorKey), clef: clef,
        )
    }

    /// The naturals an explicit key change from `priorKey` to `newKey`
    /// draws, under the engraving rule this package implements: only a
    /// change that lands on C (zero accidentals) cancels, and it cancels
    /// the whole outgoing key. Every other change draws its new
    /// signature alone.
    ///
    /// Cancelling on every reduction (G→F showing a natural for F♯) is a
    /// possible future style option; MuseScore's default — and Behind
    /// Bars — is the zero-accidental rule.
    public static func cancellationNaturals(
        priorKey: Int, newKey: Int, clef: NotatedClef,
    ) -> [Int] {
        guard newKey == 0, priorKey != 0 else { return [] }
        return naturalSteps(cancelling: priorKey, clef: clef)
    }

    /// Horizontal advance between consecutive accidentals. 1 sp causes
    /// visible overlap at 5+-accidental keys (sharp glyphs are ~1 sp
    /// wide but the optical side-bearing needs more breathing room);
    /// 1.4 sp matches MuseScore's defaults.
    public static func advance(sp: CGFloat) -> CGFloat {
        sp * 1.4
    }

    /// Convert a step value to a Y offset relative to the staff-middle
    /// reference Y. Positive step = up, which is `-dy` in y-down screen
    /// coordinates.
    public static func stepDy(step: Int, sp: CGFloat) -> CGFloat {
        -CGFloat(step) * sp / 2
    }

    // MARK: - Per-clef tables

    /// Transcribed from MuseScore's `ClefInfo` table
    /// (`engraving/dom/clef.cpp:50-83`), whose entries are staff LINES
    /// counted downward from the top line. This type's steps count
    /// upward from the middle line, so `step = 4 - line`.
    private static func table(
        for clef: NotatedClef,
    ) -> (sharps: [Int], flats: [Int]) {
        switch clef {
        // ClefType::G and its octave variants share one row; PERC /
        // PERC2 reuse it as well.
        case .treble, .treble8va, .treble8vb, .treble15ma, .treble15mb,
             .percussion, .percussion2:
            ([4, 1, 5, 2, -1, 3, 0], [0, 3, -1, 2, -2, 1, -3])
        // ClefType::F and its octave variants — the treble table
        // lowered by one line (2 steps).
        case .bass, .bass8va, .bass8vb:
            ([2, -1, 3, 0, -3, 1, -2], [-2, 1, -3, 0, -4, -1, -5])
        // ClefType::C1.
        case .soprano:
            ([-1, 3, 0, 4, 1, 5, 2], [2, -2, 1, -3, 0, -4, -1])
        // ClefType::C3.
        case .alto:
            ([3, 0, 4, 1, -2, 2, -1], [-1, 2, -2, 1, -3, 0, -4])
        // ClefType::C4 — note F♯ sits BELOW C♯ here; the tenor table
        // is not the treble one shifted uniformly.
        case .tenor:
            ([-2, 2, -1, 3, 0, 4, 1], [1, 4, 0, 3, -1, 2, -2])
        // ClefType::C5.
        case .baritone:
            ([0, 4, 1, 5, 2, -1, 3], [3, -1, 2, -2, 1, -3, 0])
        }
    }
}
