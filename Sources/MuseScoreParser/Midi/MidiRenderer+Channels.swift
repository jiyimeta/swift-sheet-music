import Foundation

extension MidiRenderer {
    /// Assign a unique MIDI channel index to each `<Channel>` of every part.
    /// - Explicit `<midiChannel>` is honoured.
    /// - Otherwise channels are allocated sequentially from a counter, skipping 9
    ///   (the GM drum channel) so it stays available for explicit drum kits.
    static func assignChannels(score: Score) -> [[ChannelAssignment]] {
        var perPart: [[ChannelAssignment]] = Array(repeating: [], count: score.parts.count)
        var nextChannel = 0
        func takeChannel() -> Int {
            if nextChannel == 9 { nextChannel = 10 }
            let c = nextChannel
            nextChannel += 1
            return c
        }
        for (partIndex, part) in score.parts.enumerated() {
            for flavour in part.instrument.channels {
                let channel = flavour.midiChannel ?? takeChannel()
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
            for offset in 0..<stavesInPart {
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
