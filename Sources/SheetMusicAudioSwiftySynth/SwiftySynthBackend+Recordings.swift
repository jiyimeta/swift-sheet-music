import SheetMusicAudioApple
import SheetMusicAudioCore
import SwiftySynth

// Recordings and the speed table on the SwiftySynth transport.
//
// The score's SMF stays loaded at its notated tempo: SwiftySynth cannot replace or reposition it without
// `Synthesizer.reset()` (both `MidiFileSequencer.play` and `seek` call it, which kills every voice), so an alignment
// is a table, never a reload. At every sequencer block start the render sets both transports' speed to the user's
// rate × the table's stretch, and each recording is read at the warped second the same table gives for the
// transport's position — so the recordings, the synthesized parts and the click run off one clock in one render call
// and cannot drift apart. A new alignment is a table swap under the lock that applies from the next block (P1,
// measured 10-29).

/// One recording as the render thread reads it. `recording` keeps the mapping behind `frames` alive.
struct RenderedRecording {
    let id: String
    let recording: MappedRecording
    let frames: PCMFrames
    let offsetSeconds: Double
    let gain: Float
    var playhead = RecordingPlayhead()
}

/// The alignment the transport follows, the recordings mixed on it, and the render thread's bookkeeping. Lives in
/// `SwiftySynthBackend.Shared`, so it is touched only under the backend's lock; every array in it is built on the main
/// actor and swapped in whole, so the render thread allocates nothing.
struct PlaybackAlignmentState {
    var tracks: [RenderedRecording] = []
    /// The tracks grouped by transposition, each with the stretcher pair it is read through when the rate is not 100 %
    /// or its transposition is not 0 (`SwiftySynthBackend+Stretch.swift`).
    var groups: [RecordingStretchGroup] = []
    /// The stretched reading's buffers, sized on the main actor for every pair in `groups`.
    var stretchScratch: StretchScratch?
    var speedTable = TransportSpeedTable(warp: nil)
    var schedule = RecordingSchedule(segments: [])
    /// Whether `speedTable` holds a span; a nil or empty warp is the identity.
    var hasWarp = false
    /// The host's rate (`setRate`). The render sets both transports to it × the table's stretch at every block start.
    var userSpeed: Double = 1
    /// The metronome's speed for a count-in started under a warp — the speed of the measure it counts into, fixed for
    /// the length of the count. Nil for a count-in started without one, which keeps the user's rate as it always did.
    var countInSpeed: Double?
    /// Frames already rendered into the score sequencer's current block (0 = the next body frame starts a block): a
    /// mirror of `MidiFileSequencer`'s private `blockWrote`, kept so speeds are decided on block starts, where the
    /// sequencer applies them.
    var blockPhase = 0
    /// The speed the score sequencer advanced its current block at. A rate change between render calls reaches the
    /// sequencer only at its next block start, so the rest of a block keeps this speed.
    var blockSpeed: Double = 1

    /// The score sequencer was (re)loaded or sought: either re-primes its block, so its position is the next frame's.
    mutating func sequencerRepositioned() {
        blockPhase = 0
    }

    /// The recordings are not mixed for a while (a pause, a stop, a load, a count-in, a paused buffer): the next frame
    /// that mixes them fades them in.
    mutating func silenceRecordings() {
        for index in tracks.indices {
            tracks[index].playhead.reset()
        }
        for index in groups.indices {
            groups[index].state.silence()
        }
    }

    /// Whether group `index` is read through its stretcher now: it has a pair, the rate or its transposition needs one,
    /// and a seek at this rate fits the scratch (past the sized rate it is read directly).
    func readsThroughStretcher(group index: Int) -> Bool {
        guard let pair = groups[index].pair, let stretchScratch,
              userSpeed != 1 || groups[index].transposeSemitones != 0
        else { return false }
        return pair.first.seekLength(rate: userSpeed) <= stretchScratch.inputCapacity
    }

