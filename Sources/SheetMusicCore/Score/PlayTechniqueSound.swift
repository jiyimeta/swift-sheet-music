import SheetMusicFoundation

/// What a play technique sounds like on an instrument. MuseScore 4 pairs a technique with the instrument's `<Channel>`
/// of the same name (`CompatUtils`' table, `compatutils.cpp:195-208`), and otherwise plays the General MIDI sound its
/// `articulationSounds` table names for the instrument's family (`soundmapping.h:880-1015`).
package enum PlayTechniqueSound {
    package enum Outcome: Sendable, Equatable {
        /// The instrument's normal sound.
        case keep
        /// One of the instrument's own `<Channel>`s.
        case channel(InstrumentChannel)
        /// A General MIDI program, bank 0, in place of the primary channel's.
        case generalMIDI(program: Int)
    }

    /// The `<Channel>` name a technique selects, MuseScore's old Staff Text Properties names.
    package static func channelName(_ technique: PlayingTechnique) -> String? {
        switch technique {
        case .pizzicato: "pizzicato"
        case .tremolo: "tremolo"
        case .mute: "mute"
        case .open: "open"
        case .distortion: "distortion"
        case .overdrive: "overdriven"
        case .harmonics: "harmonics"
        case .jazzTone: "jazz"
        default: nil
        }
    }

    private static func displayName(_ technique: PlayingTechnique) -> String {
        switch technique {
        case .pizzicato: "Pizzicato"
        case .tremolo: "Tremolo"
        case .mute: "Mute"
        case .open: "Open"
        case .distortion: "Distortion"
        case .overdrive: "Overdrive"
        case .harmonics: "Harmonics"
        case .jazzTone: "Jazz tone"
        default: technique.mscxToken
        }
    }

    package static func resolve(_ technique: PlayingTechnique, for instrument: Instrument) -> Outcome {
        guard !instrument.useDrumset, technique != .natural, let name = channelName(technique) else { return .keep }
        if let channel = instrument.channels.first(where: { $0.name?.lowercased() == name }) {
            return .channel(channel)
        }
        return generalMIDIProgram(technique, instrumentID: instrument.id.lowercased()).map { .generalMIDI(program: $0) }
            ?? .keep
    }

    /// `articulationSounds` by the instrument's MuseScore id, grouped the way MuseScore's id tables group them
    /// (`windssetupdataresolver.cpp`, `stringssetupdataresolver.cpp`): a family is a whole id or a whole hyphen segment
    /// of one, so a contrabassoon is no contrabass and steel drums are no guitar. A solo bowed string has its
    /// pizzicato only: the violin's, viola's and double bass's mute rows name their own normal program, and the
    /// cello's an MS Basic sound whose bank-0 program (49) is a string ensemble. The cornet and flugelhorn are sounds
    /// of their own outside MuseScore's brass section and keep theirs, as MuseScore does.
    ///
    /// Two deliberate departures keep their instrument's sound where MuseScore would not: bass guitars, whose rows name
    /// acoustic and electric instruments these ids do not tell apart, and the harp, plucked and folk strings, which
    /// MuseScore's last strings rule (`BASIC_STRING_SECTION`) would turn into a string ensemble's pizzicato and mute.
    ///
    /// Always bank 0. The table's other banks — 20/30/40/50 for the bowed solo and section sounds, 8 for an acoustic
    /// guitar's harmonics — are MS Basic's own, and a General MIDI font (folino ships GeneralUser GS) has none of them.
    private static func generalMIDIProgram(_ technique: PlayingTechnique, instrumentID id: String) -> Int? {
        let segments = id.split(separator: "-").map(String.init)
        if let strings = bowedStrings(id) {
            switch technique {
            case .pizzicato: return 45
            case .tremolo where strings == .section: return 44
            case .mute where strings != .solo: return 49
            default: return nil
            }
        }
        if isBrass(id, segments: segments) {
            return technique == .mute ? 59 : nil
        }
        if segments.contains("guitar"), !segments.contains("bass"), !segments.contains("drums") {
            let electric = id.contains("electric") || id.contains("overdriven") || id.contains("distortion")
            switch technique {
            case .mute: return 28
            case .harmonics: return 31
            case .jazzTone: return 26
            case .distortion where electric: return 30
            case .overdrive where electric: return 29
            default: return nil
            }
        }
        return nil
    }

    /// MuseScore's bowed-string rows: `VIOLIN` and its kin for a solo, the `…_SECTION` rows (and `BASIC_VIOL_SECTION`
    /// for the viols) for a section, `BASIC_STRING_SECTION` — no tremolo — for the strings group.
    private enum BowedStrings {
        case solo, section, group
    }

    /// `cello` is not a MuseScore id but one this package's own part plans use.
    private static func bowedStrings(_ id: String) -> BowedStrings? {
        switch id {
        case "violin", "viola", "violoncello", "cello", "contrabass", "double-bass": .solo
        case "violins", "violas", "violoncellos", "contrabasses", "treble-viol", "alto-viol", "pardessus-de-viole",
             "tenor-viol", "baryton", "viola-da-gamba", "viola-da-gamba-tablature", "violone", "d-violone": .section
        case "strings", "octobass": .group
        default: nil
        }
    }

    /// MuseScore's `BRASS_SECTION`: the bugles, euphoniums, horns, trumpets, trombones and tubas. The English horn
    /// and the basset horn are reeds, and the euphonium and mellophone bugles are sounds of their own.
    private static func isBrass(_ id: String, segments: [String]) -> Bool {
        let families: Set = ["trumpet", "trombone", "tuba", "euphonium", "horn", "bugle"]
        guard !["english-horn", "basset-horn", "euphonium-bugle", "mellophon-bugle"].contains(id) else { return false }
        return segments.contains(where: families.contains)
    }

    /// The instrument a technique's sound plays as: itself to keep; its named channel alone, or its primary channel
    /// with the General MIDI program — labeled with the technique, so a mixer row reads "Violin (Pizzicato)".
    package static func variant(of instrument: Instrument, technique: PlayingTechnique, outcome: Outcome)
        -> Instrument
    {
        var variant = instrument
        switch outcome {
        case .keep:
            return instrument
        case var .channel(channel):
            channel.midiChannel = nil
            variant.channels = [channel]
        case let .generalMIDI(program):
            var channel = instrument.channel
            channel.program = program
            channel.bank = 0
            channel.name = channelName(technique)
            channel.midiChannel = nil
            variant.channels = [channel]
        }
        variant.trackName = displayName(technique)
        return variant
    }
}
