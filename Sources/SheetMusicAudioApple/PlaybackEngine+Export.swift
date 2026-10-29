// swiftlint:disable file_length
@preconcurrency import AVFoundation
import Foundation
import SheetMusicAudioCore
import SheetMusicCore
import SheetMusicMIDI

extension PlaybackEngine {
    /// Offline-render the prepared score to an audio file at `url`.
    ///
    /// The exported audio reflects the live engine state: mixer
    /// (volume / mute / solo), per-staff program changes,
    /// metronome on/off, and the current playback rate.
    ///
    /// It also reflects the live *synth*: when a `SynthBackend` is
    /// injected and can build an offline instance of itself
    /// (`makeOfflineInstance`), the export renders through that —
    /// so an export sounds like what the user just heard. Without
    /// one it falls back to the built-in AUMIDISynth pipeline,
    /// which steals voices on dense scores and sits at a different
    /// level. See `PlaybackEngine+ExportBackend`.
    ///
    /// The implementation builds a *dedicated* `AVAudioEngine` per
    /// export call rather than reusing the live playback engine —
    /// `AVAudioEngine.enableManualRenderingMode` is a global
    /// per-engine flag that doesn't compose with concurrent
    /// hardware-routed playback. The live samplers' SF2 patches
    /// are also fragile across manual-mode toggles in practice
    /// (the samplers sometimes revert to the default sine-wave
    /// preset), which is the second motivation for the fresh
    /// engine. Live mutable state (mixer levels, metronome on/off,
    /// playback rate) is snapshotted at the start of the call and
    /// reproduced on the export engine.
    ///
    /// `prepare(score:)` must have been called for the same `score`
    /// instance; otherwise throws `.noScorePrepared`.
    ///
    /// `countIn: true` puts the count live playback plays from the range's start (`play(from:in:countIn:)`) in front
    /// of the music: its clicks at the metronome strip's volume whatever the metronome toggle says, then the range
    /// itself, so the file is longer by `CountInBeats.Result.preRollSeconds(division:)` divided by the playback rate —
    /// and, on a transport that follows an alignment, by the speed of the measure it counts into, as live. The strip
    /// decides whether the click goes on after it. A start with no count-in (`CountInBeats.compute` is nil) exports as
    /// if it were `false`.
    ///
    /// On `Task.cancel()` the in-flight render is aborted at the
    /// next buffer boundary; the partial output file at `url` is
    /// deleted.
    ///
    /// Through an injected backend's offline instance the file also carries the recordings
    /// (`setRecordingTracks(_:)`) at their strips' mix — one solo bus with the instrument strips, as live — and
    /// follows the alignment (`setAlignment(warp:segments:)`): a warped score lasts its warped length, and a range is
    /// that range's warped length. The AUMIDISynth fallback renders neither recordings nor the alignment.
    public func exportAudioFile( // swiftlint:disable:this function_body_length
        to url: URL,
        score: Score,
        format: AudioFileFormat,
        range: AudioExportRange = .full,
        countIn: Bool = false,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws {
        guard let timeline = exportTimeline() else {
            throw AudioExportError.noScorePrepared
        }

        let (startTick, endTick) = try range.resolveTickRange(
            timeline: timeline, loop: loopRange,
        )
        let unrolled = exportUnrolledTimeMap()
        let body = ExportBody(timeline: timeline, unrolled: unrolled, startTick: startTick, endTick: endTick)
        // The count live playback plays from this start, ahead of the range on the same sequence clock.
        let countIn = countIn
            ? Self.exportCountIn(score: score, timeline: timeline, unrolled: unrolled, startTick: startTick)
            : nil

        let outputFormat = AudioFileExporter.outputFormat(for: format)
        let snapshot = exportEngineSnapshot()
        let writer = try AudioFileExporter.makeWriter(url: url, format: format)
        let exporter = AudioFileExporter()

        setStateForExport(.exporting)
        do {
            let pipeline = try await buildPipeline(
                score: score,
                snapshot: snapshot,
                outputFormat: outputFormat,
                timeline: timeline,
                unrolledTimeMap: unrolled,
                startTick: startTick,
                countIn: countIn,
            )
            let framesToRender = Self.exportFrameCount(
                body: body, pipeline: pipeline, snapshot: snapshot, sampleRate: outputFormat.sampleRate,
            )
            // Tear the pipeline down on the way out however this ends. A
            // cancelled export used to leave its engine running in manual
            // rendering mode until dealloc; on the backend path that engine
            // owns a synth holding a tens-of-MB SoundFont, so leaning on ARC
            // timing is no longer good enough.
            do {
                try pipeline.start()
                try await exporter.renderLoop(
                    engine: pipeline.engine,
                    outputFormat: outputFormat,
                    framesToRender: framesToRender,
                    writer: writer,
                    progress: progress,
                )
            } catch {
                pipeline.teardown()
                throw error
            }
            pipeline.teardown()
            setStateForExport(.stopped)
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: url)
            setStateForExport(.stopped)
            throw AudioExportError.cancelled
        } catch let err as AudioExportError {
            try? FileManager.default.removeItem(at: url)
            setStateForExport(.stopped)
            throw err
        } catch {
            try? FileManager.default.removeItem(at: url)
            setStateForExport(.stopped)
            throw AudioExportError.engineSetupFailed(
                underlying: (error as NSError).localizedDescription,
            )
        }
    }