    /// The exact transport second of the next body frame. `MidiFileSequencer.position` advances once per block, at
    /// the block's start, so mid-block it reads the block's end; the frames left in the block come off at the speed
    /// the block was advanced at. Exact after any reposition, as `play` and `seek` re-prime the block.
    func transportSeconds(quantized: Double, sampleRate: Double, blockSize: Int) -> Double {
        guard blockPhase != 0 else { return quantized }
        return quantized - Double(blockSize - blockPhase) * blockSpeed / sampleRate
    }

    /// The transport speed for a block whose middle is at transport second `seconds`: the user's rate stretched by the
    /// alignment, floored as `setRate` floors it (`MidiFileSequencer.speed` must be positive).
    func speed(atTransport seconds: Double) -> Double {
        max(0.01, userSpeed * speedTable.stretch(atTransport: seconds))
    }

    /// How many frames to render before the speed may need to change. A chunk that starts mid-block ends with the
    /// block, so the next one starts where the sequencer applies a speed. From a block start: whole blocks up to about
    /// a block before the next span boundary, then one block at a time, so each block's speed is chosen by where its
    /// middle falls.
    func framesBeforeSpeedDecision(
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
    mutating func advance(frames: Int, blockSize: Int) {
        blockPhase = (blockPhase + frames) % max(1, blockSize)
    }
}

/// Where one chunk of the body sits on the warped clock. Inside one stretch the warped second is linear in the frame;
/// a chunk that crosses a span boundary is looked up per frame, because there the transport moves at its block's one
/// speed while the table's stretch changes mid-block — a linear guess would land the next chunk a few frames off,
/// which the playhead would hear as a jump.
struct ChunkClock {
    /// Transport seconds of the chunk's first frame, and per frame.
    let transportStart: Double
    let transportPerFrame: Double
    /// Warped seconds of the chunk's first frame, and per frame inside one stretch.
    let outputStart: Double
    let outputPerFrame: Double
    let crossesBoundary: Bool

    init(transportStart: Double, transportPerFrame: Double, frames: Int, table: TransportSpeedTable) {
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

    func outputSeconds(atFrame frame: Int, table: TransportSpeedTable) -> Double {
        guard crossesBoundary else { return outputStart + Double(frame) * outputPerFrame }
        return table.outputSeconds(atTransport: transportStart + Double(frame) * transportPerFrame)
    }
}

extension SwiftySynthBackend {
    // MARK: Render thread

    /// The crossfade on a jump of a recording's read position, and its fade-in after silence (P1's value).
    nonisolated static let recordingFadeSeconds = 0.005

    /// Add every recording to one chunk of the body, whose first frame is at transport second `transportStart` and
    /// whose frames each advance the transport by `transportPerFrame`. The speed table turns each frame's transport
    /// second into a warped one, where the schedule says what each track plays. A group at 100 % and no transposition
    /// is read directly, track by track; any other is read through its stretcher. A switch between the two is a jump:
    /// the reading switched from fades out while the other fades in. Allocation-free.
    nonisolated static func mixRecordings(
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        transportStart: Double,
        transportPerFrame: Double,
        sampleRate: Double,
        alignment: inout PlaybackAlignmentState,
    ) {
        guard !left.isEmpty, !alignment.tracks.isEmpty else { return }
        let clock = ChunkClock(
            transportStart: transportStart, transportPerFrame: transportPerFrame,
            frames: left.count, table: alignment.speedTable,
        )
        let fadeFrames = max(1, Int((recordingFadeSeconds * sampleRate).rounded()))
        for group in alignment.groups.indices {
            let stretched = alignment.readsThroughStretcher(group: group)
            for index in alignment.groups[group].trackIndices {
                if stretched {
                    fadeOutTrack(
                        &alignment.tracks[index], into: left, right, clock: clock,
                        table: alignment.speedTable, fadeFrames: fadeFrames,
                    )
                } else {
                    mixTrack(
                        &alignment.tracks[index], into: left, right, clock: clock,
                        table: alignment.speedTable, schedule: alignment.schedule, fadeFrames: fadeFrames,
                    )
                }
            }
            mixStretchGroup(
                group, playing: stretched, into: left, right, clock: clock,
                sampleRate: sampleRate, fadeFrames: fadeFrames, alignment: &alignment,
            )
        }
    }

