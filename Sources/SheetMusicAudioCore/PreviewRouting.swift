import SheetMusicCore
import SheetMusicFoundation

/// Where an audition of a note sounds: the tick the note sits at, and the live channel its staff plays on there.
///
/// Shared by every engine that auditions a note at the cursor (the Apple `PlaybackEngine`, the Windows
/// `WindowsPlaybackEngine`), so a note after a mid-score instrument change is heard in the new instrument on every
/// platform rather than in the part's opening one.
package enum PreviewRouting {
    /// The live channel `staff` sounds on at `tick`: its part's opening channel, moved by every instrument change at or
    /// before `tick`. `nil` for a staff the layout does not know.
    ///
    /// - Parameters:
    ///   - openingChannels: each flat staff's tick-0 channel (`PlaybackChannelLayout.staffMIDIChannels`).
    ///   - switches: each flat staff's instrument changes, ascending by tick (`PreparedPlayback.staffChannelSwitches`).
    package static func channel(
        forStaff staff: Int, atTick tick: Int, openingChannels: [Int: UInt8], switches: [Int: [StaffChannelSwitch]],
    ) -> UInt8? {
        var result = openingChannels[staff]
        guard let staffSwitches = switches[staff] else { return result }
        for entry in staffSwitches {
            if entry.tick <= tick { result = entry.channel } else { break }
        }
        return result
    }

    /// The absolute tick `noteID` sits at, on the plain (non-breath-budgeted) measure durations `PreparedPlayback`
    /// builds the channel-switch table on, so a lookup through `channel(forStaff:atTick:openingChannels:switches:)`
    /// compares like with like. The in-measure offset alone when the measure index does not resolve.
    package static func tick(of noteID: NoteID, in score: Score) -> Int {
        let inMeasure = score.resolveTickInMeasure(for: .note(noteID)) ?? 0
        let durations = score.effectiveMeasureDurations()
        guard durations.indices.contains(noteID.measureIndex) else { return inMeasure }
        var base = 0
        for index in 0 ..< noteID.measureIndex {
            base += durations[index].ticks(division: score.division)
        }
        return base + inMeasure
    }
}
