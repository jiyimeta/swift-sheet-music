import SheetMusicCore
import SheetMusicFoundation

// MARK: - GM drum-kit tables

extension MidiImporter {
    /// GM drum-kit pitch → notehead shape. The standard
    /// percussion-clef convention uses `cross` for any cymbal /
    /// hi-hat (X notehead) and `normal` for membranophones (kick,
    /// snare, toms, etc.). Pitches not listed get `nil` and render
    /// as the default duration-based notehead.
    static let gmDrumHeads: [Int: String] = [
        // Membranophones (kick / snare / toms / hand-percussion)
        35: "normal", 36: "normal", 37: "normal",
        38: "normal", 39: "normal", 40: "normal",
        41: "normal", 43: "normal", 45: "normal",
        47: "normal", 48: "normal", 50: "normal",
        // Cymbals + hi-hats — cross noteheads
        42: "cross", 44: "cross", 46: "cross",
        49: "cross", 51: "cross", 52: "cross",
        53: "cross", 55: "cross", 57: "cross",
        59: "cross",
        // Cowbell / wood block / etc — triangle to set them apart
        56: "triangle-up", 58: "triangle-up",
        60: "triangle-up", 61: "triangle-up",
    ]

    /// Voice index a given GM drum pitch should belong to in the
    /// engraved drum staff.
    ///   - 0 = voice 1, stems up: cymbals, hi-hats, ride, snare,
    ///         toms (= "hands")
    ///   - 1 = voice 2, stems down: bass drum, low floor tom,
    ///         pedal hi-hat (= "feet")
    /// Matches MuseScore's default drumset partitioning.
    static func gmDrumVoiceIndex(for pitch: Int) -> Int {
        switch pitch {
        case 35, 36, 41, 44: 1
        default: 0
        }
    }

    /// GM drum-kit pitch → percussion-staff line index
    /// (0 = top line, 4 = middle, 8 = bottom line; negative =
    /// above-staff ledger; ≥ 9 = below-staff). Used by the layout
    /// engine via `Instrument.drumLineMap` to place the notehead
    /// at the conventional position for that drum.
    static let gmDrumLines: [Int: Int] = [
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
}