    /// A track whose group is read through its stretcher: its direct reading fades out from where it was, then is
    /// skipped.
    nonisolated static func fadeOutTrack(
        _ track: inout RenderedRecording,
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        clock: ChunkClock,
        table: TransportSpeedTable,
        fadeFrames: Int,
    ) {
        guard !track.playhead.isSilent else { return }
        let frames = track.frames
        let rate = frames.sampleRate
        let gain = track.gain
        var playhead = track.playhead
        var output = clock.outputSeconds(atFrame: 0, table: table)
        for frame in 0 ..< left.count where !playhead.isSilent {
            let next = clock.outputSeconds(atFrame: frame + 1, table: table)
            let step = (next - output) * rate
            let sample = playhead.render(target: nil, step: step, from: frames, fadeFrames: fadeFrames)
            left[frame] += gain * sample.left
            right[frame] += gain * sample.right
            output = next
        }
        track.playhead = playhead
    }

    /// One track over one chunk: per frame, the warped second → the track file's second (nil = silence) → its frame,
    /// read by the playhead, which crossfades a jump and fades in after silence, and scaled by the track's gain.
    nonisolated static func mixTrack(
        _ track: inout RenderedRecording,
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        clock: ChunkClock,
        table: TransportSpeedTable,
        schedule: RecordingSchedule,
        fadeFrames: Int,
    ) {
        let frames = track.frames
        let rate = frames.sampleRate
        let gain = track.gain
        let offset = track.offsetSeconds
        var playhead = track.playhead
        var output = clock.outputSeconds(atFrame: 0, table: table)
        for frame in 0 ..< left.count {
            let next = clock.outputSeconds(atFrame: frame + 1, table: table)
            let source = schedule.sourceSeconds(atOutput: output, offset: offset)
            let target: Double? = if let source { source * rate } else { nil }
            let sample = playhead.render(
                target: target, step: (next - output) * rate, from: frames, fadeFrames: fadeFrames,
            )
            left[frame] += gain * sample.left
            right[frame] += gain * sample.right
            output = next
        }
        track.playhead = playhead
    }

    // MARK: SynthBackend

    public var canPlayRecordings: Bool {
        true
    }

    /// Replaces the recordings in one lock section. A track whose `id` was already playing keeps its playhead, so a new
    /// gain neither fades nor jumps it; a group whose transposition was already playing keeps its stretchers and where
    /// they are, and a group whose transposition changed carries on from its first track's old group and crossfades to
    /// a retuned stretcher. Stretchers a group now needs are made here, on the main actor. The previous arrays,
    /// stretchers and scratch are released after the lock, never on the render thread.
    public func setRecordingTracks(_ tracks: [RecordingTrackRender]) {
        var incoming = tracks.map { track in
            RenderedRecording(
                id: track.id, recording: track.recording, frames: track.recording.frames,
                offsetSeconds: track.offsetSeconds, gain: track.gain,
            )
        }
        let plan = RecordingGroupPlan.make(tracks: tracks, previous: recordingGroupLayout)
        var layouts = plan.map { group in
            RecordingGroupLayout(
                transposeSemitones: group.transposeSemitones,
                trackIDs: group.trackIndices.map { tracks[$0].id },
                pair: group.continues.flatMap { recordingGroupLayout[$0].pair },
            )
        }
        var scratch = stretchScratchIfNeeded(capacity: makeMissingPairs(in: &layouts))
        var groups = plan.indices.map { index in
            RecordingStretchGroup(
                transposeSemitones: plan[index].transposeSemitones, trackIndices: plan[index].trackIndices,
                pair: layouts[index].pair,
            )
        }
        lock.withLockUnchecked { shared in
            for index in incoming.indices {
                let id = incoming[index].id
                if let playing = shared.alignment.tracks.first(where: { $0.id == id }) {
                    incoming[index].playhead = playing.playhead
                }
            }
            for index in groups.indices {
                guard let previous = plan[index].continues, shared.alignment.groups.indices.contains(previous)
                else { continue }
                groups[index].state = shared.alignment.groups[previous].state
                if shared.alignment.groups[previous].transposeSemitones != groups[index].transposeSemitones {
                    groups[index].state.needsRetune = true
                }
            }
            swap(&shared.alignment.tracks, &incoming)
            swap(&shared.alignment.groups, &groups)
            if scratch != nil { swap(&shared.alignment.stretchScratch, &scratch) }
        }
        recordingGroupLayout = layouts
    }

