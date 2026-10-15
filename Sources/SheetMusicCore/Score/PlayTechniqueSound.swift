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

    /// `articulationSounds` by the instrument's id family. Bass guitars, a solo cello's mute and a solo double bass
    /// are left on their normal sound: their MuseScore rows name instruments these ids do not tell apart.
    private static func generalMIDIProgram(_ technique: PlayingTechnique, instrumentID id: String) -> Int? {
        let strings = ["violin", "viola", "violoncello", "cello", "contrabass", "strings"]
        let brass = [
            "trumpet",
            "bb-trumpet",
            "c-trumpet",
            "cornet",
            "flugelhorn",
            "trombone",
            "bass-trombone",
            "horn",
            "french-horn",
            "tuba",
            "euphonium",
        ]
        if strings.contains(where: id.hasPrefix) {
            let section = id.contains("strings") || id.contains("group")
            switch technique {
            case .pizzicato: return 45
            case .tremolo where section: return 44
            case .mute where section: return 49
            default: return nil
            }
        }
        if brass.contains(where: id.hasPrefix) {
            return technique == .mute ? 59 : nil
        }
        if id.contains("guitar"), !id.contains("bass") {
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
