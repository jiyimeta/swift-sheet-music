import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

// MARK: - T14: MIDI render with channel relabeling

extension AudioMidiBridge {
    /// Rewrites every channel-bearing event's channel field to
    /// `trackIdx & 0x0F` so each MIDI track gets a unique channel
    /// on the Android audio engine.
    static func relabelChannelsToTrackIndex(_ midi: inout MidiFile) {
        for trackIdx in midi.tracks.indices {
            let ch = trackIdx & 0x0F
            for eventIdx in midi.tracks[trackIdx].events.indices {
                let event = midi.tracks[trackIdx].events[eventIdx].event
                let relabeled: MidiEvent
                switch event {
                case let .noteOn(_, pitch, velocity):
                    relabeled = .noteOn(channel: ch, pitch: pitch, velocity: velocity)
                case let .noteOff(_, pitch, velocity):
                    relabeled = .noteOff(channel: ch, pitch: pitch, velocity: velocity)
                case let .controlChange(_, controller, value):
                    relabeled = .controlChange(
                        channel: ch, controller: controller, value: value,
                    )
                case let .programChange(_, program):
                    relabeled = .programChange(channel: ch, program: program)
                case let .pitchBend(_, value):
                    relabeled = .pitchBend(channel: ch, value: value)
                default:
                    relabeled = event
                }
                midi.tracks[trackIdx].events[eventIdx].event = relabeled
            }
        }
    }

    /// Render `score` → SMF bytes, relabeling channels by track index
    /// so each track has a deterministic unique MIDI channel.
    static func renderMidi(score: Score) throws -> Data {
        var midi = try MidiRenderer.render(score: score)
        relabelChannelsToTrackIndex(&midi)
        // Strip the baked-in CC 7 / tick-0 program on each staff's (relabeled) channel so the live
        // FluidSynth mixer is the sole authority on per-staff volume — otherwise the SMF's tick-0
        // CC 7 re-fires on the first play and clobbers a volume the user set before playing. The
        // engine seeds the score's channel volume into the synth at prepare instead. Mirrors the
        // iOS engine (shared `MidiSynthPostProcess`). One track per staff → channel == trackIdx.
        let mixerManagedChannels = Set(midi.tracks.indices.map { $0 & 0x0F })
        MidiSynthPostProcess.apply(midi: &midi, mixerManagedChannels: mixerManagedChannels)
        return try MidiWriter.write(midi)
    }

    /// Render the metronome's OWN sequence — the score's tempo map plus the click track — for the second
    /// FluidSynth player the Android engine runs on its dedicated metronome synth. Both players are advanced
    /// by the same rendered frame counts against the same tempo map, so the clicks stay locked to the score
    /// without the engine having to place them by hand.
    ///
    /// Beats are UNROLLED (repeats + jumps expanded) to match `renderMidi`'s tick space; the click patch is
    /// the one the Apple engine uses (`MetronomeSequenceBuilder`), so a click is note 76/77 at velocity
    /// 100/80 on either platform. Channel relabeling is deliberately NOT applied: this SMF plays alone on the
    /// metronome synth, where channel 9 is the GM percussion channel FluidSynth auto-selects bank 128 for.
    static func renderMetronomeMidi(score: Score) throws -> Data {
        let rendered = try MidiRenderer.render(score: score)
        let sequence = MetronomeSequenceBuilder.metronomeOnlySequence(
            rendered: rendered,
            metronomeBeats: PlaybackTimeline.unrolledMetronomeBeats(score: score),
        )
        return try MidiWriter.write(sequence)
    }

    /// The same sequence with a count-in in front: the pre-roll's clicks fill `[0, preRollTicks)` and the
    /// body's clicks are shifted to sit behind them, so ONE transport plays the count and then the piece.
    ///
    /// This is what puts the count-in on the audio clock. Waiting out the pre-roll on a wall clock and
    /// firing each click by hand quantized it to whichever output buffer picked the note up — audible as
    /// an unsteady count — whereas a click that is an event in the sequence lands where its tick says.
    /// The engine starts the score's own player when this transport reaches `preRollTicks`.
    ///
    /// Returns empty `Data` when the position has no count-in (`CountInBeats` can't schedule one).
    static func renderCountInMetronomeMidi(
        score: Score, cursor: ScoreCursor?, baseTick: Int,
    ) throws -> Data {
        guard let plan = CountInBeats.compute(score: score, startCursor: cursor) else { return Data() }
        let rendered = try MidiRenderer.render(score: score)
        let sequence = MetronomeSequenceBuilder.metronomeOnlySequence(
            rendered: rendered,
            metronomeBeats: PlaybackTimeline.unrolledMetronomeBeats(score: score),
            plan: plan,
            baseTick: baseTick,
            includingPreRollClicks: true,
        )
        return try MidiWriter.write(sequence)
    }
}

// MARK: - swift-java entry points

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeRenderMidi(...)` call site. Returns an
/// empty `Data` when the score handle is unknown or rendering throws.
public func nativeRenderMidi(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard let bytes = try? AudioMidiBridge.renderMidi(score: score) else {
        return Data()
    }
    return bytes
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeRenderMetronomeMidi(...)` call site. Returns an
/// empty `Data` when the score handle is unknown or rendering throws — the
/// engine then simply runs without a metronome player.
public func nativeRenderMetronomeMidi(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard let bytes = try? AudioMidiBridge.renderMetronomeMidi(score: score) else {
        return Data()
    }
    return bytes
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicAudioJNI.nativeRenderCountInMetronomeMidi(...)` call site: the metronome sequence with a
/// count-in in front, for playback starting at `fromCursorBytes` (whose unrolled tick the caller passes as
/// `baseTick`). Empty `Data` when the handle is unknown, the position has no count-in, or rendering throws.
public func nativeRenderCountInMetronomeMidi(
    scoreHandle: Int64, fromCursorBytes: Data, baseTick: Int64,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    let cursor = try? ScoreCursorCodec.decode(fromCursorBytes)
    guard let bytes = try? AudioMidiBridge.renderCountInMetronomeMidi(
        score: score, cursor: cursor, baseTick: Int(baseTick),
    ) else {
        return Data()
    }
    return bytes
}
