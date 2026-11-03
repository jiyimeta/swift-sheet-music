import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

// MARK: - Where a note audition sounds

extension AudioMidiBridge {
    /// What the Android engine needs to audition a note: the pitch, the flat staff it is on, the live channel and drum
    /// flag that staff sounds with at the note's tick, and the pitch wheel the note wants.
    package struct PreviewRoute: Equatable {
        package let pitch: Int
        package let staffIndex: Int
        package let channel: Int
        package let isDrum: Bool
        /// The note's microtonal offset as a pitch-wheel value (`MidiEvent.pitchBendValue(cents:)`); the center for a
        /// plain note and every drum.
        package let bend: Int

        package init(pitch: Int, staffIndex: Int, channel: Int, isDrum: Bool, bend: Int = MidiEvent.pitchBendCenter) {
            self.pitch = pitch
            self.staffIndex = staffIndex
            self.channel = channel
            self.isDrum = isDrum
            self.bend = bend
        }
    }

    /// Routes an audition of `noteID` as the Apple and Windows engines do (`PreviewRouting`): on the channel its staff
    /// plays at the note's tick, after every instrument change at or before it, rather than on the part's opening one.
    ///
    /// - Parameters:
    ///   - score: the score `noteID` addresses — the host's, which it edits in place. The note's pitch, staff and tick
    ///     come from here.
    ///   - prepared: the score the engine's synth was programmed from. Its channel layout and instrument changes do the
    ///     routing, as the Apple engine routes through the `PreparedPlayback` it installed: a channel the edit added is
    ///     not on the synth until the edit is adopted.
    ///   - pitch: the pitch to sound in the note's place, or `nil` for its own. A grace note has no `NoteID`, so its
    ///     host auditions it through its parent's — same staff, same tick — at the grace's pitch.
    ///   - cents: the microtonal offset to sound with `pitch` — a grace note's own accidental, which the parent's
    ///     `NoteID` cannot reach. Read only with an explicit `pitch`: the note's own pitch sounds with the note's own
    ///     offset (`PreviewRouting.pitchBend(of:in:)`), as the Apple engine bends an audition.
    /// - Returns: `nil` when `noteID` does not resolve in `score`, or its staff has no channel in `prepared`.
    package static func previewRoute(
        score: Score, prepared: Score, noteID: NoteID, pitch: Int?, cents: Double = 0,
    ) -> PreviewRoute? {
        guard let resolved = pitchAndStaff(score: score, noteID: noteID) else { return nil }
        let layout = PlaybackChannelLayout(score: prepared)
        let switches = PreparedPlayback.staffChannelSwitches(score: prepared, plan: layout.liveChannelPlan)
        guard let channel = PreviewRouting.channel(
            forStaff: resolved.staffIndex,
            atTick: PreviewRouting.tick(of: noteID, in: score),
            openingChannels: layout.staffMIDIChannels,
            switches: switches,
        ) else { return nil }
        let isDrum = layout.staffIsDrum[resolved.staffIndex] ?? false
        let bend: Int = if isDrum {
            MidiEvent.pitchBendCenter
        } else if pitch == nil {
            Int(PreviewRouting.pitchBend(of: noteID, in: score))
        } else {
            MidiEvent.pitchBendValue(cents: cents)
        }
        return PreviewRoute(
            pitch: pitch ?? resolved.pitch,
            staffIndex: resolved.staffIndex,
            channel: Int(channel),
            isDrum: isDrum,
            bend: bend,
        )
    }

    /// `previewRoute` as the JNI answers it: `[pitch, staffIndex, channel, isDrum ? 1 : 0, bend]`, or empty for none.
    /// A negative `pitch` sounds the note's own, with the note's own offset; `cents` goes with an explicit one.
    package static func previewRouteWire(
        score: Score, prepared: Score, noteID: NoteID, pitch: Int, cents: Double = 0,
    ) -> [Int64] {
        guard let route = previewRoute(
            score: score, prepared: prepared, noteID: noteID, pitch: pitch < 0 ? nil : pitch, cents: cents,
        ) else { return [] }
        return [
            Int64(route.pitch), Int64(route.staffIndex), Int64(route.channel), route.isDrum ? 1 : 0, Int64(route.bend),
        ]
    }
}
