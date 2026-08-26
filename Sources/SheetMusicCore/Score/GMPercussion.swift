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
    public static let drumLineMap: [Int: Int] = [
        35: 6, // Acoustic Bass Drum (bottom space)
        36: 6, // Bass Drum 1
        37: 2, // Side Stick (3rd line)
        38: 2, // Acoustic Snare (3rd line)
        39: 2, // Hand Clap
        40: 2, // Electric Snare
        41: 8, // Low Floor Tom (bottom line)
        42: -1, // Closed Hi-Hat (above top line)
        43: 7, // High Floor Tom (between bottom space and bottom line)
        44: 9, // Pedal Hi-Hat (below staff)
        45: 5, // Low Tom (4th line)
        46: -1, // Open Hi-Hat (above top line)
        47: 4, // Low-Mid Tom (middle line)
        48: 3, // Hi-Mid Tom
        49: -1, // Crash Cymbal 1 (above top line)
        50: 2, // High Tom
        51: 0, // Ride Cymbal 1 (top line)
        52: -1, // Chinese Cymbal
        53: 0, // Ride Bell
        54: 0, // Tambourine (top line, with diamond head ideally)
        55: -1, // Splash Cymbal
        56: 0, // Cowbell
        57: -1, // Crash Cymbal 2
        58: 1, // Vibraslap
        59: 0, // Ride Cymbal 2
        60: 1, // Hi Bongo
        61: 2, // Low Bongo
    ]

    /// MuseScore's `<StaffType><name>` for a five-line drum staff. Using `stdNormal` for a
    /// percussion-grouped staff confuses MuseScore's loader: it treats the staff as pitched and ignores the
    /// per-pitch `<Drum>` line positions, collapsing every drum onto the same line visually.
    public static let staffTypeName = "perc5Line"

    /// MuseScore's `<StaffType group="…">` for a drum staff.
    public static let staffGroup = "percussion"
}
