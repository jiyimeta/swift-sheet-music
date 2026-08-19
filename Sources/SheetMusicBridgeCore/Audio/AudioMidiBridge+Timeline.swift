import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicFoundation
import SheetMusicMIDI

// MARK: - T15: Timeline summary

extension AudioMidiBridge {
    package struct TimelineSummary: Equatable {
        package let totalTicks: Int64
        package let totalSecondsMicros: Int64
        package let division: Int64
        /// Length of the UNROLLED sequence (repeats + jumps expanded) —
        /// the tick space the FluidSynth player actually traverses. The
        /// Kotlin poll loop compares the player's tick against THIS for
        /// end-of-score, otherwise a repeat's second pass would push the
        /// unrolled tick past the (shorter) notated `totalTicks` and stop
        /// playback early. Mirrors the Apple engine's
        /// `max(unroll.totalUnrolledTicks, timeline.totalTicks)`.
        package let totalUnrolledTicks: Int64
    }

    package static func timelineSummary(score: Score) -> TimelineSummary {
        let t = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        return TimelineSummary(
            totalTicks: Int64(t.totalTicks),
            totalSecondsMicros: Int64((t.totalSeconds * 1_000_000).rounded()),
            division: Int64(t.division),
            totalUnrolledTicks: Int64(max(unroll.totalUnrolledTicks, t.totalTicks)),
        )
    }
}

// MARK: - T17: Metronome beats + staff params

extension AudioMidiBridge {
    /// UNROLLED (not notated) — the Kotlin poll loop feeds the FluidSynth
    /// player's UNROLLED tick (repeats + jumps expanded) to
    /// `MetronomeMixer.updateCurrentTick`. A beat list built from notated
    /// ticks alone would end at the notated length and go silent on a
    /// repeat's 2nd pass, even though the score keeps playing. Mirrors
    /// the Apple engine's `PlaybackTimeline.unrolledMetronomeBeats`
    /// wiring in `PlaybackEngine.prepare(score:)`.
    package static func metronomeBeats(score: Score) -> Data {
        let beats = PlaybackTimeline.unrolledMetronomeBeats(score: score)
        return MetronomeBeatCodec.encodeArray(beats)
    }

    package static func staffParams(score: Score) -> Data {
        let entries = score.allStaves.enumerated().map { idx, entry -> StaffParams in
            let address = entry.address
            let part = score.part(at: address)
            let channel = part?.instrument.channels.first ?? InstrumentChannel()
            return StaffParams(
                staffIndex: idx,
                bankLSB: UInt8(clamping: channel.bank),
                program: UInt8(clamping: channel.program),
                isDrums: part?.instrument.useDrumset == true,
                partAddressHash: Int64(address.partIndex) * 1000
                    + Int64(address.staffIndexInPart),
                partIndex: address.partIndex,
                staffIndexInPart: address.staffIndexInPart,
                displayName: score.staffDisplayName(at: address),
                trackName: part?.trackName ?? "",
                instrumentLongName: part?.instrument.longName ?? "",
                channelVolume: UInt8(clamping: channel.volume),
                defaultClefType: entry.staff.defaultClefType ?? "",
                groupRawValue: entry.staff.group,
            )
        }
        return StaffParamsCodec.encodeArray(entries)
    }

    /// One entry per deduped (part × instrument) mixer strip — the
    /// Android mirror of `PlaybackEngine.rebuildMixerChannels`.
    ///
    /// Naming comes from `LiveChannelPlan.labels(for:in:)`, the same call
    /// the Apple engine makes when it fills `MixerChannel`. It used to be
    /// a second copy of that rule here, under a comment promising the two
    /// matched; sharing the function is what actually holds them together.
    package static func instrumentParams(score: Score) -> Data {
        let plan = LiveChannelPlan.build(score: score)
        let entries = plan.strips.map { strip -> InstrumentParams in
            let name = plan.labels(for: strip, in: score).displayName
            return InstrumentParams(
                partIndex: strip.partIndex,
                ordinal: strip.ordinal,
                liveChannel: strip.liveChannel,
                bankLSB: UInt8(clamping: strip.instrument.channel.bank),
                program: UInt8(clamping: strip.instrument.channel.program),
                isDrums: strip.instrument.useDrumset,
                displayName: name,
                channelVolume: UInt8(clamping: strip.instrument.channel.volume),
            )
        }
        return InstrumentParamsCodec.encodeArray(entries)
    }
}