    /// Frame count for the offline render loop, rate-corrected: `durationSec`
    /// is timeline-seconds at rate 1.0, but the export sequencer plays at
    /// `rate` (`sequencer.rate = snapshot.rate`), so the render actually
    /// spans `durationSec / rate` wall-clock seconds. `rate` is floored to a
    /// small positive value so a stray `0` (or negative) can't produce an
    /// infinite or zero frame count. `internal` (not `private`) so tests can
    /// exercise the rate-correction math directly.
    ///
    /// A count-in of `countInSeconds` (wall-clock, already at its own speed) goes in front, rounded to the frame as the
    /// backend rounds it, and `allowanceFrames` after (`warpDriftAllowanceFrames`). Both 0 is the frame count an
    /// export always had.
    static func renderFrameCount(
        durationSec: Double, rate: Float, sampleRate: Double, countInSeconds: Double = 0, allowanceFrames: Int = 0,
    ) -> AVAudioFrameCount {
        let renderSeconds = durationSec / Double(max(rate, 0.01))
        let body = AVAudioFrameCount((renderSeconds * sampleRate).rounded(.up))
        let countIn = AVAudioFrameCount((max(0, countInSeconds) * sampleRate).rounded())
        return countIn + body + AVAudioFrameCount(max(0, allowanceFrames))
    }

    /// The span of the transport an export plays: the range's ends on the unrolled clock, and the second a seek to its
    /// start parks the transport at, never before 0 — half a tick before the onset (`UnrolledTimeMap.park`, the rule
    /// `SwiftySynthBackend.seek(toTick:)` follows), so the onset's note-on is dispatched; the body then runs that much
    /// past its end.
    struct ExportBody {
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let parkedSeconds: TimeInterval

        /// How long the range `[startTick, endTick)` plays: its ends on the continuous notated clock — a frame lookup
        /// lands on the last onset at or before a tick, which for the end of the score is the start of its last beat,
        /// and the file stopped there — then on the unrolled clock the sequencer actually runs, so repeats and jumps
        /// play out in full. The end of the score is where the last measure-play ends, which for an al Fine / al Coda
        /// ending is not the notated end.
        init(timeline: PlaybackTimeline, unrolled: UnrolledTimeMap, startTick: Int, endTick: Int) {
            let park = unrolled.park(atTick: startTick, timeline: timeline)
            startSeconds = park.onset
            endSeconds = endTick >= timeline.totalTicks
                ? unrolled.unrolledLength(of: timeline)
                : unrolled.unrolledSeconds(fromNotated: timeline.seconds(atTick: Double(endTick)))
            parkedSeconds = max(0, park.parked)
        }
    }

