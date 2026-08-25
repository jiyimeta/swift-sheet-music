import JavaScriptKit
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation

// The sequences a browser host's synth plays, and the numbers a transport UI
// needs before the first frame is drawn. The cursor, seek and loop surface is
// in `PlaybackEntry+Cursor.swift`.
//
// Unlike Android — where the Kotlin host polls the FluidSynth player's UNROLLED
// TICK and hands it back through three separate translations — a Web Audio
// sequencer reports SECONDS, and `PlaybackClock` projects those straight onto
// the notated timeline. Nothing on this surface speaks ticks, which also keeps
// it clear of wasm32's 32-bit `Int`.

// MARK: - Sequences

/// The Standard MIDI File the host's synth plays: the live single-port channel
/// plan applied, and the baked-in CC 7 / tick-0 program stripped off every
/// mixer-owned channel so a live mixer is the sole authority.
///
/// Android: `nativeRenderMidi`. Empty for an unknown handle or a render failure.
@JS public func renderMidi(handle: Int) -> JSUint8Array {
    guard let score = scoreTable.value(for: Int64(handle)),
          let bytes = try? AudioMidiBridge.renderMidi(score: score)
    else { return JSUint8Array(length: 0) }
    return bytes.bridgedUint8Array
}

/// The metronome's own sequence — the score's tempo map plus the click track —
/// for the second sequencer the web engine runs alongside the score's.
///
/// Two sequencers rather than one merged SMF because that is what makes muting
/// the metronome a flag flip: reloading a merged sequence would cut every voice
/// sounding on the score side. Both advance against the same tempo map, so they
/// stay locked without the host placing clicks by hand.
///
/// Android: `nativeRenderMetronomeMidi`. Empty for an unknown handle or a
/// render failure — the host then simply runs without a metronome.
@JS public func renderMetronomeMidi(handle: Int) -> JSUint8Array {
    guard let score = scoreTable.value(for: Int64(handle)),
          let bytes = try? AudioMidiBridge.renderMetronomeMidi(score: score)
    else { return JSUint8Array(length: 0) }
    return bytes.bridgedUint8Array
}

/// The metronome sequence with a count-in in front of it: the pre-roll's clicks
/// fill `[0, countInSeconds)` and the body's clicks sit behind them, so ONE
/// sequencer plays the count and then the piece.
///
/// That is what puts the count on the audio clock. Waiting the pre-roll out on a
/// wall clock and firing each click by hand quantizes it to whichever output
/// buffer noticed the deadline — audible as an unsteady count — whereas a click
/// that is an event in the sequence lands where its tick says.
///
/// Android: `nativeRenderCountInMetronomeMidi`, which takes an encoded
/// `ScoreCursor` plus its unrolled base tick. The wasm surface takes a position
/// on the player's clock and resolves both internally, so no cursor wire format
/// has to exist in JavaScript.
///
/// Seconds rather than a measure index because a count-in is not restricted to a
/// downbeat: `CountInBeats` schedules a partial lead-in for a start partway
/// through a bar, which is the case a tap-to-start produces. Pass
/// `playerSecondsForMeasure(...)` for the downbeat case.
///
/// Empty when the handle is unknown, the position is outside the score, or it
/// has no count-in.
@JS public func renderCountInMetronomeMidi(handle: Int, fromPlayerSeconds: Double) -> JSUint8Array {
    guard let score = scoreTable.value(for: Int64(handle)) else { return JSUint8Array(length: 0) }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    guard let frame = clock.frame(atPlayerSeconds: fromPlayerSeconds) else { return JSUint8Array(length: 0) }
    let baseTick = clock.unrolledTick(fromNotatedTick: frame.tick)
    guard let bytes = try? AudioMidiBridge.renderCountInMetronomeMidi(
        score: score, cursor: frame.cursor, baseTick: baseTick,
    ) else { return JSUint8Array(length: 0) }
    return bytes.bridgedUint8Array
}

/// How long the count-in for `fromPlayerSeconds` lasts, in seconds. The host
/// starts the metronome transport, watches its position, and starts the score
/// transport on the frame this elapses.
///
/// `0` when the handle is unknown, the position is outside the score, or it has
/// no count-in — all of which the host reads as "start now".
///
/// Android: `nativeCountIn`, which returns the whole click schedule as a
/// `CountInWire` payload because its `MetronomeMixer` places clicks itself. The
/// web host does not: the clicks are events in the sequence
/// `renderCountInMetronomeMidi` returns, so only the total is needed.
@JS public func countInSeconds(handle: Int, fromPlayerSeconds: Double) -> Double {
    guard let score = scoreTable.value(for: Int64(handle)) else { return 0 }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    guard let cursor = clock.cursor(atPlayerSeconds: fromPlayerSeconds),
          let result = CountInBeats.compute(score: score, startCursor: cursor),
          score.division > 0, result.quarterBpm > 0
    else { return 0 }
    // `division` is ticks per quarter, so `tick / division` is quarter notes and
    // `× 60 / quarterBpm` turns that into seconds — the same projection
    // `CountInCodec.wire(from:division:)` makes for the Android host.
    let secondsPerTick = 60.0 / (result.quarterBpm * Double(score.division))
    return Double(result.preRollTicks) * secondsPerTick
}