// MARK: - T16: Frame lookup

extension AudioMidiBridge {
    package static func frameAtTick(score: Score, tick: Int64) -> Data {
        // A tick before the sequence start is out of range → no frame.
        // Guard BEFORE the unroll map, whose `notatedTick(fromUnrolled:)`
        // clamps negatives to 0 (a valid frame); without this a negative
        // tick would wrongly resolve to the first frame.
        guard tick >= 0 else { return Data() }
        let timeline = PlaybackTimeline(score: score)
        // `tick` arrives from the FluidSynth player in UNROLLED SMF
        // coordinates (repeats + jumps expanded), but `timeline` frames
        // are NOTATED. Translate before the lookup so the cursor follows
        // a repeat's second pass and every jump instead of clamping
        // forward. Mirrors the Apple engine's read-path translation
        // (`PlaybackEngine.mappedCursor`).
        let unroll = MidiRenderer.playbackUnroll(score: score)
        let notated = unroll.notatedTick(fromUnrolled: Int(tick))
        guard let frame = timeline.frame(atTick: notated) else { return Data() }
        return FrameCodec.encode(frame)
    }

    /// Continuous seconds at a possibly fractional UNROLLED player tick.
    ///
    /// The counterpart of `frameAtTick`, which snaps to a frame onset and so
    /// quantizes to note / beat granularity. A host animating a playhead needs
    /// the value BETWEEN onsets, and interpolating between two polled frame
    /// times cannot supply it: those times are themselves quantized, so the
    /// result steps at note granularity no matter how often it is sampled.
    ///
    /// Takes the same unrolled coordinates the FluidSynth player reports, and
    /// translates the whole part through the unroll map before carrying the
    /// fraction across. Within one pass of a repeat that map is a constant
    /// offset, so adding the remainder back is exact; the only inexact instant
    /// is a jump landing strictly inside a tick, which no player reports.
    package static func secondsAtTick(score: Score, unrolledTick: Double) -> Double {
        guard unrolledTick >= 0, unrolledTick.isFinite else { return 0 }
        let timeline = PlaybackTimeline(score: score)
        let unroll = MidiRenderer.playbackUnroll(score: score)
        let whole = unrolledTick.rounded(.down)
        let notated = Double(unroll.notatedTick(fromUnrolled: Int(whole)))
            + (unrolledTick - whole)
        return timeline.seconds(atTick: notated)
    }

    package static func frameForCursor(score: Score, cursor: ScoreCursor) -> Data {
        let timeline = PlaybackTimeline(score: score)
        guard let frame = timeline.frame(forCursor: cursor) else { return Data() }
        return FrameCodec.encode(frame)
    }

    /// The UNROLLED transport tick a NOTATED score tick sits at — the WRITE
    /// direction, and the inverse of the translation `frameAtTick` performs on
    /// the read side.
    ///
    /// Everything the Kotlin engine hands the FluidSynth player (`seekTick`)
    /// or reads back from it (`currentTick`) is unrolled, while every tick it
    /// gets out of `frameForCursor` / `itemEndTick` / `totalTicks` is notated.
    /// One of the two has to be projected before they meet, and this is that
    /// projection. `PlaybackUnroll.firstUnrolledTick(forNotated:)` is the same
    /// rule the Apple engine schedules by, so the two platforms cannot drift.
    package static func unrolledTickForNotated(score: Score, notatedTick: Int64) -> Int64 {
        let unroll = MidiRenderer.playbackUnroll(score: score)
        return Int64(unroll.firstUnrolledTick(forNotated: Int(notatedTick)))
    }
}
