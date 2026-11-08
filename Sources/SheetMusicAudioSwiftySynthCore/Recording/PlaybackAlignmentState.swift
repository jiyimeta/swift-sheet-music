import SheetMusicAudioCore
import SwiftySynth

// Recordings and the speed table on a SwiftySynth transport — the Apple backend's and Android's `HostedSynth`'s.
//
// The score's SMF stays loaded at its notated tempo: SwiftySynth cannot replace or reposition it without
// `Synthesizer.reset()` (both `MidiFileSequencer.play` and `seek` call it, which kills every voice), so an alignment
// is a table, never a reload. At every sequencer block start the render sets the transports' speed to the user's
// rate × the table's stretch, and each recording is read at the warped second the same table gives for the
// transport's position — so the recordings, the synthesized parts and the click run off one clock in one render call
// and cannot drift apart. A new alignment is a table swap under the host's lock that applies from the next block (P1,
// measured 10-29).

/// One recording as the render thread reads it. `recording` keeps the mapping behind `frames` alive.
package struct RenderedRecording {
    package let id: String
    package let recording: MappedRecording
    package let frames: PCMFrames
    package let offsetSeconds: Double
    /// The gain the engine resolved. What a frame is scaled by is `gainRamp`'s, which heads for this one.
    package let gain: Float
    package var playhead = RecordingPlayhead()
    package var gainRamp: RecordingGainRamp
}

extension RenderedRecording {
    /// A track as the host described it, its playhead at rest and its gain where it is headed.
    package init(_ track: RecordingTrackRender) {
        self.init(
            id: track.id, recording: track.recording, frames: track.recording.frames,
            offsetSeconds: track.offsetSeconds, gain: track.gain, gainRamp: RecordingGainRamp(gain: track.gain),
        )
    }
}