    // MARK: Stretchers (main actor)

    /// Whether a group of this transposition is read through a stretcher at the current rate.
    func needsStretcher(transposeSemitones: Double) -> Bool {
        rate != 1 || transposeSemitones != 0
    }

    /// Gives every group that needs a stretcher and has none a new pair from the factory (none without a factory), and
    /// returns the scratch input capacity the new pairs need. Only a new pair is asked: one already handed to the
    /// render thread is the render thread's to call.
    func makeMissingPairs(in layouts: inout [RecordingGroupLayout]) -> Int {
        guard let stretcherFactory else { return 0 }
        var capacity = 0
        for index in layouts.indices where layouts[index].pair == nil {
            guard needsStretcher(transposeSemitones: layouts[index].transposeSemitones) else { continue }
            let pair = StretcherPair(factory: stretcherFactory, sampleRate: sampleRate)
            capacity = max(capacity, StretchScratch.inputCapacity(for: pair.first))
            layouts[index].pair = pair
        }
        return capacity
    }

    /// A scratch of `capacity` when the installed one is smaller; nil when it is big enough.
    func stretchScratchIfNeeded(capacity: Int) -> StretchScratch? {
        guard capacity > stretchScratchCapacity else { return nil }
        stretchScratchCapacity = capacity
        return StretchScratch(inputCapacity: capacity)
    }

    /// Before a rate change reaches the render: pairs for the groups that need one at `rate` and lack it, with the
    /// scratch they need. `installStretchers` hands them over inside the lock section.
    func stretchersForRate() -> (pairs: [(group: Int, pair: StretcherPair)], scratch: StretchScratch?) {
        var layouts = recordingGroupLayout
        let capacity = makeMissingPairs(in: &layouts)
        var made: [(group: Int, pair: StretcherPair)] = []
        for index in layouts.indices where recordingGroupLayout[index].pair == nil {
            if let pair = layouts[index].pair { made.append((index, pair)) }
        }
        recordingGroupLayout = layouts
        return (made, stretchScratchIfNeeded(capacity: capacity))
    }

    /// Inside the lock: installs what `stretchersForRate` made. The swapped-out scratch comes back in `scratch`, to be
    /// released after the lock.
    nonisolated static func installStretchers(
        _ pairs: [(group: Int, pair: StretcherPair)], scratch: inout StretchScratch?, into shared: inout Shared,
    ) {
        for (group, pair) in pairs where shared.alignment.groups.indices.contains(group) {
            shared.alignment.groups[group].pair = pair
        }
        if scratch != nil { swap(&shared.alignment.stretchScratch, &scratch) }
    }

    /// Swaps the speed table and the schedule together in one lock section: the next render call sees either the old
    /// pair or the new one, and the transport takes the new speed from its next block — no stop, seek or reload. The
    /// previous table and schedule are released after the lock, never on the render thread.
    public func setPlaybackAlignment(warp: PlaybackTimeWarp?, segments: [RecordingSegment]) {
        var table = TransportSpeedTable(warp: warp)
        var schedule = RecordingSchedule(segments: segments)
        let hasWarp = !(warp?.spans.isEmpty ?? true)
        lock.withLockUnchecked { shared in
            swap(&shared.alignment.speedTable, &table)
            swap(&shared.alignment.schedule, &schedule)
            shared.alignment.hasWarp = hasWarp
        }
    }
}