    /// How many frames an export renders. The body lasts its length on the warped clock when the pipeline's transport
    /// follows the alignment — the notated one otherwise — divided by the rate; a count-in lasts what the backend
    /// holds the score for (`TransportSpeedTable.countIn(seconds:userSpeed:bodyStart:)`, the rule the backend reads),
    /// which off the alignment is the pre-roll divided by the rate — what the AUMIDISynth sequencer takes to play it.
    /// A warped body is followed by an allowance for where its end can land late: the drift at the span boundaries
    /// (`warpDriftAllowanceFrames`) and the parked lead. Without a warp or a count-in this is the frame count an export
    /// always had.
    static func exportFrameCount(
        body: ExportBody, pipeline: ExportPipeline, snapshot: ExportEngineSnapshot, sampleRate: Double,
    ) -> AVAudioFrameCount {
        let warp = pipeline.followsAlignment ? snapshot.alignmentWarp : nil
        let table = TransportSpeedTable(warp: warp)
        let warpedSeconds = table.outputSeconds(atTransport: body.endSeconds)
            - table.outputSeconds(atTransport: body.startSeconds)
        // The user speed exactly as the backend holds it (`SynthBackend.setRate`), so the count-in rounds alike.
        let userSpeed = max(0.01, Double(snapshot.rate))
        let countIn = pipeline.countInSeconds.map {
            table.countIn(seconds: $0, userSpeed: userSpeed, bodyStart: body.startSeconds).duration
        }
        var allowance = 0
        if !(warp?.spans.isEmpty ?? true) {
            let lead = table.outputSeconds(atTransport: body.startSeconds)
                - table.outputSeconds(atTransport: body.parkedSeconds)
            allowance = warpDriftAllowanceFrames(table: table, from: body.parkedSeconds, to: body.endSeconds)
                + Int((max(0, lead) / userSpeed * sampleRate).rounded(.up))
        }
        return renderFrameCount(
            durationSec: max(0, warpedSeconds), rate: snapshot.rate, sampleRate: sampleRate,
            countInSeconds: countIn ?? 0, allowanceFrames: allowance,
        )
    }

    /// Frames a warped export renders past its body, so the body's end is never cut.
    ///
    /// A backend that follows a warp sets its transport's speed per synthesizer block (`SwiftySynthBackend`: 64
    /// frames), by the stretch where the block's middle falls. A block that straddles a span boundary therefore runs
    /// at one side's speed throughout, and from there the transport lags or leads the table by up to half a block ×
    /// |Δstretch| ÷ the stretch after the boundary, in output frames (2–4 frames measured over two boundaries). The
    /// sum over every boundary the body crosses — from just before its start, where a seek parks the transport — is
    /// the most it can end late. 0 without a span, so an unwarped export keeps its length.
    static func warpDriftAllowanceFrames(
        table: TransportSpeedTable, from start: TimeInterval, to end: TimeInterval,
    ) -> Int {
        let halfBlockFrames = 32.0
        var frames = 0.0
        var previous = start - 0.01
        while let boundary = table.nextBoundary(after: previous), boundary < end {
            let before = table.stretch(atTransport: (previous + boundary) / 2)
            let after = table.stretch(atTransport: boundary)
            frames += halfBlockFrames * abs(before - after) / after
            previous = boundary
        }
        return Int(frames.rounded(.up))
    }

