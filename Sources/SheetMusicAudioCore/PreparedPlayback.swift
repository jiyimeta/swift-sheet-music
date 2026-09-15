import SheetMusicCore
import SheetMusicFoundation
import SheetMusicMIDI

/// Score-derived playback data that can be built away from the main actor and
/// installed into a `PlaybackEngine` immediately before playback.
public struct PreparedPlayback: Sendable {
    public let score: Score

    package let timeline: PlaybackTimeline
    package let unroll: PlaybackUnroll
    package let unrolledTimeMap: UnrolledTimeMap
    package let metronomeBeats: [MetronomeBeat]
    package let channelLayout: PlaybackChannelLayout
    package let staffChannelSwitches: [Int: [StaffChannelSwitch]]
    package let renderedMidi: MidiFile

    package var derivation: PlaybackScoreDerivation {
        PlaybackScoreDerivation(
            timeline: timeline,
            unroll: unroll,
            unrolledTimeMap: unrolledTimeMap,
            metronomeBeats: metronomeBeats,
            channelLayout: channelLayout,
            staffChannelSwitches: staffChannelSwitches,
        )
    }

    /// Derives all playback data from `score`, including its rendered SMF.
    ///
    /// `previous` is reserved for future range-limited regeneration. The
    /// current implementation deliberately rebuilds the complete value.
    /// Throws `CancellationError` when the current task is cancelled.
    public static func make(
        score: Score,
        previous _: PreparedPlayback? = nil,
    ) throws -> PreparedPlayback {
        try Task.checkCancellation()
        let derivation = derive(score: score)
        try Task.checkCancellation()
        return try PreparedPlayback(
            score: score,
            timeline: derivation.timeline,
            unroll: derivation.unroll,
            unrolledTimeMap: derivation.unrolledTimeMap,
            metronomeBeats: derivation.metronomeBeats,
            channelLayout: derivation.channelLayout,
            staffChannelSwitches: derivation.staffChannelSwitches,
            renderedMidi: render(score: score, channelLayout: derivation.channelLayout),
        )
    }

    package static func derive(score: Score) -> PlaybackScoreDerivation {
        let timeline = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        let channelLayout = PlaybackChannelLayout(score: score)
        return PlaybackScoreDerivation(
            timeline: timeline,
            unroll: unroll,
            unrolledTimeMap: UnrolledTimeMap(unroll: unroll, timeline: timeline),
            metronomeBeats: PlaybackTimeline.unrolledMetronomeBeats(
                score: score,
                unroll: unroll,
            ),
            channelLayout: channelLayout,
            staffChannelSwitches: Self.staffChannelSwitches(
                score: score,
                plan: channelLayout.liveChannelPlan,
            ),
        )
    }

    package static func render(
        score: Score,
        channelLayout: PlaybackChannelLayout,
    ) throws -> MidiFile {
        var midi = try MidiRenderer.renderForPlayback(score: score)
        MidiChannelRemap.apply(midi: &midi, plan: channelLayout.liveChannelPlan)
        return midi
    }

    private static func staffChannelSwitches(
        score: Score,
        plan: LiveChannelPlan,
    ) -> [Int: [StaffChannelSwitch]] {
        // Plain duration sums intentionally exclude the breath-pause budget
        // used by MIDI rendering. This table chooses a preview channel at a
        // UI cursor; playback routing remains the renderer's responsibility.
        var bases: [Int] = []
        var accumulatedTicks = 0
        for duration in score.effectiveMeasureDurations() {
            bases.append(accumulatedTicks)
            accumulatedTicks += duration.ticks(division: score.division)
        }

        var switches: [Int: [StaffChannelSwitch]] = [:]
        for (staffIndex, entry) in score.allStaves.enumerated() {
            let partIndex = entry.address.partIndex
            let timeline = score.instrumentTimeline(forPart: partIndex)
            guard timeline.count > 1 else { continue }
            switches[staffIndex] = timeline.enumerated().compactMap { timelineIndex, point in
                guard bases.indices.contains(point.measureIndex),
                      let ordinal = plan.dedupedOrdinal(
                          partIndex: partIndex,
                          timelineIndex: timelineIndex,
                      ),
                      let strip = plan.strip(partIndex: partIndex, ordinal: ordinal)
                else { return nil }
                return StaffChannelSwitch(
                    tick: bases[point.measureIndex]
                        + point.position.ticks(division: score.division),
                    channel: UInt8(clamping: strip.liveChannel),
                )
            }.sorted { $0.tick < $1.tick }
        }
        return switches
    }
}

package struct PlaybackScoreDerivation: Sendable {
    package let timeline: PlaybackTimeline
    package let unroll: PlaybackUnroll
    package let unrolledTimeMap: UnrolledTimeMap
    package let metronomeBeats: [MetronomeBeat]
    package let channelLayout: PlaybackChannelLayout
    package let staffChannelSwitches: [Int: [StaffChannelSwitch]]
}

package struct StaffChannelSwitch: Sendable, Equatable {
    package let tick: Int
    package let channel: UInt8
}

package struct PlaybackChannelLayout: Sendable, Equatable {
    package let liveChannelPlan: LiveChannelPlan
    package let staffMIDIChannels: [Int: UInt8]
    package let staffIsDrum: [Int: Bool]
    package let instrumentMIDIChannels: [MixerChannel.Kind: UInt8]
    package let mixerChannels: [MixerChannel]
    package let drumChannels: Set<UInt8>

    package init(score: Score) {
        let plan = LiveChannelPlan.build(score: score)
        liveChannelPlan = plan
        instrumentMIDIChannels = Dictionary(
            uniqueKeysWithValues: plan.strips.map { strip in
                (
                    MixerChannel.Kind.instrument(
                        partIndex: strip.partIndex,
                        ordinal: strip.ordinal,
                    ),
                    UInt8(clamping: strip.liveChannel),
                )
            },
        )

        var staffChannels: [Int: UInt8] = [:]
        var drumFlags: [Int: Bool] = [:]
        var backendDrumChannels: Set<UInt8> = []
        for (index, entry) in score.allStaves.enumerated() {
            let channel = UInt8(clamping: plan.strip(
                partIndex: entry.address.partIndex,
                ordinal: 0,
            )?.liveChannel ?? 0)
            let isDrum = score.part(at: entry.address)?.instrument.useDrumset == true
            staffChannels[index] = channel
            drumFlags[index] = isDrum
            if isDrum { backendDrumChannels.insert(channel) }
        }
        staffMIDIChannels = staffChannels
        staffIsDrum = drumFlags
        drumChannels = backendDrumChannels

        var defaults = plan.strips.map { strip in
            let labels = plan.labels(for: strip, in: score)
            return MixerChannel(
                id: .instrument(partIndex: strip.partIndex, ordinal: strip.ordinal),
                name: labels.displayName,
                partName: labels.partName,
                instrumentName: labels.instrumentName,
                volume: Float(max(0, min(127, strip.instrument.channel.volume))) / 127,
                program: UInt8(clamping: strip.instrument.channel.program),
                isDrums: strip.instrument.useDrumset,
            )
        }
        defaults.append(MixerChannel(id: .metronome, name: "Metronome"))
        mixerChannels = defaults
    }
}