/// The alignment the transport follows, the recordings mixed on it, and the render thread's bookkeeping. Lives inside
/// the host's lock (the Apple backend's `Shared`, `HostedSynth`'s own), so it is touched only under it; every array in
/// it is built off the render thread and swapped in whole (`RecordingMixController`), so the render thread allocates
/// nothing.
package struct PlaybackAlignmentState {
    package var tracks: [RenderedRecording] = []
    /// The tracks grouped by transposition and table, each with the stretcher pair it is read through when the rate is
    /// not 100 % or its transposition is not 0 (`RecordingRender+Stretch.swift`).
    package var groups: [RecordingStretchGroup] = []
    /// The stretched reading's buffers, sized off the render thread for every pair in `groups`.
    package var stretchScratch: StretchScratch?
    package var speedTable = TransportSpeedTable(warp: nil)
    /// The shared table: what every group without a table of its own plays (`RecordingStretchGroup.schedule`).
    package var schedule = RecordingSchedule(segments: [])
    /// The host's rate. The render sets the transports to it × the table's stretch at every block start.
    package var userSpeed: Double = 1
    /// The metronome's speed for a count-in started under a warp — the speed of the measure it counts into, fixed for
    /// the length of the count. Nil for a count-in started without one, which keeps the user's rate as it always did.
    package var countInSpeed: Double?
    /// Frames already rendered into the score sequencer's current block (0 = the next body frame starts a block): a
    /// mirror of `MidiFileSequencer`'s private `blockWrote`, kept so speeds are decided on block starts, where the
    /// sequencer applies them.
    package var blockPhase = 0
    /// The speed the score sequencer advanced its current block at. A rate change between render calls reaches the
    /// sequencer only at its next block start, so the rest of a block keeps this speed.
    package var blockSpeed: Double = 1

    package init() {}

    /// The score sequencer was (re)loaded or sought: either re-primes its block, so its position is the next frame's.
    package mutating func sequencerRepositioned() {
        blockPhase = 0
    }

    /// The recordings are not mixed for a while (a pause, a stop, a load, a count-in, a paused buffer): the next frame
    /// that mixes them fades them in, at the gain each is headed for.
    package mutating func silenceRecordings() {
        for index in tracks.indices {
            tracks[index].playhead.reset()
            let gain = tracks[index].gain
            tracks[index].gainRamp.settle(at: gain)
        }
        for index in groups.indices {
            groups[index].state.silence()
        }
    }

    /// Whether group `index` is read through its stretcher now: it is in the track list (not draining), it has a pair,
    /// the rate or its transposition needs one, and a seek at this rate fits the scratch (past the sized rate it is
    /// read directly).
    package func readsThroughStretcher(group index: Int) -> Bool {
        guard groups[index].drainTracks == nil, let pair = groups[index].pair, let stretchScratch,
              userSpeed != 1 || groups[index].transposeSemitones != 0
        else { return false }
        return pair.first.seekLength(rate: userSpeed) <= stretchScratch.inputCapacity
    }

    /// The exact transport second of the next body frame. `MidiFileSequencer.position` advances once per block, at
    /// the block's start, so mid-block it reads the block's end; the frames left in the block come off at the speed
    /// the block was advanced at. Exact after any reposition, as `play` and `seek` re-prime the block.
    package func transportSeconds(quantized: Double, sampleRate: Double, blockSize: Int) -> Double {
        guard blockPhase != 0 else { return quantized }
        return quantized - Double(blockSize - blockPhase) * blockSpeed / sampleRate
    }

    /// `transportSeconds(quantized:sampleRate:blockSize:)` for where `sequencer` stands.
    package func transportSeconds(of sequencer: MidiFileSequencer, sampleRate: Double) -> Double {
        let position = sequencer.position.components
        return transportSeconds(
            quantized: Double(position.seconds) + Double(position.attoseconds) * 1e-18,
            sampleRate: sampleRate, blockSize: sequencer.synthesizer.blockSize,
        )
    }

    /// The transport speed for a block whose middle is at transport second `seconds`: the user's rate stretched by the
    /// alignment, floored as a rate is floored (`MidiFileSequencer.speed` must be positive).
    package func speed(atTransport seconds: Double) -> Double {
        max(0.01, userSpeed * speedTable.stretch(atTransport: seconds))
    }

    /// How many frames to render before the speed may need to change. A chunk that starts mid-block ends with the
    /// block, so the next one starts where the sequencer applies a speed. From a block start: whole blocks up to about
    /// a block before the next span boundary, then one block at a time, so each block's speed is chosen by where its
    /// middle falls.
    package func framesBeforeSpeedDecision(
        at seconds: Double, speed: Double, sampleRate: Double, blockSize: Int, limit: Int,
    ) -> Int {
        let toBlockEnd = blockSize - blockPhase
        guard blockPhase == 0 else { return min(limit, toBlockEnd) }
        guard let boundary = speedTable.nextBoundary(after: seconds) else { return limit }
        let framesToBoundary = (boundary - seconds) * sampleRate / speed
        guard framesToBoundary.isFinite, framesToBoundary < Double(limit + 2 * blockSize) else { return limit }
        let frames = Int(framesToBoundary.rounded(.up))
        guard frames > toBlockEnd + blockSize else { return min(limit, toBlockEnd) }
        let wholeBlocks = (frames - toBlockEnd) / blockSize - 1
        return min(limit, toBlockEnd + wholeBlocks * blockSize)
    }

    /// `frames` body frames were rendered.
    package mutating func advance(frames: Int, blockSize: Int) {
        blockPhase = (blockPhase + frames) % max(1, blockSize)
    }
}

// MARK: - The body, chunk by chunk

/// One chunk of a playing buffer's body: frames rendered at one speed, so the transports' speed can follow the speed
/// table (`PlaybackAlignmentState.beginBodyChunk`).
package struct BodyChunk {
    /// Frames in the chunk, at least 1.
    package let frames: Int
    /// The transport second of its first frame.
    package let transportStart: Double
    /// The speed its frames advance the transport at.
    package let speed: Double
    /// The speed decided at the block start this chunk begins on, which the host also gives its metronome transport;
    /// nil for a chunk that starts mid-block.
    package let decidedSpeed: Double?
}

