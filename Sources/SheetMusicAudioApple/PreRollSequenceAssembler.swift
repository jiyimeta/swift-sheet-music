import Foundation
import SheetMusicAudioCore
import SheetMusicMIDI

/// Pure builder for the playback `MidiFile` handed to `AVAudioSequencer`. It is the single seam where the
/// rendered score, the body metronome, and (for a count-in) the pre-roll click track are woven together, so
/// the engine's `buildSequencer` / `buildCountInSequencer` stay thin and this assembly is unit-testable with
/// no audio engine (see `PlaybackEnginePreRollTests`).
///
/// Two modes:
///
///   * `assembleNormal` — the pre-count-in build: render + append the body metronome + post-process. Kept
///     byte-identical to what the engine assembled before the count-in feature existed.
///   * `assemble` — the count-in build: every score track is shifted past a metronome pre-roll region, a
///     governing tempo is seeded at sequencer tick 0, the body metronome is shifted to match, and a separate
///     always-on pre-roll click track is appended so the count-in sounds even when the metronome toggle is off.
enum PreRollSequenceAssembler {
    /// The count-in build's product: the assembled `MidiFile` plus the two metronome track indices the engine
    /// needs to route. `bodyMetronomeTrackIndex` is always the last track (so `MetronomeController.attach(to:)`,
    /// which grabs `sequencer.tracks.last`, routes the toggle-gated body metronome); `preRollTrackIndex` is the
    /// always-on click track the engine hands to `attachPreRoll`.
    struct Assembled: Equatable {
        var midi: MidiFile
        var preRollTrackIndex: Int
        var bodyMetronomeTrackIndex: Int
    }

    /// Non-count-in playback sequence: the rendered score with the body metronome appended and the shared
    /// playback post-process applied. Must stay byte-identical to the pre-count-in engine's build.
    static func assembleNormal(
        rendered: MidiFile,
        metronomeBeats: [MetronomeBeat],
        mixerManagedChannels: Set<Int>,
    ) -> MidiFile {
        var midi = rendered
        midi.tracks.append(
            MetronomeController.makeMetronomeTrack(beats: metronomeBeats, division: midi.division),
        )
        MidiSynthPostProcess.apply(midi: &midi, mixerManagedChannels: mixerManagedChannels)
        return midi
    }

    /// Count-in playback sequence. Every score track is shifted so content that was at score tick `baseTick`
    /// lands at sequencer tick `plan.preRollTicks`; anything earlier than `baseTick` is dropped. A governing
    /// tempo meta is seeded at sequencer tick 0 (so the pre-roll plays at the start position's tempo), the body
    /// metronome is shifted the same way, and `plan.beats` become an always-on pre-roll click track that fills
    /// the `[0, preRollTicks)` region. The shared playback post-process is applied last.
    static func assemble(
        rendered: MidiFile,
        metronomeBeats: [MetronomeBeat],
        mixerManagedChannels: Set<Int>,
        plan: CountInBeats.Result,
        baseTick: Int,
    ) -> Assembled {
        // Content that was at score tick `baseTick` moves to sequencer tick `preRollTicks`; from-start plays
        // (baseTick 0) shift by the whole pre-roll, mid-score plays keep their tail in place when the pre-roll
        // exactly replaces the dropped head.
        let shift = plan.preRollTicks - baseTick

        var midi = rendered
        midi.tracks = midi.tracks.map { shiftTrack($0, dropBelow: baseTick, by: shift) }

        // Seed the governing tempo at sequencer tick 0 on the first (conductor) track so the pre-roll — which
        // lives before any shifted score event — plays at the start position's tempo. 120 BPM → 500_000 µs/quarter.
        let tempoEvent = TimedMidiEvent(
            tick: 0,
            event: .meta(.tempo(microsecondsPerQuarter: 60_000_000 / Int(plan.quarterBpm.rounded()))),
        )
        if midi.tracks.isEmpty {
            midi.tracks.append(MidiTrack(events: [tempoEvent]))
        } else {
            midi.tracks[0].events.insert(tempoEvent, at: 0)
        }

        // Body metronome: the score's beats from `baseTick` onward, shifted to match the score content.
        let bodyBeats = metronomeBeats
            .filter { $0.tick >= baseTick }
            .map { MetronomeBeat(tick: $0.tick + shift, isDownbeat: $0.isDownbeat) }

        // Pre-roll click track sits in `[0, preRollTicks)` at `plan.beats`' own (unshifted) ticks.
        let preRollTrack = MetronomeController.makeMetronomeTrack(beats: plan.beats, division: midi.division)
        let preRollTrackIndex = midi.tracks.count
        midi.tracks.append(preRollTrack)

        // Body metronome is appended last so `MetronomeController.attach(to:)` (which routes `tracks.last`)
        // picks it up as the toggle-gated metronome.
        let bodyTrack = MetronomeController.makeMetronomeTrack(beats: bodyBeats, division: midi.division)
        let bodyMetronomeTrackIndex = midi.tracks.count
        midi.tracks.append(bodyTrack)

        MidiSynthPostProcess.apply(midi: &midi, mixerManagedChannels: mixerManagedChannels)
        return Assembled(
            midi: midi,
            preRollTrackIndex: preRollTrackIndex,
            bodyMetronomeTrackIndex: bodyMetronomeTrackIndex,
        )
    }

    /// A metronome-ONLY sequence for the SwiftySynth backend, which plays the metronome on a separate synth so
    /// it can be muted live without touching the score transport. Shared with the Android engine, which drives
    /// its metronome from the same kind of sequence on a second FluidSynth player — the shape, the count-in
    /// shift, and the tempo-map copy all live in `MetronomeSequenceBuilder.metronomeOnlySequence`.
    static func metronomeOnly(
        rendered: MidiFile,
        metronomeBeats: [MetronomeBeat],
        plan: CountInBeats.Result? = nil,
        baseTick: Int = 0,
    ) -> MidiFile {
        MetronomeSequenceBuilder.metronomeOnlySequence(
            rendered: rendered,
            metronomeBeats: metronomeBeats,
            plan: plan,
            baseTick: baseTick,
        )
    }

    /// Drop every event before `dropBelow`, then advance the rest by `by` ticks. Event payloads are untouched —
    /// only their absolute ticks move — so a note whose on/off straddle `dropBelow` would be split; the caller's
    /// `baseTick` is a measure/beat boundary, so in practice both ends of a note fall on one side.
    private static func shiftTrack(_ track: MidiTrack, dropBelow: Int, by shift: Int) -> MidiTrack {
        var out: [TimedMidiEvent] = []
        out.reserveCapacity(track.events.count)
        for event in track.events where event.tick >= dropBelow {
            out.append(TimedMidiEvent(tick: event.tick + shift, event: event.event))
        }
        return MidiTrack(events: out)
    }
}