    /// Choose the export pipeline. An injected `SynthBackend` that can build an
    /// offline instance of itself wins — that is the only way the exported file
    /// reproduces what live playback sounds like, in both voice allocation and
    /// level. Everything else falls back to the built-in AUMIDISynth pipeline.
    private func buildPipeline(
        score: Score,
        snapshot: ExportEngineSnapshot,
        outputFormat: AVAudioFormat,
        timeline: PlaybackTimeline,
        unrolledTimeMap: UnrolledTimeMap,
        startTick: Int,
        countIn: ExportCountIn?,
    ) async throws -> ExportPipeline {
        if let offline = backend?.makeOfflineInstance(
            sampleRate: outputFormat.sampleRate,
        ) {
            return try await Self.buildBackendExportPipeline(
                score: score,
                snapshot: snapshot,
                outputFormat: outputFormat,
                timeline: timeline,
                unrolledTimeMap: unrolledTimeMap,
                startTick: startTick,
                countIn: countIn,
                backend: offline,
            )
        }
        return try Self.buildExportPipeline(
            score: score,
            snapshot: snapshot,
            outputFormat: outputFormat,
            timeline: timeline,
            startTick: startTick,
            countIn: countIn,
        )
    }

    /// Build a dedicated `AVAudioEngine` + melodic and percussion
    /// `AVAudioUnitMIDIInstrument` units + a loaded `AVAudioSequencer`
    /// ready to drive an offline render of `score`. Mirrors the live
    /// engine: melodic carries pitched channels (ch≠9), percussion
    /// carries GM channel 9; drum staves route to percussion.
    ///
    /// The engine is left in manual-rendering mode and started so the
    /// caller can immediately `start()` the returned pipeline and call
    /// `renderLoop`. Caller owns the returned pipeline and must call
    /// its `teardown` before releasing.
    private static func buildExportPipeline(
        score: Score,
        snapshot: ExportEngineSnapshot,
        outputFormat: AVAudioFormat,
        timeline: PlaybackTimeline,
        startTick: Int,
        countIn: ExportCountIn?,
    ) throws -> ExportPipeline {
        let engine = AVAudioEngine()
        let resolver = snapshot.resolver
        // Same LIVE single-port collapse the playback engine uses — one
        // strip per (part × distinct instrument) — so the offline
        // export addresses the same channels the mixer snapshot was
        // keyed against.
        let plan = LiveChannelPlan.build(score: score)

        // Master output chain — mirrors the live engine's
        // (PlaybackEngine.buildMasterChain). Rebuilt here so exported
        // files reflect the chosen master gain and shaping stage.
        let scoreGainMixer = buildOutputChain(
            engine: engine,
            gain: snapshot.masterGain,
            stage: snapshot.masterOutputStage,
        )

        // 1. Build the score synth (routed through the master stage).
        let exportSynth = buildScoreSynth(
            score: score, plan: plan, snapshot: snapshot, resolver: resolver,
            engine: engine, output: scoreGainMixer,
        )
        applyMixerSnapshot(
            scoreSynth: exportSynth, channels: snapshot.mixerChannels, soloing: snapshot.isSoloing,
        )

        // 2. Optional metronome synth / track. Onto `scoreGainMixer`, like
        //    the score — the click is scaled by the master gain, matching
        //    the live engine (see `PlaybackEngine.init`). A count-in needs it
        //    whatever the metronome toggle says.
        let metronomeSampler = buildMetronomeSampler(
            snapshot: snapshot, countsIn: countIn != nil, engine: engine, output: scoreGainMixer,
        )

        // 3. Render MIDI bytes (score tracks + optional metronome
        //    track, or the count-in assembly) and load into a fresh
        //    sequencer bound to the fresh engine.
        let sequencer = try makeExportSequencer(
            score: score, plan: plan, snapshot: snapshot, engine: engine,
            metronomeOutput: scoreGainMixer, exportSynth: exportSynth,
            metronomeSampler: metronomeSampler, countIn: countIn,
        )

        // 4. Switch to manual rendering mode and start. Engine is
        //    fresh so `enableManualRenderingMode` always succeeds.
        try engine.enableManualRenderingMode(
            .offline,
            format: outputFormat,
            maximumFrameCount: AudioFileExporter.bufferFrames,
        )
        try engine.start()

        return ExportPipeline(
            engine: engine,
            countInSeconds: countIn?.preRollSeconds,
            followsAlignment: false,
            start: {
                // A count-in sequence starts at its pre-roll origin: the assembler already moved `startTick`'s
                // content to `preRollTicks`, behind the count.
                try startSequencer(
                    sequencer, melodic: exportSynth.melodic,
                    timeline: timeline, startTick: countIn == nil ? startTick : 0,
                )
            },
            teardown: {
                sequencer.stop()
                engine.stop()
                engine.disableManualRenderingMode()
                // Releasing the references is enough; AVAudioEngine cleans
                // up its attached nodes on dealloc.
            },
        )
    }

