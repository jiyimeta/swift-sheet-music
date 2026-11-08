import SheetMusicAudioCore
import SheetMusicFoundation
import SwiftySynth

// Recordings and the speed table on a hosted score synth — what the Apple backend does in its render callback
// (`SwiftySynthBackend+Render.swift`), shaped for Android's engine, which pulls frames from its audio writer thread.
//
// The render state (`PlaybackAlignmentState`), the mix and the grouping are the Apple backend's own code
// (`Recording/`). The state lives under the synth's lock; the control side (`RecordingMixController`) under a second
// lock of its own, `recordingControlLock`, which a control call takes first and holds while the controller swaps its
// arrays in under the synth's lock. Lock order, always: `recordingControlLock` → this synth's lock → the metronome
// synth's lock. The render takes only the last two, in that order; no control call takes two synths' locks.

extension HostedSynth {
    // MARK: - Control

    /// What makes the stretchers the recordings are read through when the rate is not 100 % or a track is transposed.
    /// Nil (the default): recordings are read directly at any rate and their transposition is ignored. Set it before
    /// the first track list.
    public func setRecordingStretcherFactory(_ factory: RecordingStretcherFactory?) {
        recordingControlLock.withLock { recordingMix.stretcherFactory = factory }
    }

    /// Replaces the recordings mixed onto this synth's sequence, as `SwiftySynthBackend.setRecordingTracks` does: a
    /// track whose `id` was already playing carries on from where it is, and its new gain is ramped to. Callable while
    /// playing; nothing it releases is released on the render thread.
    public func setRecordingTracks(_ tracks: [RecordingTrackRender]) {
        recordingControlLock.withLock {
            recordingMix.setRecordingTracks(tracks, withAlignment: withAlignment)
        }
    }

    /// The alignment the transport and the recordings follow, as `SwiftySynthBackend.setPlaybackAlignment` takes it:
    /// a table swap that applies from the next synthesizer block, never a stop, a seek or a reload.
    public func setPlaybackAlignment(
        warp: PlaybackTimeWarp?, segments: [RecordingSegment], trackSegments: [String: [RecordingSegment]] = [:],
    ) {
        recordingControlLock.withLock {
            recordingMix.setPlaybackAlignment(
                warp: warp, segments: segments, trackSegments: trackSegments, withAlignment: withAlignment,
            )
        }
    }

    /// `RecordingMixController`'s lock section.
    func withAlignment(_ body: (inout PlaybackAlignmentState) -> Void) {
        lock.withLock { body(&alignment) }
    }

    /// `HostedSequence.setSpeed`: the user's rate, which the render stretches by the alignment at every block start.
    /// The stretcher pairs a rate away from 100 % needs are made first, outside the synth's lock, and installed in the
    /// section that sets it.
    func setSequenceSpeed(_ id: Int, speed: Double) {
        let speed = max(0.01, speed.isFinite ? speed : 1)
        recordingControlLock.withLock {
            recordingMix.rate = Float(speed)
            var stretchers = recordingMix.stretchersForRate()
            lock.withLock {
                stretchers.install(into: &alignment)
                guard !isClosed, let current = attached, current.id == id else { return }
                current.sequencer.speed = speed
                alignment.userSpeed = speed
            }
        }
    }

    // MARK: - Clock

    /// The exact transport second the attached sequence stands at (its SMF's seconds); 0 without one. Exact between
    /// blocks only while the host renders through `renderMix`, which keeps the block bookkeeping.
    public var currentTransportSeconds: Double {
        lock.withLock { transportSecondsHoldingLock() }
    }

    /// The warped second — the recording's time at 100 % — of transport second `seconds`; the identity without a warp.
    public func outputSeconds(atTransport seconds: Double) -> Double {
        lock.withLock { alignment.speedTable.outputSeconds(atTransport: seconds) }
    }

    /// The transport second of warped second `seconds`; the inverse of `outputSeconds(atTransport:)`.
    public func transportSeconds(atOutput seconds: Double) -> Double {
        lock.withLock { alignment.speedTable.transportSeconds(atOutput: seconds) }
    }

    /// How the sequence this synth plays — the score's, repeats and jumps played out — lies over the score's notated
    /// timeline, as `SwiftySynthBackend.setUnrolledTimeMap` takes it: what `notatedSeconds(atOutput:)` and
    /// `outputSeconds(atNotated:)` read. Set it when a sequence rendered from another score is attached; until then the
    /// identity, which is right for a score without a repeat plan.
    public func setUnrolledTimeMap(_ map: UnrolledTimeMap) {
        lock.withLock { unrolledTimeMap = map }
    }