/// Build a bank-128 SoundFont from two click WAVs, mapping the strong click to
/// note 76 and the weak one to note 77 — the notes `renderMetronomeMidi`'s
/// sequence plays.
///
/// Load it into the metronome's synth alongside (and ahead of) the score's GM
/// bank to replace the General MIDI wood blocks with the host's own clicks.
/// Without it the metronome still sounds, using whatever the GM bank has at
/// those notes.
///
/// Empty when either WAV fails to parse, which a host reads as "keep the GM
/// clicks". Accepts what `WavPcmReader` accepts: uncompressed PCM.
///
/// Android: `nativeBuildClickSoundFont`.
@JS public func buildClickSoundFont(strongWav: JSUint8Array, weakWav: JSUint8Array) -> JSUint8Array {
    guard let strong = try? WavPcmReader.read(strongWav.bridgedData),
          let weak = try? WavPcmReader.read(weakWav.bridgedData)
    else { return JSUint8Array(length: 0) }
    return ClickSoundFontBuilder.build(
        strong: strong.samples, strongRate: strong.sampleRate,
        weak: weak.samples, weakRate: weak.sampleRate,
    ).bridgedUint8Array
}

// MARK: - Timeline

/// What a transport UI needs before the first frame is drawn.
///
/// Android reads the same numbers out of `nativeTimelineSummary`, which answers
/// `[totalTicks, totalSecondsMicros, division, totalUnrolledTicks]` because its
/// player speaks ticks. The web host's clock is seconds and its sequencer knows
/// for itself when the sequence has run out, so the tick fields have no
/// counterpart here.
@JS public struct PlaybackSummary {
    /// The score's own length.
    public var totalNotatedSeconds: Double
    /// The length of the sequence the synth actually plays — longer than
    /// `totalNotatedSeconds` on any score with repeats.
    public var totalPlayerSeconds: Double
    public var measureCount: Int
    /// Ticks per quarter note.
    public var division: Int
    /// The tempo governing the start, in quarter-note BPM. MuseScore's 120
    /// default when the score sets none.
    public var openingQuarterBpm: Double

    /// Spelled out rather than left to the memberwise default, which would be
    /// `internal`: BridgeJS generates a `@_transparent` lowering function that
    /// cannot reference an internal declaration.
    public init(
        totalNotatedSeconds: Double,
        totalPlayerSeconds: Double,
        measureCount: Int,
        division: Int,
        openingQuarterBpm: Double,
    ) {
        self.totalNotatedSeconds = totalNotatedSeconds
        self.totalPlayerSeconds = totalPlayerSeconds
        self.measureCount = measureCount
        self.division = division
        self.openingQuarterBpm = openingQuarterBpm
    }
}

/// Android: `nativeTimelineSummary` + `nativeOpeningQuarterBpm`.
/// `nil` for an unknown handle.
@JS public func playbackSummary(handle: Int) -> PlaybackSummary? {
    guard let score = scoreTable.value(for: Int64(handle)) else { return nil }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    return PlaybackSummary(
        totalNotatedSeconds: clock.totalNotatedSeconds,
        totalPlayerSeconds: clock.totalPlayerSeconds,
        measureCount: clock.measureCount,
        division: clock.division,
        // The same accessor `scoreMetadata` reads.
        openingQuarterBpm: score.openingQuarterBpm,
    )
}

/// Click positions for a visual beat indicator, as `[playerSeconds, isDownbeat]`
/// repeated — two `Double`s per beat, the flag being `1` or `0`.
///
/// The clicks themselves are events in `renderMetronomeMidi`'s sequence, so a
/// host that only wants to HEAR the metronome never calls this. Android's
/// `nativeMetronomeBeats` is load-bearing instead, because its `MetronomeMixer`
/// places clicks by hand.
///
/// UNROLLED, like the sequence: a beat list built from notated ticks alone would
/// run out at the notated length and go quiet on a repeat's second pass.
/// Empty for an unknown handle.
@JS public func metronomeBeats(handle: Int) -> [Double] {
    guard let score = scoreTable.value(for: Int64(handle)) else { return [] }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    let beats = PlaybackTimeline.unrolledMetronomeBeats(score: score)
    var out: [Double] = []
    out.reserveCapacity(beats.count * 2)
    for beat in beats {
        out.append(clock.playerSecondsForUnrolledTick(beat.tick))
        out.append(beat.isDownbeat ? 1 : 0)
    }
    return out
}