    /// Render `score` to an SMF, append the metronome track when one is being
    /// sounded, post-process it for AUMIDISynth, and load it into a fresh
    /// `AVAudioSequencer` bound to `engine` with each track routed to its
    /// melodic / percussion / metronome unit.
    ///
    /// With `countIn`, the SMF is the live count-in build instead (`buildCountInSequencer`): the staves shifted
    /// behind the count, the count's own click track, then the body metronome.
    ///
    /// `internal` (not `private`) so a test can read the routing back: a track left without a destination still
    /// sounds, through whatever instrument `AVAudioSequencer` falls back to, so no rendered file can tell a count
    /// routed to the metronome sampler from one sounding through the score synth.
    static func makeExportSequencer(
        score: Score,
        plan: LiveChannelPlan,
        snapshot: ExportEngineSnapshot,
        engine: AVAudioEngine,
        metronomeOutput: AVAudioMixerNode,
        exportSynth: ScoreSynth,
        metronomeSampler: AVAudioUnitMIDIInstrument?,
        countIn: ExportCountIn?,
    ) throws -> AVAudioSequencer {
        var midi = try MidiRenderer.render(score: score)
        // Collapse the MuseScore-exact multi-port SMF onto the same
        // live single-port channel set `exportSynth` was built against
        // — BEFORE `postProcessForMIDISynth` below, which strips tick-0
        // events keyed on those live channel numbers. See
        // `PlaybackEngine.cachedRender` for the identical live-playback
        // ordering.
        MidiChannelRemap.apply(midi: &midi, plan: plan)
        // The tracks past the staves that the metronome sampler plays.
        var metronomeTracks: Set<Int> = []
        if let countIn {
            // The body metronome is empty with the toggle off: the count is the only click asked for. The
            // assembler applies the same post-process as the branch below, so it is not run twice.
            let assembled = PreRollSequenceAssembler.assemble(
                rendered: midi,
                metronomeBeats: snapshot.metronomeEnabled ? snapshot.metronomeBeats : [],
                mixerManagedChannels: plan.managedChannels,
                plan: countIn.plan,
                baseTick: countIn.baseTick,
            )
            midi = assembled.midi
            metronomeTracks = [assembled.preRollTrackIndex, assembled.bodyMetronomeTrackIndex]
        } else {
            if metronomeSampler != nil {
                // This controller is used only to generate the metronome MIDI track; `prepare(soundfontURL:)` is
                // never called on it, so `output` is never connected. Pass the real metronome output anyway (not
                // `mainMixerNode`) so that if a future change does call `prepare`, the click lands where the live
                // engine puts it rather than silently bypassing the gain stage and the soft clip.
                let metronome = MetronomeController(
                    engine: engine, output: metronomeOutput,
                )
                midi.tracks.append(metronome.metronomeTrack(
                    beats: snapshot.metronomeBeats, division: midi.division,
                ))
                metronomeTracks = [midi.tracks.count - 1]
            }
            // Strip RAC + complete RPN Data-Entry pair, and drop CC 7 on the
            // mixer-managed channels so the export's `applyMixerSnapshot`
            // volume / mute / solo wins instead of the SMF's tick-0 CC 7 —
            // see `PlaybackEngine.postProcessForMIDISynth` for rationale.
            postProcessForMIDISynth(
                midi: &midi,
                mixerManagedChannels: plan.managedChannels,
            )
        }
        let bytes = try MidiWriter.write(midi)
        let sequencer = AVAudioSequencer(audioEngine: engine)
        try sequencer.load(from: bytes, options: [])
        let staffTrackCount = score.allStaves.count
        for (i, track) in sequencer.tracks.enumerated() {
            if i < staffTrackCount {
                track.destinationAudioUnit = exportSynth.staffIsDrum[i] == true
                    ? (exportSynth.percussion ?? exportSynth.melodic)
                    : exportSynth.melodic
            } else if metronomeTracks.contains(i), let s = metronomeSampler {
                track.destinationAudioUnit = s
            }
        }
        sequencer.rate = snapshot.rate
        return sequencer
    }

