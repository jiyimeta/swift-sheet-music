import Foundation
import SheetMusicAudioCore
@_spi(PlaybackProbe) import SheetMusicAudioWindows
import SheetMusicCore

// The scripted steps of the ssm 4.0.0 D design's §7 (in folino,
// docs/superpowers/specs/2026-09-30-ssm-4-d-windows-playback-design.md), one method per step. Every limit below is the
// spec's, except where a comment says what the spec's number could not measure and what is checked instead.

// swiftlint:disable file_length

/// Drives one `WindowsPlaybackEngine` through the checks.
final class Probe { // swiftlint:disable:this type_body_length
    let engine: WindowsPlaybackEngine
    let score: Score
    let report: ProbeReport
    let inbox: ProbeInbox
    /// The SoundFont the engine loaded: a copy the probe owns, so the rename question can be asked of it safely.
    let soundFontCopy: URL
    private let clock = ContinuousClock()

    init(engine: WindowsPlaybackEngine, score: Score, report: ProbeReport, inbox: ProbeInbox, soundFontCopy: URL) {
        self.engine = engine
        self.score = score
        self.report = report
        self.inbox = inbox
        self.soundFontCopy = soundFontCopy
    }

    private var measureCount: Int {
        score.parts.first?.staves.first?.measures.count ?? 0
    }