    /// The notated second — the score's own timeline, repeats folded — that warped second `seconds` stands for
    /// (`TransportSpeedTable.notatedSeconds(atOutput:unrolled:)`, the rule Apple's
    /// `PlaybackEngine.notatedSeconds(forReportedSeconds:)` reads under an alignment). Through the identity warp and
    /// map, the identity.
    public func notatedSeconds(atOutput seconds: Double) -> Double {
        lock.withLock { alignment.speedTable.notatedSeconds(atOutput: seconds, unrolled: unrolledTimeMap) }
    }

    /// The warped second at which notated second `seconds` plays, at its first occurrence: the inverse of
    /// `notatedSeconds(atOutput:)`, as `PlaybackEngine.reportedSeconds(forNotatedSeconds:)` has it.
    public func outputSeconds(atNotated seconds: Double) -> Double {
        lock.withLock { alignment.speedTable.outputSeconds(atNotated: seconds, unrolled: unrolledTimeMap) }
    }

    /// The attached sequence's second at `tick`, on its own tempo map; 0 without one.
    public func transportSeconds(atTick tick: Int) -> Double {
        lock.withLock { attached.map { max(0, $0.tempoMap.seconds(atTick: Double(tick))) } ?? 0 }
    }

    /// The attached sequence's tick at its second `seconds`, rounded to the nearest; 0 without one.
    public func tick(atTransportSeconds seconds: Double) -> Int {
        lock.withLock {
            guard let attached, seconds.isFinite else { return 0 }
            return max(0, Int(attached.tempoMap.tick(atSeconds: max(0, seconds)).rounded()))
        }
    }

    /// How a count-in of `seconds` (its metronome SMF's own length) plays into the body the sequence is parked before
    /// — `TransportSpeedTable.countIn(seconds:userSpeed:bodyStart:)`, the rule the Apple backend reads. Under a warp
    /// the count runs at the speed of the measure it counts into, `speed`, for its whole length; without one `speed`
    /// is nil and the count keeps the user's rate. `duration` is how long the score must wait.
    public func countIn(seconds: Double) -> (duration: Double, speed: Double?) {
        lock.withLock {
            var bodyStart = 0.0
            if let attached {
                // A seek parks a quarter tick early (`HostedSequence.parkTicks`); the body starts on the onset.
                let tick = attached.tempoMap.tick(atSeconds: transportSecondsHoldingLock()).rounded()
                bodyStart = max(0, attached.tempoMap.seconds(atTick: tick))
            }
            let countIn = alignment.speedTable.countIn(
                seconds: seconds, userSpeed: alignment.userSpeed, bodyStart: bodyStart,
            )
            alignment.countInSpeed = countIn.speed
            return countIn
        }
    }

    /// Asks for the pages each recording plays over the next couple of seconds to be read in, from where the transport
    /// is and, when given, from `loopStartTransportSeconds`, where a loop wrap lands (`MappedRecording.prefetch`).
    /// Advice, and off the render thread: call it after a play, a seek or a loop wrap and every few cursor polls.
    public func prefetchRecordings(loopStartTransportSeconds: Double?) {
        let (now, table, shared, rate) = lock.withLock {
            (transportSecondsHoldingLock(), alignment.speedTable, alignment.schedule, alignment.userSpeed)
        }
        recordingControlLock.withLock {
            let tracks = recordingMix.recordingTracks
            guard !tracks.isEmpty else { return }
            let own = recordingMix.recordingTrackSegments.mapValues { RecordingSchedule(segments: $0) }
            let origins = [now] + (loopStartTransportSeconds.map { [$0] } ?? [])
            for track in tracks {
                let reading = RecordingPrefetch.schedule(
                    forTrack: track.id, offsetSeconds: track.offsetSeconds, shared: shared, own: own,
                )
                for origin in origins {
                    let ranges = RecordingPrefetch.ranges(
                        transportSeconds: origin, rate: rate, table: table, schedule: reading.schedule,
                        offset: reading.offset,
                    )
                    for seconds in ranges {
                        track.recording.prefetch(seconds: seconds)
                    }
                }
            }
        }
    }