    /// Position and start the export sequencer. Split out of
    /// `buildExportPipeline` only for length; the ordering — position, prime,
    /// re-assert pitch bend, start — is the contract and must not be shuffled.
    private static func startSequencer(
        _ sequencer: AVAudioSequencer,
        melodic: AVAudioUnitMIDIInstrument,
        timeline: PlaybackTimeline,
        startTick: Int,
    ) throws {
        // Position the sequencer at `startTick` (in beats) so
        // partial-range exports start at the right place.
        let beatsPerTick = 1.0 / Double(timeline.division)
        sequencer.currentPositionInBeats = Double(startTick) * beatsPerTick
        sequencer.prepareToPlay()
        // Re-assert pitch-bend sensitivity right before the sequencer
        // starts — see the matching block in `PlaybackEngine.play(from:in:)`
        // for the rationale. Melodic only: percussion (GM ch 9) never uses
        // pitch bend, mirroring the live engine's `play(from:in:)` path.
        for ch: UInt8 in 0 ..< 16 where ch != 9 {
            MIDISynthBuilder.setPitchBendSensitivity(
                into: melodic, semitones: 12, onChannel: ch,
            )
        }
        try sequencer.start()
    }

    /// Attach the master output chain (scoreGainMixer → sumMixer → softClip → mainMixerNode) to `engine`, seed
    /// `scoreGainMixer.outputVolume` with `gain`, and bypass the soft clip unless `stage` selects it. Returns
    /// `scoreGainMixer` — the chain's entry point, which both the score synth and the metronome sampler feed.
    /// `sumMixer` is wired but not handed back: nothing joins the chain after the gain stage, and live it exists only
    /// as the metering tap point. Mirrors `PlaybackEngine.buildMasterChain` from `+Master.swift`. `internal` (not
    /// `private`) so the backend pipeline in `PlaybackEngine+ExportBackend` builds the identical master stage.
    static func buildOutputChain(
        engine: AVAudioEngine,
        gain: Float,
        stage: MasterOutputStage,
    ) -> AVAudioMixerNode {
        let scoreGainMixer = AVAudioMixerNode()
        let sumMixer = AVAudioMixerNode()
        let softClip = SoftClipAudioUnit.makeNode()
        softClip.bypass = stage != .softClip
        engine.attach(scoreGainMixer)
        engine.attach(sumMixer)
        engine.attach(softClip)
        engine.connect(scoreGainMixer, to: sumMixer, format: nil)
        engine.connect(sumMixer, to: softClip, format: nil)
        engine.connect(softClip, to: engine.mainMixerNode, format: nil)
        scoreGainMixer.outputVolume = gain
        return scoreGainMixer
    }

    /// `internal` only so a test can hand `makeExportSequencer` the units to route to.
    struct ScoreSynth {
        let melodic: AVAudioUnitMIDIInstrument
        /// Separate percussion unit (GM channel 9), built only when the score has a drum part — mirrors the live
        /// engine's lazy percussion unit so a drumless export doesn't load the SoundFont twice. `nil` ⇒ no drums.
        let percussion: AVAudioUnitMIDIInstrument?
        /// Flat staff index → is-drum, for per-track routing.
        let staffIsDrum: [Int: Bool]
        /// Live MIDI channel per mixer strip identity — one entry per
        /// (part × distinct instrument), mirroring
        /// `PlaybackEngine.instrumentMIDIChannels`.
        let instrumentMIDIChannels: [MixerChannel.Kind: UInt8]
    }