extension PlaybackAlignmentState {
    /// Starts the next chunk of a playing buffer's body, `limit` frames at most: at a sequencer block start, sets
    /// `sequencer`'s speed to the user's rate × the stretch where the block's middle falls. Without a warp the speed
    /// never changes, and the chunks (one, or two when the buffer starts mid-block) render sample for sample what one
    /// render call would. The host renders its metronome at `decidedSpeed` alongside. Allocation-free.
    package mutating func beginBodyChunk(sequencer: MidiFileSequencer, sampleRate: Double, limit: Int) -> BodyChunk {
        let blockSize = sequencer.synthesizer.blockSize
        let now = transportSeconds(of: sequencer, sampleRate: sampleRate)
        var decided: Double?
        if blockPhase == 0 {
            let middle = now + Double(blockSize) / 2 * sequencer.speed / sampleRate
            let speed = speed(atTransport: middle)
            if sequencer.speed != speed { sequencer.speed = speed }
            blockSpeed = speed
            decided = speed
        }
        let speed = blockSpeed
        let frames = max(1, framesBeforeSpeedDecision(
            at: now, speed: speed, sampleRate: sampleRate, blockSize: blockSize, limit: limit,
        ))
        return BodyChunk(frames: frames, transportStart: now, speed: speed, decidedSpeed: decided)
    }

    /// Renders `chunk` into `left` / `right` (`chunk.frames` long): the score transport advances and renders, the
    /// recordings are mixed in on its clock, and the block bookkeeping moves on. Allocation-free.
    package mutating func renderBodyChunk(
        _ chunk: BodyChunk, sequencer: MidiFileSequencer,
        into left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>, sampleRate: Double,
    ) {
        // Advance the score transport, dispatch due events, render.
        sequencer.render(left: left, right: right)
        RecordingRender.mixRecordings(
            into: left, right, transportStart: chunk.transportStart, transportPerFrame: chunk.speed / sampleRate,
            sampleRate: sampleRate, alignment: &self,
        )
        advance(frames: chunk.frames, blockSize: sequencer.synthesizer.blockSize)
    }
}

/// The speed table and the shared schedule a new alignment brings, laid out off the render thread.
package struct AlignmentTables {
    package var speedTable: TransportSpeedTable
    package var schedule: RecordingSchedule

    package init(speedTable: TransportSpeedTable, schedule: RecordingSchedule) {
        self.speedTable = speedTable
        self.schedule = schedule
    }

    /// Inside the lock: trades these for the ones `alignment` holds, which come back here to be released after it.
    package mutating func swap(into alignment: inout PlaybackAlignmentState) {
        Swift.swap(&speedTable, &alignment.speedTable)
        Swift.swap(&schedule, &alignment.schedule)
    }
}

/// Where one chunk of the body sits on the warped clock. Inside one stretch the warped second is linear in the frame;
/// a chunk that crosses a span boundary is looked up per frame, because there the transport moves at its block's one
/// speed while the table's stretch changes mid-block — a linear guess would land the next chunk a few frames off,
/// which the playhead would hear as a jump.
package struct ChunkClock {
    /// Transport seconds of the chunk's first frame, and per frame.
    package let transportStart: Double
    package let transportPerFrame: Double
    /// Warped seconds of the chunk's first frame, and per frame inside one stretch.
    package let outputStart: Double
    package let outputPerFrame: Double
    package let crossesBoundary: Bool

    package init(transportStart: Double, transportPerFrame: Double, frames: Int, table: TransportSpeedTable) {
        self.transportStart = transportStart
        self.transportPerFrame = transportPerFrame
        outputStart = table.outputSeconds(atTransport: transportStart)
        outputPerFrame = transportPerFrame / table.stretch(atTransport: transportStart)
        let transportEnd = transportStart + Double(frames) * transportPerFrame
        if let boundary = table.nextBoundary(after: transportStart) {
            crossesBoundary = boundary < transportEnd
        } else {
            crossesBoundary = false
        }
    }

    package func outputSeconds(atFrame frame: Int, table: TransportSpeedTable) -> Double {
        guard crossesBoundary else { return outputStart + Double(frame) * outputPerFrame }
        return table.outputSeconds(atTransport: transportStart + Double(frame) * transportPerFrame)
    }
}
