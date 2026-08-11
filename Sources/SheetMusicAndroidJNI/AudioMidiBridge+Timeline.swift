import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicMIDI

// MARK: - T15: Timeline summary

extension AudioMidiBridge {
    struct TimelineSummary: Equatable {
        let totalTicks: Int64
        let totalSecondsMicros: Int64
        let division: Int64
        /// Length of the UNROLLED sequence (repeats + jumps expanded) —
        /// the tick space the FluidSynth player actually traverses. The
        /// Kotlin poll loop compares the player's tick against THIS for
        /// end-of-score, otherwise a repeat's second pass would push the
        /// unrolled tick past the (shorter) notated `totalTicks` and stop
        /// playback early. Mirrors the Apple engine's
        /// `max(unroll.totalUnrolledTicks, timeline.totalTicks)`.
        let totalUnrolledTicks: Int64
    }

    static func timelineSummary(score: Score) -> TimelineSummary {
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
    static func metronomeBeats(score: Score) -> Data {
        let beats = PlaybackTimeline.unrolledMetronomeBeats(score: score)
        return MetronomeBeatCodec.encodeArray(beats)
    }

    static func staffParams(score: Score) -> Data {
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
            )
        }
        return StaffParamsCodec.encodeArray(entries)
    }

    /// One entry per deduped (part × instrument) mixer strip — the
    /// Android mirror of `PlaybackEngine.rebuildMixerChannels`.
    ///
    /// Naming mirrors `PlaybackEngine+Mixer.stripName` exactly: gate the
    /// parenthesised suffix on the DEDUPED strip count for the part
    /// (`plan.strips`, filtered to `strip.partIndex`), not the raw
    /// `instrumentTimeline(forPart:).count` — a part whose two timeline
    /// entries dedup onto ONE live channel must show no suffix even
    /// though its timeline has two entries. Also suppress the suffix
    /// when the instrument name equals the part label — the primary
    /// strip's own instrument name always equals `partName` by
    /// construction, which would otherwise render "Piano (Piano)" for
    /// `instrument-change.mscx`.
    static func instrumentParams(score: Score) -> Data {
        let plan = LiveChannelPlan.build(score: score)
        let entries = plan.strips.map { strip -> InstrumentParams in
            let address = StaffAddress(
                partIndex: strip.partIndex, staffIndexInPart: 0,
            )
            let partName = score.staffDisplayName(at: address)
            let instrumentName = strip.instrument.longName
                ?? strip.instrument.trackName ?? strip.instrument.id
            let distinctStripsForPart = plan.strips
                .count { $0.partIndex == strip.partIndex }
            let showsSuffix = distinctStripsForPart > 1
                && !instrumentName.isEmpty
                && instrumentName != partName
            let name = showsSuffix
                ? "\(partName) (\(instrumentName))"
                : partName
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
    static func frameAtTick(score: Score, tick: Int64) -> Data {
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

    static func frameForCursor(score: Score, cursor: ScoreCursor) -> Data {
        let timeline = PlaybackTimeline(score: score)
        guard let frame = timeline.frame(forCursor: cursor) else { return Data() }
        return FrameCodec.encode(frame)
    }
}

// MARK: - swift-java entry points

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeGMInstrumentList()` call site.
public func nativeGMInstrumentList() -> Data {
    GMInstrumentCodec.encodeAll()
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeBuildClickSoundFont(...)` call site. Reuses
/// the Phase 1 Core (`WavPcmReader` + `ClickSoundFontBuilder`) to turn two
/// click WAVs into a bank-128 SF2 mapping strong→note 76 / weak→note 77.
/// Returns empty `Data` on any read failure so the Kotlin caller can fall
/// back to the GM drum-kit.
public func nativeBuildClickSoundFont(strongWav: Data, weakWav: Data) -> Data {
    guard let strong = try? WavPcmReader.read(strongWav),
          let weak = try? WavPcmReader.read(weakWav)
    else { return Data() }
    return ClickSoundFontBuilder.build(
        strong: strong.samples, strongRate: strong.sampleRate,
        weak: weak.samples, weakRate: weak.sampleRate,
    )
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeItemEndTick(...)` call site. Returns -1 when
/// the score handle is unknown, the id payload is empty / undecodable, or
/// the timeline has no end-tick entry for the id (only `.note` / `.rest`
/// items are tracked).
public func nativeItemEndTick(scoreHandle: Int64, idBytes: Data) -> Int64 {
    guard let score = scoreTable.value(for: scoreHandle) else { return -1 }
    guard !idBytes.isEmpty,
          let id = try? ScoreItemIDCodec.decode(idBytes)
    else { return -1 }
    return AudioMidiBridge.itemEndTick(score: score, id: id)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeTimelineSummary(...)` call site. Returns
/// `[totalTicks, totalSecondsMicros, division, totalUnrolledTicks]`, or an
/// empty array when the score handle is unknown. The trailing
/// `totalUnrolledTicks` is appended (existing indices unchanged) so the
/// Kotlin poll loop can detect end-of-score against the unrolled length.
public func nativeTimelineSummary(scoreHandle: Int64) -> [Int64] {
    guard let score = scoreTable.value(for: scoreHandle) else { return [] }
    let summary = AudioMidiBridge.timelineSummary(score: score)
    return [
        summary.totalTicks, summary.totalSecondsMicros,
        summary.division, summary.totalUnrolledTicks,
    ]
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeFrameAtTick(...)` call site. Returns an empty
/// `Data` when the score handle is unknown or the tick has no frame.
public func nativeFrameAtTick(scoreHandle: Int64, tick: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.frameAtTick(score: score, tick: tick)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeFrameForCursor(...)` call site. Returns an
/// empty `Data` when the score handle is unknown, the cursor payload is
/// empty / undecodable, or the timeline has no frame for the cursor.
public func nativeFrameForCursor(scoreHandle: Int64, cursorBytes: Data) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard !cursorBytes.isEmpty,
          let cursor = try? ScoreCursorCodec.decode(cursorBytes)
    else { return Data() }
    return AudioMidiBridge.frameForCursor(score: score, cursor: cursor)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeMetronomeBeats(...)` call site.
public func nativeMetronomeBeats(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.metronomeBeats(score: score)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeStaffParams(...)` call site.
public func nativeStaffParams(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.staffParams(score: score)
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeInstrumentParams(...)` call site.
public func nativeInstrumentParams(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return AudioMidiBridge.instrumentParams(score: score)
}