    private func wait(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// Polls `condition` every 10 ms until it holds or `timeout` passes; answers whether it held.
    private func waitUntil(timeout: Double, _ condition: () -> Bool) -> Bool {
        let start = clock.now
        while seconds(clock.now - start) < timeout {
            if condition() { return true }
            wait(0.01)
        }
        return condition()
    }

    private func measureCursor(_ index: Int) -> ScoreCursor {
        .beat(measureIndex: max(0, min(index, measureCount - 1)), tickInMeasure: 0)
    }

    private func controller7(_ channel: Int) -> Int {
        engine.probeController(7, onChannel: channel) ?? -1
    }

    /// How many ticks 64 frames are at the unrolled `tick` — the resolution of every render-thread decision.
    private func ticksPerChunk(at tick: Int?) -> Double {
        tick.flatMap { engine.probeTicksPerChunk(atUnrolledTick: $0) } ?? 0
    }

    // MARK: prepare

    func prepare() {
        let diagnostics = engine.diagnostics
        let bufferMilliseconds = Double(diagnostics.bufferFrames) / diagnostics.sampleRate * 1000
        let latencyMilliseconds = diagnostics.latencySeconds * 1000
        report.note(
            "prepare",
            "rate \(Int(diagnostics.sampleRate)) Hz, buffer \(diagnostics.bufferFrames) frames "
                + "(\(formatted(bufferMilliseconds, 1)) ms), latency \(formatted(latencyMilliseconds, 1)) ms",
        )
        report.check(
            "prepare", "output device", diagnostics.hasOutputDevice,
            value: "\(diagnostics.hasOutputDevice)", limit: "true",
        )
        report.check(
            "prepare", "SoundFont loaded", diagnostics.soundFontLoaded,
            value: "\(diagnostics.soundFontLoaded)", limit: "true",
        )

        var mismatches: [String] = []
        let strips = engine.probeStrips
        for strip in strips {
            let expected = engine.mixerChannels.first { $0.id == strip.kind }?.program.map(Int.init)
            let actual = engine.probeProgram(onChannel: strip.channel)
            let bankHeld = !strip.isDrum || actual?.first == 128
            if actual?.last != expected || !bankHeld {
                mismatches.append("ch\(strip.channel) \(actual.map { "\($0)" } ?? "?") expected \(expected ?? -1)")
            }
        }
        report.check(
            "prepare", "programs held", mismatches.isEmpty,
            value: mismatches.isEmpty ? "\(strips.count) strips" : mismatches.joined(separator: "; "),
            limit: "every strip on its mixer program, drums in bank 128",
        )
        let dynamic = engine.probeSetting("synth.dynamic-sample-loading")
        report.check("prepare", "synth.dynamic-sample-loading", dynamic == 0, value: "\(dynamic ?? -1)", limit: "0")
        let reset = engine.probeSetting("player.reset-synth")
        report.check("prepare", "player.reset-synth", reset == 0, value: "\(reset ?? -1)", limit: "0")

        // W0-6's open question: does FluidSynth keep the SoundFont's file open after loading it?
        let renamed = soundFontCopy.appendingPathExtension("renamed")
        do {
            try FileManager.default.moveItem(at: soundFontCopy, to: renamed)
            try FileManager.default.moveItem(at: renamed, to: soundFontCopy)
            report.note("prepare", "the loaded SoundFont could be renamed: FluidSynth does not hold its file open")
        } catch {
            report.note("prepare", "the loaded SoundFont could NOT be renamed (\(error)): FluidSynth holds its file")
        }
    }

    // MARK: play

    /// Ten seconds from the top: the tick's seconds against the wall clock, and against the audio rendered.
    func play() { // swiftlint:disable:this function_body_length
        let duration = min(10, engine.totalTimeSeconds - 1)
        guard duration > 2 else {
            report.note("play", "score too short (\(formatted(engine.totalTimeSeconds, 1)) s) to measure drift")
            return
        }
        let diagnostics = engine.diagnostics
        let underrunsBefore = diagnostics.underruns
        // The drift's points: every 64-frame chunk of the first `duration − 0.5` s of audio the score renders.
        let traceChunks = Int((duration - 0.5) * diagnostics.sampleRate) / 64
        engine.stop()
        engine.probeStartClockTrace(chunks: traceChunks)
        engine.play(in: score)
        let start = clock.now
        var samples: [(wall: Double, delta: Double)] = []
        var misdated = 0
        while seconds(clock.now - start) < duration {
            wait(0.05)
            // Dated by the middle of a bracket around the read. A bracket over 2 ms means the probe was preempted, or
            // waited out a render callback for the lock: its wall time is not the tick's, and read as the cursor's
            // jitter it would be the probe's own. Dropped and counted instead.
            let before = seconds(clock.now - start)
            let tickSeconds = engine.probeContinuousSeconds
            let after = seconds(clock.now - start)
            guard after - before <= 0.002 else {
                misdated += 1
                continue
            }
            let wall = (before + after) / 2
            samples.append((wall, wall - tickSeconds))
        }
        let trace = engine.probeTakeClockTrace()
        engine.stop()

        // The first half second holds the start-up (the first buffer fill): an offset, not jitter. After it the tick
        // moves once per render wake, a device period (~10 ms) at a time, so this reads about ±5 ms with nothing wrong
        // and a render wake that comes late adds to it directly: the 10 ms leaves ~5 ms for that.
        let steady = samples.filter { $0.wall >= 0.5 }
        if steady.count > 2 {
            let mean = steady.map(\.delta).reduce(0, +) / Double(steady.count)
            let deviation = steady.map { abs($0.delta - mean) }.max() ?? 0
            report.check(
                "play", "|Δ(wall − tick s) − mean|", deviation <= 0.010,
                value: "\(formatted(deviation * 1000, 2)) ms (mean \(formatted(mean * 1000, 1)) ms, "
                    + "\(steady.count) polls, \(misdated) dropped as misdated)",
                limit: "≤ 10 ms",
            )
            // Against the wall clock the slope is the output device's crystal against QPC — ±50 ppm (±3 ms/min) is an
            // ordinary tolerance, and the cursor has to follow the audio, not QPC — and the ~10 ms steps above let a
            // 50 ms poll over 9.5 s resolve it only to ≈ ±5 ms/min (1σ = period / (√N · 9.5 s)): the first Windows run
            // read 1.06 ms/min. So it is reported, not gated; the check above still fails a rate error from ~0.1 %.
            let wallSlope = Self.slope(steady.map(\.wall), steady.map(\.delta)) * 60000
            report.note(
                "play",
                "wall − tick slope \(formatted(wallSlope, 2)) ms/min (\(formatted(wallSlope * 1000 / 60, 1)) ppm): the "
                    + "device's clock against QPC, within ±5 ms/min of poll resolution — not gated",
            )
        } else {
            report.check(
                "play", "|Δ(wall − tick s) − mean|", false,
                value: "\(steady.count) polls kept, \(misdated) dropped as misdated", limit: "≤ 10 ms",
            )
        }

        // The spec's ≤ 1 ms/min is for drift this engine could accumulate itself — FluidSynth's player, the SMF's tempo
        // against the timeline's, the unroll — so it is taken on the score's clock against the audio rendered, which
        // the players run on, and fitted over every chunk of the trace rather than over the polls. FluidSynth moves
        // its player in whole milliseconds of the sample clock (`fluid_sample_timer_process` truncates) and in whole
        // ticks (`fluid_player_callback` rounds), so tick s − rendered s is a sawtooth 1.7–2 ms peak to peak (σ 0.4 ms
        // at 124 bpm, 480 ppq). A slope through 150–190 polls of it hangs on the polls' phase against that sawtooth: a
        // model of FluidSynth's arithmetic gives σ 0.3–0.7 ms/min while the phase wanders, and 1.8 ms/min once
        // Windows' default 15.6 ms timer rounds the 50 ms sleep up to 62.5 ms and the phase only creeps — so the gate
        // at 1 ms/min read the scheduling, not the engine (two runs: 0.21, then 1.84 under a Defender scan). Every
        // chunk is the same ~7,000 points each run however the threads are scheduled, so the fit depends on the score
        // and the rate alone: the sawtooth's own slope, −0.045 ms/min at 48 or 44.1 kHz (of the order of 2 · 0.5 ms ·
        // its 125 ms period / (9.5 s)² ≈ 0.08). A tempo event inside the window would re-anchor the player and step the
        // sawtooth by up to half a tick, which a fit reads as up to ~5 ms/min: the sample score has one, at tick 0.
        let drift = Self.slope(trace.map(\.rendered), trace.map { $0.score - $0.rendered }) * 60000
        report.check(
            "play", "drift (tick s − rendered s)", trace.count == traceChunks && abs(drift) <= 1,
            value: "\(formatted(drift, 3)) ms/min over \(trace.count) chunks",
            limit: "≤ 1 ms/min over \(traceChunks) chunks",
        )
        let underruns = engine.diagnostics.underruns - underrunsBefore
        report.check("play", "underruns", underruns == 0, value: "\(underruns)", limit: "0")
    }

    /// Least-squares slope of `y` over `x`.
    private static func slope(_ x: [Double], _ y: [Double]) -> Double {
        let count = Double(x.count)
        let meanX = x.reduce(0, +) / count
        let meanY = y.reduce(0, +) / count
        var numerator = 0.0
        var denominator = 0.0
        for (xi, yi) in zip(x, y) {
            numerator += (xi - meanX) * (yi - meanY)
            denominator += (xi - meanX) * (xi - meanX)
        }
        return denominator > 0 ? numerator / denominator : 0
    }

    // MARK: seek

    func seek() {
        let target = measureCursor(4)
        let measure = target.measureIndex
        engine.stop()
        engine.play(in: score)
        wait(1)
        engine.seek(to: target)
        let first = engine.currentCursor?.measureIndex
        report.check(
            "seek", "first poll after a seek while playing", first == measure,
            value: "measure \(first.map { $0 + 1 } ?? 0)", limit: "measure \(measure + 1)",
        )
        wait(0.5)

        // The landing tick, on a transport slowed to a crawl so the first observation is the landing itself.
        engine.pause()
        engine.setRate(0.001)
        engine.seek(to: target)
        engine.play(in: score)
        wait(0.2)
        if let expected = engine.probeUnrolledTick(for: target), let landed = engine.probeTransport?.scorePlayerTick {
            report.check(
                "seek", "landing tick", landed >= expected && landed <= expected + 2,
                value: "\(landed)", limit: "[\(expected), \(expected + 2)]",
            )
        }
        engine.pause()
        engine.setRate(1)

        guard engine.totalTimeSeconds > 21 else {
            report.note("seek", "score too short for ±10 s skips")
            engine.stop()
            return
        }
        // A skip lands on the frame at or before the target time (`PlaybackTimeline.frame(atTime:)`), as the Apple
        // engine's `skip(by:)` does, so it moves 10 s less the gap back to that frame, not 10 s flat — the spec's
        // 10 ± 0.05 s held only where a frame happens to sit within 50 ms before the target. The −10 s skip starts past
        // the 10 s mark: from under it, the clamp at the top decides the step, not the skip.
        let timeline = PlaybackTimeline(score: score)
        engine.seek(to: measureCursor(0))
        let before = engine.currentTimeSeconds
        engine.skip(by: 10)
        checkSkip("skip +10 s", from: before, by: 10, timeline: timeline)
        engine.skip(by: 10)
        let middle = engine.currentTimeSeconds
        engine.skip(by: -10)
        checkSkip("skip −10 s", from: middle, by: -10, timeline: timeline)
        engine.stop()
    }

    /// Checks that a skip by `step` from `start` landed on the frame at or before `start + step`.
    private func checkSkip(_ name: String, from start: Double, by step: Double, timeline: PlaybackTimeline) {
        let target = max(0, min(timeline.totalSeconds, start + step))
        let expected = timeline.frame(atTime: target)?.timeSeconds ?? -1
        let landed = engine.currentTimeSeconds
        report.check(
            "seek", name, expected >= 0 && abs(landed - expected) <= 0.001,
            value: "Δ \(formatted(abs(landed - start))) s",
            limit: "Δ \(formatted(abs(expected - start))) s: the frame at or before \(formatted(target)) s",
        )
    }

    // MARK: rate

    func rate() {
        for rate in [0.5, 2.0] {
            let window = min(10, (engine.totalTimeSeconds - 1) / rate)
            guard window > 2 else {
                report.note("rate", "score too short for rate \(rate)")
                continue
            }
            engine.stop()
            // Set while stopped: the players take the remembered rate when they start.
            engine.setRate(Float(rate))
            engine.play(in: score)
            wait(0.3)
            let startSeconds = engine.probeContinuousSeconds
            let start = clock.now
            wait(window)
            let advanced = engine.probeContinuousSeconds - startSeconds
            let expected = seconds(clock.now - start) * rate
            report.check(
                "rate", "rate \(rate) for \(formatted(window, 1)) s", abs(advanced - expected) <= 0.1,
                value: "\(formatted(advanced)) s of score", limit: "\(formatted(expected)) ± 0.1 s",
            )
        }
        engine.stop()
        engine.setRate(1)
    }

    // MARK: loop

    // swiftlint:disable:next function_body_length
    func loop() {
        guard measureCount >= 6 else {
            report.note("loop", "the score needs 6 measures for the 3–5 loop")
            return
        }
        engine.stop()
        engine.setLoop(from: measureCursor(2), to: measureCursor(5))
        let wrapsBefore = engine.diagnostics.loopWraps
        guard let bounds = engine.probeTransport, let loopStart = bounds.loopStartTick, let loopEnd = bounds.loopEndTick
        else {
            report.check("loop", "loop set", false, value: "no transport loop", limit: "measures 3–5")
            return
        }
        let perChunk = ticksPerChunk(at: loopEnd - 1)
        engine.play(from: measureCursor(2), in: score)
        var worstDetection = Int.min
        var worstLanding = Int.min
        var seen = wrapsBefore
        let reached = waitUntil(timeout: 90) {
            let wraps = engine.diagnostics.loopWraps
            if wraps > seen, let transport = engine.probeTransport {
                seen = wraps
                if let detected = transport.lastWrapDetectedTick {
                    worstDetection = max(worstDetection, detected - loopEnd)
                }
                if let landed = transport.lastWrapLandingTick {
                    worstLanding = max(worstLanding, landed - loopStart)
                }
            }
            return wraps - wrapsBefore >= 3
        }
        engine.clearLoop()
        // Let the last landing be read, then run on past the old end.
        wait(0.05)
        if let landed = engine.probeTransport?.lastWrapLandingTick {
            worstLanding = max(worstLanding, landed - loopStart)
        }
        let loopTicks = loopEnd - loopStart
        let runPast = waitUntil(timeout: 30) {
            (engine.probeTransport?.scorePlayerTick ?? 0) > loopEnd + loopTicks / 8
        }
        let wraps = engine.diagnostics.loopWraps - wrapsBefore
        report.check("loop", "wraps", reached && wraps == 3, value: "\(wraps)", limit: "exactly 3")
        report.check(
            "loop", "wrap decided past the end by", worstDetection >= 0 && Double(worstDetection) <= perChunk + 1,
            value: "\(worstDetection) ticks", limit: "≤ 64 frames (\(formatted(perChunk, 1)) ticks)",
        )
        report.check(
            "loop", "landing past the start by", worstLanding >= 0 && worstLanding <= 2,
            value: "\(worstLanding) ticks", limit: "≤ 2 ticks",
        )
        report.check("loop", "clearLoop runs past the end", runPast, value: "\(runPast)", limit: "true")

        // A count-in into a loop that starts mid-score hands over at the loop's start. Read at the first poll that sees
        // the handover: past the start by no more than what can have rendered since the last poll that still saw the
        // count — that much device time, plus the one buffer the render thread may have filled ahead of the device.
        // (A fixed "50 ms after" left out the poll's own latency, Windows' 15.6 ms timer rounding every sleep up, and
        // the buffer: the first run read 61 ms of music against 53 ticks allowed.)
        engine.stop()
        engine.setLoop(from: measureCursor(2), to: measureCursor(5))
        engine.play(in: score, countIn: true)
        let countStart = clock.now
        var lastCounting = countStart
        var sawCount = false
        var handedOver = -1
        var window = 0.0
        while seconds(clock.now - countStart) < 15 {
            let polled = clock.now
            guard let transport = engine.probeTransport else { break }
            if transport.countingIn {
                sawCount = true
                lastCounting = polled
            } else {
                handedOver = transport.reportedScoreTick
                window = seconds(clock.now - lastCounting)
                break
            }
            wait(0.005)
        }
        let diagnostics = engine.diagnostics
        let slackFrames = window * diagnostics.sampleRate + Double(diagnostics.bufferFrames)
        let tolerance = Int((ticksPerChunk(at: loopStart) * (slackFrames / 64 + 1)).rounded(.up))
        report.check(
            "loop", "count-in into the loop starts at its start",
            sawCount && handedOver >= loopStart && handedOver <= loopStart + tolerance,
            value: "tick \(handedOver), \(formatted(window * 1000, 1)) ms after the count was last seen",
            limit: "[\(loopStart), \(loopStart + tolerance)]",
        )
        engine.stop()
        engine.clearLoop()
    }

    // MARK: tuning

    func tuning() {
        let strips = engine.probeStrips
        let drumsBefore = strips.filter(\.isDrum).map { engine.probeTuning(onChannel: $0.channel) }
        let tuningCents = -31.77
        engine.setMasterTuning(cents: tuningCents)
        engine.setTranspose(semitones: 2)
        for strip in strips {
            let cents = MasterTuning.effectiveCents(
                tuning: tuningCents, transposeSemitones: 2, isPercussion: strip.isDrum,
            )
            let expected = MasterTuning.split(cents: cents)
            guard let actual = engine.probeTuning(onChannel: strip.channel) else { continue }
            let held = actual[0] == Double(expected.coarseSemitones) && abs(actual[1] - expected.fineCents) <= 0.05
            let cc6 = engine.probeController(6, onChannel: strip.channel) ?? -1
            let cc38 = engine.probeController(38, onChannel: strip.channel) ?? -1
            report.check(
                "tuning", "ch\(strip.channel)\(strip.isDrum ? " (drums)" : "")", held,
                value: "coarse \(Int(actual[0])), fine \(formatted(actual[1], 2)) (CC6 \(cc6), CC38 \(cc38))",
                limit: "coarse \(expected.coarseSemitones), fine \(formatted(expected.fineCents, 2)) ± 0.05",
            )
        }
        engine.setMasterTuning(cents: 0)
        let drumsAfter = strips.filter(\.isDrum).map { engine.probeTuning(onChannel: $0.channel) }
        if !drumsBefore.isEmpty {
            report.check(
                "tuning", "transposition leaves drums at concert pitch", drumsBefore == drumsAfter,
                value: "\(drumsAfter)", limit: "\(drumsBefore)",
            )
        }
        engine.setTranspose(semitones: 0)
        report.note("tuning", "ear (optional): transpose +2 while playing — the melody up a tone, drums unchanged")
    }

    // MARK: mixer

    // swiftlint:disable:next function_body_length
    func mixer() {
        let strips = engine.probeStrips
        guard let first = strips.first(where: { !$0.isDrum }) ?? strips.first else { return }
        let original = engine.mixerChannels.first { $0.id == first.kind }
        engine.setVolume(forChannel: first.kind, to: 0.5)
        report.check(
            "mixer", "volume 0.5 → CC7", controller7(first.channel) == 64,
            value: "\(controller7(first.channel))", limit: "64",
        )
        engine.setMuted(forChannel: first.kind, to: true)
        report.check(
            "mixer", "mute → CC7", controller7(first.channel) == 0, value: "\(controller7(first.channel))", limit: "0",
        )
        engine.setMuted(forChannel: first.kind, to: false)
        report.check(
            "mixer", "unmute → CC7", controller7(first.channel) == 64,
            value: "\(controller7(first.channel))", limit: "64",
        )
        if let other = strips.first(where: { $0.kind != first.kind }) {
            engine.setSoloed(forChannel: other.kind, to: true)
            report.check(
                "mixer", "solo another → CC7", controller7(first.channel) == 0,
                value: "\(controller7(first.channel))", limit: "0",
            )
            engine.setSoloed(forChannel: other.kind, to: false)
            report.check(
                "mixer", "unsolo → CC7", controller7(first.channel) == 64,
                value: "\(controller7(first.channel))", limit: "64",
            )
        }

        engine.setMuted(forChannel: .metronome, to: true)
        let mutedLevel = engine.probeTransport?.metronomeLevel ?? -1
        report.check("mixer", "metronome mute", mutedLevel == 0, value: "level \(mutedLevel)", limit: "0")
        engine.setMuted(forChannel: .metronome, to: false)
        let unmutedLevel = engine.probeTransport?.metronomeLevel ?? -1
        report.check("mixer", "metronome unmute", unmutedLevel > 0, value: "level \(unmutedLevel)", limit: "> 0")

        let program: UInt8 = first.isDrum ? 25 : 40
        engine.setProgram(forChannel: first.kind, to: program)
        let read = engine.probeProgram(onChannel: first.channel)
        report.check(
            "mixer", "program", read?.last == Int(program), value: "\(read ?? [])", limit: "program \(program)",
        )
        if let original {
            engine.setVolume(forChannel: first.kind, to: original.volume)
            if let program = original.program {
                engine.setProgram(forChannel: first.kind, to: program)
            }
        }

        // Master gain 4× past full scale: `.none` lets it through, `.softClip` keeps it under.
        engine.stop()
        engine.startLevelMonitoring { [inbox] level in inbox.record(level) }
        engine.play(in: score)
        engine.setMasterGain(4)
        var peaks: [MasterOutputStage: Float] = [:]
        for stage in [MasterOutputStage.none, .softClip] {
            engine.setMasterOutputStage(stage)
            wait(0.1)
            var peak: Float = 0
            let start = clock.now
            while seconds(clock.now - start) < 2 {
                peak = max(peak, engine.probeTransport?.lastOutputPeak ?? 0)
                wait(0.005)
            }
            peaks[stage] = peak
        }
        let levels = inbox.takeLevels()
        engine.stopLevelMonitoring()
        engine.setMasterGain(1)
        engine.setMasterOutputStage(.none)
        engine.stop()
        report.check(
            "mixer", "gain 4× with .none", (peaks[MasterOutputStage.none] ?? 0) > 1,
            value: "peak \(formatted(Double(peaks[MasterOutputStage.none] ?? 0)))", limit: "> 1",
        )
        report.check(
            "mixer", "gain 4× with .softClip", (peaks[.softClip] ?? 2) <= 1,
            value: "peak \(formatted(Double(peaks[.softClip] ?? 0)))", limit: "≤ 1",
        )
        report.check(
            "mixer", "level monitoring", levels.readings > 0,
            value: "\(levels.readings) readings, pre-shaping peak \(formatted(Double(levels.peak)))",
            limit: "> 0 readings",
        )
    }

    // MARK: preview

    func preview() {
        engine.stop()
        if let note = firstNote(drums: false) {
            engine.playPreview(noteID: note, in: score, duration: 0.3)
            wait(0.05)
            let sounding = engine.probeActiveVoices[0]
            report.check("preview", "tap sounds", sounding > 0, value: "\(sounding) voices", limit: "> 0")
            let start = clock.now
            let silent = waitUntil(timeout: 3) { engine.probeActiveVoices[0] == 0 }
            let after = seconds(clock.now - start) + 0.05
            report.check(
                "preview", "tap silent after ring + tail", silent && after <= 0.3 + 0.8 + 0.3,
                value: "\(formatted(after, 2)) s", limit: "≤ 1.4 s (0.3 ring + 0.8 tail + 0.3)",
            )
        }
        if let drum = firstNote(drums: true) {
            engine.playPreview(noteID: drum, in: score, duration: 0.3)
            wait(1.5)
            report.note("preview", "drum at 1.5 s: \(engine.probeActiveVoices[0]) voices (a drum rings 2 s)")
            let silent = waitUntil(timeout: 3) { engine.probeActiveVoices[0] == 0 }
            report.check("preview", "drum silent after 2 s + tail", silent, value: "\(silent)", limit: "silent")
        }
        engine.previewNoteOn(pitch: 60, onStaff: 0, atTick: 0)
        wait(0.3)
        let held = engine.probeActiveVoices[0]
        engine.previewNoteOff(pitch: 60)
        let released = waitUntil(timeout: 3) { engine.probeActiveVoices[0] == 0 }
        report.check(
            "preview", "held note sounds, then stops", held > 0 && released,
            value: "\(held) voices held, released \(released)", limit: "> 0, then 0",
        )
        previewRightAfterPause()
    }

    /// A held preview started in the same moment as a pause. The paused score player sends All Sound Off in its next
    /// rendered block — on the channels it sent a note-on on, and only those (`fluid_player_callback`) — which the
    /// preview's note-on must not be caught by (folino docs/superpowers/specs/2026-10-03-ssm-windows-minor-design.md
    /// §4). So playback starts AT a note of the previewed staff: its channel is then one the player played on, as in
    /// a reader paused mid-piece. Ten tries: a lost one depends on when the next block comes.
    private func previewRightAfterPause() {
        guard let note = firstNote(drums: false),
              let staff = score.allStaves.firstIndex(where: { $0.address == note.staff })
        else {
            report.check("preview", "a preview right after a pause sounds", false, value: "no pitched note", limit: "")
            return
        }
        let tick = PreviewRouting.tick(of: note, in: score)
        let trials = 10
        var sounded = 0
        var counts: [Int] = []
        for _ in 0 ..< trials {
            engine.play(from: .item(.note(note)), in: score)
            wait(0.5)
            engine.pause()
            engine.previewNoteOn(pitch: 72, onStaff: staff, atTick: tick)
            wait(0.15)
            let voices = engine.probeActiveVoices[0]
            counts.append(voices)
            if voices > 0 {
                sounded += 1
            }
            engine.previewNoteOff(pitch: 72)
            _ = waitUntil(timeout: 3) { engine.probeActiveVoices[0] == 0 }
        }
        engine.stop()
        report.check(
            "preview", "a preview right after a pause sounds", sounded == trials,
            value: "\(sounded) of \(trials) (voices \(counts))", limit: "\(trials) of \(trials)",
        )
    }

    private func firstNote(drums: Bool) -> NoteID? {
        for (address, staff) in score.allStaves {
            guard (score.part(at: address)?.instrument.useDrumset == true) == drums else { continue }
            for (measureIndex, measure) in staff.measures.enumerated() {
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for (elementIndex, element) in voice.elements.enumerated() {
                        if case let .chord(chord) = element, !chord.notes.isEmpty {
                            return NoteID(
                                staff: address, measureIndex: measureIndex, voiceIndex: voiceIndex,
                                elementIndex: elementIndex, noteIndexInChord: 0,
                            )
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: count-in

    func countIn() {
        engine.stop()
        let start = measureCursor(2)
        // A count-in sounds whatever the metronome's mute says.
        engine.setMuted(forChannel: .metronome, to: true)
        engine.play(from: start, in: score, countIn: true)
        wait(0.05)
        let transport = engine.probeTransport
        report.check(
            "countin", "counting, audible though muted",
            transport?.countingIn == true && (transport?.metronomeLevel ?? 0) > 0,
            value: "counting \(transport?.countingIn ?? false), level \(transport?.metronomeLevel ?? 0)",
            limit: "counting, level > 0",
        )
        let pinned = engine.currentCursor?.measureIndex
        report.check(
            "countin", "cursor pinned to the start", pinned == start.measureIndex,
            value: "measure \(pinned.map { $0 + 1 } ?? 0)", limit: "measure \(start.measureIndex + 1)",
        )
        let handedOver = waitUntil(timeout: 15) { engine.probeTransport?.countingIn == false }
        let late = engine.diagnostics.lastCountInHandoverLateTicks
        let perChunk = ticksPerChunk(at: engine.probeUnrolledTick(for: start))
        report.check(
            "countin", "handover late by", handedOver && (late ?? -1) >= 0 && Double(late ?? 0) <= perChunk + 1,
            value: "\(late.map(String.init) ?? "–") ticks", limit: "≤ 64 frames (\(formatted(perChunk, 1)) ticks)",
        )
        wait(2)
        engine.stop()
        engine.setMuted(forChannel: .metronome, to: false)
        report.note("countin", "ear (required once): one bar of wood-block clicks, then the music on the next downbeat")
    }

    // MARK: device

    /// The env-var fault hook: the shim fails one buffer request with AUDCLNT_E_DEVICE_INVALIDATED.
    func deviceFault() { // swiftlint:disable:this function_body_length
        guard ProcessInfo.processInfo.environment["SSM_WASAPI_FAIL_ONCE"] == "invalidated" else {
            report.note("device", "skipped: run with SSM_WASAPI_FAIL_ONCE=invalidated for the fault hook")
            return
        }
        _ = inbox.takeEvents()
        _ = inbox.takeRemovals()
        let bufferSeconds = Double(engine.diagnostics.bufferFrames) / engine.diagnostics.sampleRate

        // While playing.
        engine.stop()
        engine.play(in: score)
        wait(1)
        let rebuildsBefore = engine.diagnostics.deviceRebuilds
        var samples: [(wall: Double, tick: Double)] = []
        let start = clock.now
        // The same measurement with nothing wrong, first: the tick moves once per render wake, so consecutive polls
        // read up to one device period (plus the poll's own lateness) ahead of the wall clock. That floor is added to
        // the bound below — measured three times, the jump read 28.3, 36.7 and 41.9 ms against a 40 ms buffer.
        var steady: [(wall: Double, tick: Double)] = []
        for _ in 0 ..< 30 {
            wait(0.01)
            steady.append((seconds(clock.now - start), engine.probeContinuousSeconds))
        }
        let floor = zip(steady, steady.dropFirst())
            .map { pair in (pair.1.tick - pair.0.tick) - (pair.1.wall - pair.0.wall) }
            .max() ?? 0
        engine.probeInjectDeviceFault()
        let rebuilt = waitUntil(timeout: 3) {
            samples.append((seconds(clock.now - start), engine.probeContinuousSeconds))
            return engine.diagnostics.deviceRebuilds > rebuildsBefore
        }
        for _ in 0 ..< 50 {
            wait(0.01)
            samples.append((seconds(clock.now - start), engine.probeContinuousSeconds))
        }
        let diagnostics = engine.diagnostics
        report.check(
            "device", "rebuilt once (playing)", rebuilt && diagnostics.deviceRebuilds - rebuildsBefore == 1,
            value: "\(diagnostics.deviceRebuilds - rebuildsBefore)", limit: "1",
        )
        report.check("device", "still playing", engine.state == .playing, value: "\(engine.state)", limit: "playing")
        let rebuildSeconds = diagnostics.lastDeviceRebuildSeconds ?? .infinity
        report.check(
            "device", "rebuild time", rebuildSeconds <= 0.5,
            value: "\(formatted(rebuildSeconds * 1000, 1)) ms", limit: "≤ 500 ms",
        )
        var jump = 0.0
        for (previous, next) in zip(samples, samples.dropFirst()) {
            jump = max(jump, (next.tick - previous.tick) - (next.wall - previous.wall))
        }
        let bound = bufferSeconds + max(0, floor)
        report.check(
            "device", "tick jump", jump <= bound,
            value: "\(formatted(jump * 1000, 1)) ms",
            limit: "≤ 1 buffer (\(formatted(bufferSeconds * 1000, 1)) ms) + the steady poll floor "
                + "(\(formatted(floor * 1000, 1)) ms)",
        )
        let events = inbox.takeEvents()
        report.check(
            "device", "events", events.contains(.deviceLost) && events.contains(.deviceRecovered),
            value: "\(events)", limit: "deviceLost, deviceRecovered",
        )
        // The control for the removal below: the device is still there after this one.
        let removalsOnInvalidation = inbox.takeRemovals()
        report.check(
            "device", "an invalidation with the device kept is no removal", removalsOnInvalidation == 0,
            value: "\(removalsOnInvalidation) removals", limit: "0",
        )

        // While paused: the position is kept, and the resume plays from it.
        engine.pause()
        let pausedTick = engine.probeTransport?.reportedScoreTick ?? -1
        let pausedRebuilds = engine.diagnostics.deviceRebuilds
        engine.probeInjectDeviceFault()
        let rebuiltPaused = waitUntil(timeout: 3) { engine.diagnostics.deviceRebuilds > pausedRebuilds }
        let afterTick = engine.probeTransport?.reportedScoreTick ?? -2
        report.check(
            "device", "rebuilt once (paused), position kept", rebuiltPaused && afterTick == pausedTick,
            value: "tick \(afterTick)", limit: "tick \(pausedTick)",
        )
        engine.play(in: score)
        wait(0.1)
        let resumed = engine.probeTransport?.scorePlayerTick ?? -1
        // At most the 100 ms waited, and a few chunks either side.
        let allowance = ticksPerChunk(at: max(0, pausedTick)) * (0.1 * engine.diagnostics.sampleRate / 64 + 20)
        report.check(
            "device", "resume after a paused rebuild",
            resumed >= pausedTick && Double(resumed - pausedTick) <= allowance,
            value: "tick \(resumed)", limit: "[\(pausedTick), \(pausedTick + Int(allowance))]",
        )
        deviceRemoval()
        engine.stop()
    }

    /// An unplug as the stream sees one — the invalidation, then the device gone — while playing: reported once
    /// through `onOutputDeviceRemoved`, and the engine plays on (pausing is the host's call).
    private func deviceRemoval() {
        _ = inbox.takeEvents()
        _ = inbox.takeRemovals()
        let rebuildsBefore = engine.diagnostics.deviceRebuilds
        engine.probeInjectDeviceFault(removed: true)
        let rebuilt = waitUntil(timeout: 3) { engine.diagnostics.deviceRebuilds > rebuildsBefore }
        // `deviceRecovered` follows the rebuild count by a moment.
        wait(0.1)
        let removals = inbox.takeRemovals()
        let events = inbox.takeEvents()
        report.check(
            "device", "a removal is reported once", rebuilt && removals == 1,
            value: "\(removals) removals, rebuilt \(rebuilt)", limit: "1",
        )
        report.check(
            "device", "after a removal the engine plays on, lost and recovered",
            engine.state == .playing && events.contains(.deviceLost) && events.contains(.deviceRecovered),
            value: "\(engine.state), \(events)", limit: "playing; deviceLost, deviceRecovered",
        )
    }

    /// A real device switch: the operator changes the default output while this plays.
    func deviceReal() {
        _ = inbox.takeEvents()
        _ = inbox.takeRemovals()
        let rebuildsBefore = engine.diagnostics.deviceRebuilds
        engine.stop()
        engine.play(in: score)
        report.note(
            "device",
            "switch the default output device now (Set-AudioDevice between Speakers and Remote Audio, or disable the "
                + "endpoint); listening for 30 s",
        )
        _ = waitUntil(timeout: 30) { engine.diagnostics.deviceRebuilds > rebuildsBefore && engine.state == .playing }
        wait(1)
        let diagnostics = engine.diagnostics
        let rebuilds = diagnostics.deviceRebuilds - rebuildsBefore
        report.check("device", "real switch rebuilt", rebuilds >= 1, value: "\(rebuilds)", limit: "≥ 1")
        report.check(
            "device", "real switch still playing", engine.state == .playing, value: "\(engine.state)", limit: "playing",
        )
        let rebuildSeconds = diagnostics.lastDeviceRebuildSeconds ?? .infinity
        report.check(
            "device", "real switch rebuild time", rebuildSeconds <= 0.5,
            value: "\(formatted(rebuildSeconds * 1000, 1)) ms", limit: "≤ 500 ms",
        )
        report.note("device", "events: \(inbox.takeEvents()), removals: \(inbox.takeRemovals())")
        engine.stop()
    }
}
