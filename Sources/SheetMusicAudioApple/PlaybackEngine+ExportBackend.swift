@preconcurrency import AVFoundation
import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

/// Offline export driven by an injected `SynthBackend` instead of AUMIDISynth.
///
/// The AUMIDISynth pipeline in `PlaybackEngine+Export` predates the backend
/// seam, so for a host that injects one (e.g. `SwiftySynthBackend`) an export
/// used to be rendered by a DIFFERENT synth from the one it had just been
/// listening to — audibly so: AUMIDISynth steals voices on dense scores and
/// sits at its own level. This path renders through a second instance of the
/// live backend, so an export sounds like playback.
///
/// It mirrors `PlaybackEngine.backendPlay` rather than the AU export: the score
/// SMF is loaded un-shifted, the metronome rides the backend's own separate
/// transport (so `metronomeEnabled` is a mute flag, not a track append), and
/// the mixer is re-asserted after the seek — a backend seek resets the synth's
/// channels to GM defaults, and the SMF's tick-0 CC 7 / programChange are
/// stripped for mixer-managed channels precisely so the mixer stays the sole
/// authority.
extension PlaybackEngine {
    /// Build a dedicated `AVAudioEngine` around `backend` (a fresh offline
    /// instance from `SynthBackend.makeOfflineInstance`), loaded and positioned
    /// for an offline render of `score`.
    ///
    /// Suspends while the backend loads its SoundFont — `SynthBackend.prepare`
    /// may do that off the main actor, and every transport command is contracted
    /// to be dropped until `isReady`. The engine is left in manual-rendering
    /// mode and started, so the caller can `start()` and pull frames.
    ///
    /// The instance gets the live recordings and alignment as the snapshot holds them, and with `includesCountIn` the
    /// count-in live playback plays into `startTick` (`backendCountIn`), started as `startBackendCountIn` starts it.
    static func buildBackendExportPipeline(
        score: Score,
        snapshot: ExportEngineSnapshot,
        outputFormat: AVAudioFormat,
        timeline: PlaybackTimeline,
        unrolledTimeMap: UnrolledTimeMap,
        startTick: Int,
        includesCountIn: Bool,
        backend: any SynthBackend,
    ) async throws -> ExportPipeline {
        let engine = AVAudioEngine()
        // Same LIVE single-port collapse the playback engine uses — one strip
        // per (part × distinct instrument) — so the offline render addresses the
        // same channels the mixer snapshot was keyed against.
        let plan = LiveChannelPlan.build(score: score)

        let scoreGainMixer = buildOutputChain(
            engine: engine,
            gain: snapshot.masterGain,
            stage: snapshot.masterOutputStage,
        )
        backend.attach(to: engine)
        // Into `scoreGainMixer`, exactly as the live engine connects it in
        // `prepareSynth`. The backend mixes its own metronome inside its render
        // block, so the click rides the master gain here — as it does on the AU
        // path, whose separate metronome sampler lands on the same node.
        engine.connect(backend.outputNode, to: scoreGainMixer, format: nil)

        backend.prepare(
            soundfontURL: snapshot.resolver.defaultGMSoundfontURL,
            metronomeSoundfontURL: snapshot.metronomeSoundFontURL,
            drumChannels: drumChannels(score: score, plan: plan),
        )
        try await waitUntilReady(backend)

        let rendered = try loadTransports(
            backend: backend, score: score, plan: plan,
            snapshot: snapshot, timeline: timeline,
        )
        loadRecordings(backend: backend, snapshot: snapshot)
        let countIn = includesCountIn
            ? CountInBeats.compute(score: score, startCursor: timeline.frame(atTick: startTick)?.cursor).map {
                backendCountIn(
                    plan: $0, rendered: rendered, metronomeBeats: snapshot.metronomeBeats, baseTick: startTick,
                    timeline: timeline, unrolledTimeMap: unrolledTimeMap,
                )
            }
            : nil

        try engine.enableManualRenderingMode(
            .offline,
            format: outputFormat,
            maximumFrameCount: AudioFileExporter.bufferFrames,
        )
        try engine.start()

        return ExportPipeline(
            engine: engine,
            countInSeconds: countIn?.seconds,
            followsAlignment: backend.canPlayRecordings,
            start: {
                startTransport(
                    backend: backend, snapshot: snapshot, plan: plan, startTick: startTick, countIn: countIn,
                )
            },
            teardown: {
                backend.stop()
                backend.teardown()
                engine.stop()
                engine.disableManualRenderingMode()
            },
        )
    }

    /// Load the score + metronome transports and the state the backend persists
    /// across them (rate, tuning). Rate + tuning go FIRST: both are contracted
    /// to persist across transport operations, and `loadSequence` / `seek`
    /// re-assert whatever the backend has stored — a fresh synth resets them.
    /// Returns the rendered score, whose tempo map a count-in's metronome sequence copies.
    private static func loadTransports(
        backend: any SynthBackend,
        score: Score,
        plan: LiveChannelPlan,
        snapshot: ExportEngineSnapshot,
        timeline: PlaybackTimeline,
    ) throws -> MidiFile {
        backend.setRate(snapshot.rate)
        backend.setTuning(
            cents: snapshot.masterTuningCents,
            transposeSemitones: snapshot.transposeSemitones,
        )
        var rendered = try MidiRenderer.render(score: score)
        MidiChannelRemap.apply(midi: &rendered, plan: plan)
        backend.loadSequence(
            PreRollSequenceAssembler.assembleNormal(
                rendered: rendered,
                // Empty: the metronome is NOT baked into the score SMF on this
                // path — it plays on the backend's own transport, below.
                metronomeBeats: [],
                mixerManagedChannels: plan.managedChannels,
            ),
            timeline: timeline,
        )
        backend.loadMetronomeSequence(
            PreRollSequenceAssembler.metronomeOnly(
                rendered: rendered, metronomeBeats: snapshot.metronomeBeats,
            ),
            offsetSeconds: 0,
        )
        backend.setMetronomeVolume(snapshot.metronomeVolume)
        backend.setMetronomeMuted(!snapshot.metronomeEnabled)
        return rendered
    }

