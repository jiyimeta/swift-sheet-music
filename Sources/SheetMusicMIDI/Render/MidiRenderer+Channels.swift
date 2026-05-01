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

    /// Map each top-level staff to its owning part. mscx lists parts and top-level
    /// `<Staff id="N">` in matching document order; a part with K `<Staff>` declarations
    /// owns K consecutive top-level staves.
    static func staffOwnership(score: Score) -> [StaffOwnership] {
        var result: [StaffOwnership] = []
        var staffCursor = 0
        for (partIndex, part) in score.parts.enumerated() {
            let stavesInPart = max(1, part.staffDeclarations.count)
            for offset in 0 ..< stavesInPart {
                guard staffCursor < score.staves.count else { break }
                result.append(StaffOwnership(partIndex: partIndex, isTopOfPart: offset == 0))
                staffCursor += 1
            }
        }
        // Defensive padding if part declarations are off — keep them on the last part.
        while result.count < score.staves.count {
            result.append(StaffOwnership(partIndex: max(0, score.parts.count - 1), isTopOfPart: false))
        }
        return result
    }
}
