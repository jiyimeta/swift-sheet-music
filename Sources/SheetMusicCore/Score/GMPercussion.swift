import SheetMusicFoundation

/// The General MIDI percussion conventions used when *authoring* a drum staff — `MidiImporter` (which has to
/// invent a drum staff for a channel-10 track) and the blank-score factory, plus any command that adds a drum
/// part to an existing score. One definition so an authored kit and an imported one place the same drum on
/// the same line.
///
/// This is NOT "the" drum table. `PDFImporter.defaultDrumLineMap` is deliberately a different one —
/// MuseScore 3's stock drumset, whose lines are what actually positioned the noteheads in the PDF being
/// read. Reconciling the two would move already-engraved notes off their own ink, so leave it alone.
public enum GMPercussion {
    /// GM drum-kit pitch → percussion-staff line index (0 = top line, 4 = middle, 8 = bottom line; negative =
    /// above-staff ledger; ≥ 9 = below-staff). Consumed through `Instrument.drumLineMap`, which the layout
    /// engine reads to place the notehead at the conventional position for that drum instead of applying the
    /// pitched diatonic formula.
    ///
    /// The lines themselves live in `GMDrumset.entries` now, alongside the head, voice and name that belong to
    /// the same drum; this is the lines-only projection every existing caller was written against.
    public static let drumLineMap: [Int: Int] = GMDrumset.entries.mapValues(\.line)

    /// MuseScore's `<StaffType><name>` for a five-line drum staff. Using `stdNormal` for a
    /// percussion-grouped staff confuses MuseScore's loader: it treats the staff as pitched and ignores the
    /// per-pitch `<Drum>` line positions, collapsing every drum onto the same line visually.
    public static let staffTypeName = "perc5Line"

    /// MuseScore's `<StaffType group="…">` for a drum staff.
    public static let staffGroup = "percussion"
}