    /// Position the offline transport at `startTick` and start it — through `countIn` first when there is one.
    private static func startTransport(
        backend: any SynthBackend, snapshot: ExportEngineSnapshot, plan: LiveChannelPlan, startTick: Int,
        countIn: BackendCountIn?,
    ) {
        // Seek FIRST, mixer second: the seek resets the synth's channels
        // to GM defaults, so a mixer pushed before it would be silently
        // undone (same ordering as `PlaybackEngine.seek`'s backend branch).
        backend.seek(toTick: startTick)
        if let countIn {
            // After the seek, which moves both transports: the load re-parks the metronome on the count's first
            // click, as `startBackendCountIn` does.
            backend.loadMetronomeSequence(countIn.metronomeSequence, offsetSeconds: countIn.metronomeOffsetSeconds)
        }
        applyMixerSnapshotToBackend(
            backend: backend,
            channels: snapshot.mixerChannels,
            soloing: snapshot.isSoloing,
            plan: plan,
        )
        // The backend holds the score through the count, at the speed of the measure it counts into, and sounds it
        // whatever the metronome strip says (`SynthBackend.play(afterCountInSeconds:)`).
        if let countIn {
            backend.play(afterCountInSeconds: countIn.seconds)
        } else {
            backend.play()
        }
    }

    /// Hand the offline instance the live recordings and alignment, after the rate (`loadTransports`), so the
    /// stretchers a rate away from 100 % needs are made with the tracks. With neither, nothing is sent: an export
    /// without recordings drives the backend exactly as it always did.
    private static func loadRecordings(backend: any SynthBackend, snapshot: ExportEngineSnapshot) {
        if snapshot.alignmentWarp != nil || !snapshot.alignmentSegments.isEmpty {
            backend.setPlaybackAlignment(warp: snapshot.alignmentWarp, segments: snapshot.alignmentSegments)
        }
        if !snapshot.recordings.isEmpty {
            backend.setRecordingTracks(snapshot.recordings)
        }
    }

    /// The live MIDI channels that render as percussion — each drum part's
    /// ordinal-0 strip, matching how `prepareSynth` derives the same set for
    /// live playback.
    private static func drumChannels(score: Score, plan: LiveChannelPlan) -> Set<UInt8> {
        var channels: Set<UInt8> = []
        for entry in score.allStaves
            where score.part(at: entry.address)?.instrument.useDrumset == true
        {
            guard let strip = plan.strip(
                partIndex: entry.address.partIndex, ordinal: 0,
            ) else { continue }
            channels.insert(UInt8(clamping: strip.liveChannel))
        }
        return channels
    }

    /// Push the export snapshot's mixer onto the backend as program + CC 7 per
    /// deduped (part × instrument) strip — the backend counterpart of
    /// `reassertBackendChannelState`, reading the snapshot rather than the live
    /// `mixerChannels` so a mix changed mid-export can't leak into the file.
    ///
    /// Each strip's CC 7 is `exportVolumeCC7(of:soloing:)` — playback's own
    /// audibility rule, shared with the AUMIDISynth export — against the live
    /// solo bus, recordings included (`ExportEngineSnapshot.isSoloing`).
    private static func applyMixerSnapshotToBackend(
        backend: any SynthBackend,
        channels: [MixerChannel],
        soloing: Bool,
        plan: LiveChannelPlan,
    ) {
        var midiChannels: [MixerChannel.Kind: UInt8] = [:]
        for strip in plan.strips {
            midiChannels[
                .instrument(partIndex: strip.partIndex, ordinal: strip.ordinal),
            ] = UInt8(clamping: strip.liveChannel)
        }
        for channel in channels {
            guard case .instrument = channel.id,
                  let midiCh = midiChannels[channel.id]
            else { continue }
            if let program = channel.program, midiCh != 9 {
                backend.setProgram(channel: midiCh, program: program)
            }
            backend.sendVolume(
                channel: midiCh,
                cc7: exportVolumeCC7(of: channel, soloing: soloing),
            )
        }
    }

    /// Suspend until `backend.isReady`, i.e. until an asynchronous SoundFont
    /// load kicked by `prepare` has landed. Polls rather than hooking
    /// `onReadyChanged` so an already-ready (synchronously loading) backend
    /// falls straight through and no continuation can be missed between the
    /// `prepare` call and the handler being installed.
    ///
    /// Throws `.engineSetupFailed` on timeout instead of hanging the export
    /// forever on a backend whose load never completes (an unreadable or
    /// corrupt SoundFont makes `SwiftySynthBackend` ready with a nil synth, so
    /// this is a backstop, not the normal failure path).
    private static func waitUntilReady(
        _ backend: any SynthBackend,
        timeout: Duration = .seconds(180),
    ) async throws {
        guard !backend.isReady else { return }
        let step = Duration.milliseconds(10)
        var waited = Duration.zero
        while !backend.isReady {
            try Task.checkCancellation()
            try await Task.sleep(for: step)
            waited += step
            guard waited < timeout else {
                throw AudioExportError.engineSetupFailed(
                    underlying: "Synth backend did not finish loading its SoundFont",
                )
            }
        }
    }
}