    private static func buildScoreSynth( // swiftlint:disable:this function_body_length
        score: Score,
        plan: LiveChannelPlan,
        snapshot: ExportEngineSnapshot,
        resolver: SoundfontResolver,
        engine: AVAudioEngine,
        output: AVAudioNode,
    ) -> ScoreSynth {
        let melodic = MIDISynthBuilder.make()
        engine.attach(melodic)
        engine.connect(melodic, to: output, format: nil)
        if let url = resolver.defaultGMSoundfontURL {
            try? MIDISynthBuilder.loadSoundFont(
                into: melodic, url: url,
                bankMSB: 0, bankLSB: 0, program: 0,
            )
        }
        for ch: UInt8 in 0 ..< 16 where ch != 9 {
            MIDISynthBuilder.setPitchBendSensitivity(
                into: melodic, semitones: 12, onChannel: ch,
            )
        }

        // Percussion unit only when the score has a drum part (matches the live engine).
        var percussion: AVAudioUnitMIDIInstrument?
        if score.parts.contains(where: \.instrument.useDrumset) {
            let p = MIDISynthBuilder.make()
            engine.attach(p)
            engine.connect(p, to: output, format: nil)
            if let url = resolver.defaultGMSoundfontURL {
                try? MIDISynthBuilder.loadSoundFont(
                    into: p, url: url,
                    bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
                )
            }
            percussion = p
        }

        // Per-track routing picks the melodic or the percussion unit per
        // staff; the CHANNEL each event rides on is already baked into
        // the rendered SMF by `MidiChannelRemap`.
        var staffIsDrum: [Int: Bool] = [:]
        for (idx, entry) in score.allStaves.enumerated() {
            staffIsDrum[idx] = score.part(at: entry.address)?
                .instrument.useDrumset == true
        }

        // The SMF's tick-0 programChange events on each strip's channel
        // set up every channel's preset; pre-engine sendProgramChange is
        // only needed for mixer overrides. Cover EVERY deduped strip —
        // not just each staff's primary — so a part with an instrument
        // change doesn't leave its secondary instrument on program 0
        // (piano) for a range export that starts after that instrument's
        // own embedded programChange.
        var instrumentMIDIChannels: [MixerChannel.Kind: UInt8] = [:]
        for strip in plan.strips {
            let id = MixerChannel.Kind.instrument(
                partIndex: strip.partIndex, ordinal: strip.ordinal,
            )
            let midiCh = UInt8(clamping: strip.liveChannel)
            instrumentMIDIChannels[id] = midiCh
            guard midiCh != 9,
                  let chan = snapshot.mixerChannels.first(where: { $0.id == id }),
                  let p = chan.program
            else { continue }
            // See PlaybackEngine.loadProgram — preload to load
            // the preset, then plain PC to select.
            MIDISynthBuilder.preloadPreset(
                into: melodic,
                bankMSB: 0, bankLSB: 0, program: p,
                onChannel: midiCh,
            )
            let pcStatus = UInt32(0xC0) | UInt32(midiCh & 0x0F)
            _ = MusicDeviceMIDIEvent(
                melodic.audioUnit, pcStatus, UInt32(p), 0, 0,
            )
        }
        // Reproduce the live engine's transpose + master A4 tuning on the offline synths:
        // melodic = calibration + transpose (semitones→cents), percussion = calibration only.
        Self.applyMasterTuning(
            to: melodic,
            cents: MasterTuning.effectiveCents(
                tuning: snapshot.masterTuningCents, transposeSemitones: snapshot.transposeSemitones,
                isPercussion: false,
            ),
        )
        if let percussion {
            Self.applyMasterTuning(
                to: percussion,
                cents: MasterTuning.effectiveCents(
                    tuning: snapshot.masterTuningCents, transposeSemitones: snapshot.transposeSemitones,
                    isPercussion: true,
                ),
            )
        }

        return ScoreSynth(
            melodic: melodic, percussion: percussion,
            staffIsDrum: staffIsDrum,
            instrumentMIDIChannels: instrumentMIDIChannels,
        )
    }

