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

    /// GM drum-kit pitch → percussion-staff line index. The table itself lives in `SheetMusicCore` as
    /// `GMPercussion.drumLineMap` so an imported kit and one authored through `Score.blank(_:)` place the
    /// same drum on the same line; this is the importer-local spelling of that one definition.
    static let gmDrumLines: [Int: Int] = GMPercussion.drumLineMap
}