    func transportSecondsHoldingLock() -> Double {
        guard let attached else { return 0 }
        return alignment.transportSeconds(of: attached.sequencer, sampleRate: Double(sampleRate))
    }

    // MARK: - Render

    /// Renders `frames` frames of the score into `left` / `right` with the recordings mixed in, and of `metronome` into
    /// `metronomeLeft` / `metronomeRight` — which stay apart so the host keeps the metronome's gain and the final sum
    /// — taking this synth's lock and then the metronome's. While the sequence plays the body runs in chunks, as the
    /// Apple backend's does: the score's speed and the metronome's follow the speed table from each block start, and
    /// the recordings are read on the score's clock. While it does not, the synth renders alone (previews, release
    /// tails) and the recordings are silent, fading in when it plays again. With `metronomeAudible` false the metronome
    /// is not rendered (its transport freezes, as the host's mix always had it) and its buffers come back zeroed.
    /// Allocation-free.
    public func renderMix(
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
        metronome: HostedSynth?, metronomeLeft: UnsafeMutablePointer<Float>,
        metronomeRight: UnsafeMutablePointer<Float>, metronomeAudible: Bool, frames: Int,
    ) {
        withMixLocks(metronome: metronome) {
            renderMixHoldingLocks(
                left: left, right: right, metronome: metronome, metronomeLeft: metronomeLeft,
                metronomeRight: metronomeRight, metronomeAudible: metronomeAudible, frames: frames,
            )
        }
    }

    /// Runs `body` holding this synth's lock and then `metronome`'s — for a caller that must pin its buffers only once
    /// both are held (JNI), so it never waits on a control call with them pinned.
    public func withMixLocks<R>(metronome: HostedSynth?, _ body: () throws -> R) rethrows -> R {
        try lock.withLock {
            guard let metronome, metronome !== self else { return try body() }
            return try metronome.lock.withLock(body)
        }
    }

    /// `renderMix` for a caller already inside `withMixLocks`.
    public func renderMixHoldingLocks(
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>,
        metronome: HostedSynth?, metronomeLeft: UnsafeMutablePointer<Float>,
        metronomeRight: UnsafeMutablePointer<Float>, metronomeAudible: Bool, frames: Int,
    ) {
        guard frames > 0 else { return }
        let metronome = metronome === self ? nil : metronome
        let clicks = metronomeAudible ? metronome : nil
        if clicks == nil {
            metronomeLeft.update(repeating: 0, count: frames)
            metronomeRight.update(repeating: 0, count: frames)
        }
        let leftBuffer = UnsafeMutableBufferPointer(start: left, count: frames)
        let rightBuffer = UnsafeMutableBufferPointer(start: right, count: frames)
        guard !isClosed, attached?.isPlaying == true, let sequencer = attached?.sequencer else {
            if isClosed {
                leftBuffer.update(repeating: 0)
                rightBuffer.update(repeating: 0)
            } else {
                synthesizer.render(left: leftBuffer, right: rightBuffer)
            }
            alignment.silenceRecordings()
            clicks?.renderHoldingLock(left: metronomeLeft, right: metronomeRight, frames: frames)
            return
        }
        let sampleRate = Double(sampleRate)
        var offset = 0
        while offset < frames {
            let chunk = alignment.beginBodyChunk(sequencer: sequencer, sampleRate: sampleRate, limit: frames - offset)
            if let speed = chunk.decidedSpeed { metronome?.setTransportSpeedHoldingLock(speed) }
            let chunkLeft = UnsafeMutableBufferPointer(rebasing: leftBuffer[offset ..< offset + chunk.frames])
            let chunkRight = UnsafeMutableBufferPointer(rebasing: rightBuffer[offset ..< offset + chunk.frames])
            alignment.renderBodyChunk(chunk, sequencer: sequencer, into: chunkLeft, chunkRight, sampleRate: sampleRate)
            clicks?.renderHoldingLock(
                left: metronomeLeft + offset, right: metronomeRight + offset, frames: chunk.frames,
            )
            offset += chunk.frames
        }
    }

    /// The metronome's side of a block start: its transport takes the score's speed, as the Apple backend sets both.
    func setTransportSpeedHoldingLock(_ speed: Double) {
        guard let sequencer = attached?.sequencer, sequencer.speed != speed else { return }
        sequencer.speed = speed
    }
}
