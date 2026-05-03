import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// GM percussion channel (0-indexed). DAWs like Logic Pro auto-detect any
    /// MIDI events on this channel as drums and load a drum-kit patch.
    static let drumChannel = 9

    /// Assign a unique MIDI channel index to each `<Channel>` of every part.
    /// - Explicit `<midiChannel>` is honoured.
    /// - Drumset instruments (`<useDrumset>1</useDrumset>`) are auto-routed to
    ///   GM channel 10 (0-indexed: 9). Multiple drumset parts share that
    ///   channel — General MIDI percussion is keyed on note number, not part.
    /// - Other parts are allocated sequentially from a counter, skipping 9 so
    ///   it stays reserved for percussion.
    /// Mirrors MuseScore's `MasterScore::reorderMidiMapping` /
    /// `addMidiMapping` logic in `dom/midimapping.cpp:300`.
    static func assignChannels(score: Score) -> [[ChannelAssignment]] {
        var perPart: [[ChannelAssignment]] = Array(repeating: [], count: score.parts.count)
        var nextChannel = 0
        func takeChannel() -> Int {
            if nextChannel == drumChannel { nextChannel = drumChannel + 1 }
            let c = nextChannel
            nextChannel += 1
            return c
        }
        for (partIndex, part) in score.parts.enumerated() {
            let isDrumset = part.instrument.useDrumset
            for flavour in part.instrument.channels {
                let channel: Int
                if let explicit = flavour.midiChannel {
                    channel = explicit
                } else if isDrumset {
                    channel = drumChannel
                } else {
                    channel = takeChannel()
                }
                perPart[partIndex].append(ChannelAssignment(channel: channel, flavour: flavour))
            }
        }
        return perPart
    }
}
