import Foundation
import Wirelet

/// One General-MIDI Level 1 melodic program (0...127), with the
/// canonical name and family grouping. Drives the program picker
/// in the mixer.
///
/// `@WireFormat` synthesizes a `WireFormat` conformance whose encoded
/// layout is each stored property in declaration order: `program` (u8),
/// `name` (i32-prefixed UTF-8), `family` (u8 ordinal). The blob has no
/// envelope — `[GMInstrument]` encodes as the standard
/// `Array<T: WireFormat>` (i32 length prefix + elements).
@WireFormat
public struct GMInstrument: Sendable, Equatable, Identifiable {
    public let program: UInt8 // 0...127
    public let name: String
    public let family: Family
    public var id: UInt8 {
        program
    }

    /// 16 GM families, each spanning 8 consecutive programs. Used
    /// to group the picker's 128-item list under collapsible
    /// section headers so the user isn't scrolling a flat list.
    ///
    /// Wire layout: `UInt8` = ordinal in `allCases` (0...15).
    @WireFormatEnum
    public enum Family: String, CaseIterable, Sendable {
        case piano = "Piano"
        case chromaticPercussion = "Chromatic Percussion"
        case organ = "Organ"
        case guitar = "Guitar"
        case bass = "Bass"
        case strings = "Strings"
        case ensemble = "Ensemble"
        case brass = "Brass"
        case reed = "Reed"
        case pipe = "Pipe"
        case synthLead = "Synth Lead"
        case synthPad = "Synth Pad"
        case synthEffects = "Synth Effects"
        case ethnic = "Ethnic"
        case percussive = "Percussive"
        case soundEffects = "Sound Effects"

        /// Programs within the family, in canonical 0...127 order.
        public var programs: [GMInstrument] {
            GMInstrument.all.filter { $0.family == self }
        }
    }

    /// All 128 GM programs in order.
    public static let all: [GMInstrument] = zip(GMInstrument.names, 0 ..< UInt8(GMInstrument.names.count))
        .map { name, program in
            GMInstrument(
                program: program,
                name: name,
                family: GMInstrument.family(for: program),
            )
        }

    /// Look up the GM program by number. Falls back to a synthetic
    /// "Program N" entry for out-of-range values so calling code
    /// never fails on a stored program byte.
    public static func instrument(for program: UInt8) -> GMInstrument {
        if program < all.count { return all[Int(program)] }
        return GMInstrument(
            program: program,
            name: "Program \(program)",
            family: .soundEffects,
        )
    }

    private static func family(for program: UInt8) -> Family {
        // Each family is 8 programs wide; index = program / 8.
        let idx = Int(program / 8)
        let families = Family.allCases
        return idx < families.count ? families[idx] : .soundEffects
    }

    /// Names from the GM Level 1 specification, in program order.
    private static let names: [String] = [
        // 0...7 Piano
        "Acoustic Grand Piano", "Bright Acoustic Piano",
        "Electric Grand Piano", "Honky-tonk Piano",
        "Electric Piano 1", "Electric Piano 2",
        "Harpsichord", "Clavinet",
        // 8...15 Chromatic Percussion
        "Celesta", "Glockenspiel", "Music Box", "Vibraphone",
        "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
        // 16...23 Organ
        "Drawbar Organ", "Percussive Organ", "Rock Organ",
        "Church Organ", "Reed Organ", "Accordion",
        "Harmonica", "Tango Accordion",
        // 24...31 Guitar
        "Acoustic Guitar (nylon)", "Acoustic Guitar (steel)",
        "Electric Guitar (jazz)", "Electric Guitar (clean)",
        "Electric Guitar (muted)", "Overdriven Guitar",
        "Distortion Guitar", "Guitar Harmonics",
        // 32...39 Bass
        "Acoustic Bass", "Electric Bass (finger)",
        "Electric Bass (pick)", "Fretless Bass",
        "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
        // 40...47 Strings
        "Violin", "Viola", "Cello", "Contrabass",
        "Tremolo Strings", "Pizzicato Strings",
        "Orchestral Harp", "Timpani",
        // 48...55 Ensemble
        "String Ensemble 1", "String Ensemble 2",
        "Synth Strings 1", "Synth Strings 2",
        "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
        // 56...63 Brass
        "Trumpet", "Trombone", "Tuba", "Muted Trumpet",
        "French Horn", "Brass Section",
        "Synth Brass 1", "Synth Brass 2",
        // 64...71 Reed
        "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax",
        "Oboe", "English Horn", "Bassoon", "Clarinet",
        // 72...79 Pipe
        "Piccolo", "Flute", "Recorder", "Pan Flute",
        "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
        // 80...87 Synth Lead
        "Lead 1 (square)", "Lead 2 (sawtooth)",
        "Lead 3 (calliope)", "Lead 4 (chiff)",
        "Lead 5 (charang)", "Lead 6 (voice)",
        "Lead 7 (fifths)", "Lead 8 (bass + lead)",
        // 88...95 Synth Pad
        "Pad 1 (new age)", "Pad 2 (warm)",
        "Pad 3 (polysynth)", "Pad 4 (choir)",
        "Pad 5 (bowed)", "Pad 6 (metallic)",
        "Pad 7 (halo)", "Pad 8 (sweep)",
        // 96...103 Synth Effects
        "FX 1 (rain)", "FX 2 (soundtrack)",
        "FX 3 (crystal)", "FX 4 (atmosphere)",
        "FX 5 (brightness)", "FX 6 (goblins)",
        "FX 7 (echoes)", "FX 8 (sci-fi)",
        // 104...111 Ethnic
        "Sitar", "Banjo", "Shamisen", "Koto",
        "Kalimba", "Bagpipe", "Fiddle", "Shanai",
        // 112...119 Percussive
        "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock",
        "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
        // 120...127 Sound Effects
        "Guitar Fret Noise", "Breath Noise", "Seashore",
        "Bird Tweet", "Telephone Ring", "Helicopter",
        "Applause", "Gunshot",
    ]
}