    /// The click sampler, at the metronome strip's volume — built when the metronome toggle is on, or when the export
    /// counts in, whose count sounds whatever the toggle says. `nil` without a click SoundFont.
    private static func buildMetronomeSampler(
        snapshot: ExportEngineSnapshot,
        countsIn: Bool,
        engine: AVAudioEngine,
        output: AVAudioNode,
    ) -> AVAudioUnitMIDIInstrument? {
        guard snapshot.metronomeEnabled || countsIn,
              let metroURL = snapshot.metronomeSoundFontURL
        else { return nil }
        let s = MIDISynthBuilder.make()
        engine.attach(s)
        engine.connect(s, to: output, format: nil)
        try? MIDISynthBuilder.loadSoundFont(
            into: s, url: metroURL,
            bankMSB: 0, bankLSB: 0, program: 0, channel: 9,
        )
        s.volume = snapshot.metronomeVolume
        return s
    }

    /// The CC 7 an export renders an instrument strip at — playback's own rule (`MixerChannel.isSilenced`, under
    /// which mute wins over solo), so a strip the user hears silent is silent in the file. Both export pipelines read
    /// it: `applyMixerSnapshot` below for AUMIDISynth, `applyMixerSnapshotToBackend` for an injected backend.
    /// `soloing` is the snapshot's `isSoloing` — the live solo bus, a soloed recording included; the metronome is off
    /// it, and whether the click renders is carried by the snapshot's own `metronomeEnabled`.
    nonisolated static func exportVolumeCC7(of channel: MixerChannel, soloing: Bool) -> UInt8 {
        let gain: Float = channel.isSilenced(soloing: soloing) ? 0 : channel.volume
        return UInt8(clamping: Int((gain * 127).rounded()))
    }

    /// Push the mixer snapshot's volume / mute / solo onto the export
    /// synth's per-strip CC 7 state — every deduped (part × instrument)
    /// channel, not just each staff's primary, each at
    /// `exportVolumeCC7(of:soloing:)`.
    private static func applyMixerSnapshot(
        scoreSynth: ScoreSynth,
        channels: [MixerChannel],
        soloing: Bool,
    ) {
        for chan in channels {
            guard case .instrument = chan.id,
                  let midiCh = scoreSynth.instrumentMIDIChannels[chan.id]
            else { continue }
            let unit = midiCh == 9
                ? (scoreSynth.percussion ?? scoreSynth.melodic) : scoreSynth.melodic
            let cc7 = exportVolumeCC7(of: chan, soloing: soloing)
            MIDISynthBuilder.sendControlChange(
                into: unit, controller: 7, value: cc7, onChannel: midiCh,
            )
        }
    }

    /// One prepared offline render, independent of which synth drives it.
    ///
    /// `engine` is already in manual-rendering mode and started; `start` kicks
    /// whichever transport the pipeline owns (an `AVAudioSequencer` for the
    /// AUMIDISynth path, the backend's own for `+ExportBackend`) and must be
    /// called before pulling frames; `teardown` stops both and leaves manual
    /// rendering mode. Closures rather than stored transports because the two
    /// paths share no transport type.
    struct ExportPipeline {
        let engine: AVAudioEngine
        /// The count-in's own seconds on the sequence clock (`ExportCountIn.preRollSeconds`) when `start` plays one
        /// before the body, else nil.
        let countInSeconds: TimeInterval?
        /// Whether the transport follows the snapshot's alignment: an offline backend that plays recordings.
        let followsAlignment: Bool
        let start: @MainActor () throws -> Void
        let teardown: @MainActor () -> Void
    }
}
