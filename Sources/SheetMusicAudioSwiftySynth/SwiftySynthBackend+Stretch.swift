import SheetMusicAudioCore

// A group's recordings read through its stretcher pair, on the render thread.
//
// The stretcher's input is the reference recording at the engine rate: reference frame x is every track of the group
// read at its own second `x / rate − offset`, scaled by its gain (ramped per input frame), and summed. Inside a
// segment the target — the reference frame the output should play now — advances `userRate` frames per output frame,
// and the stretcher is fed `userRate` input frames per output frame from
// `target + inputLatency + outputLatency × userRate` on, so its output lands on the target (`RecordingStretcher`). A
// discontinuity in the target — a cut between segments, a seek or loop wrap, silence beginning or ending, a retune —
// is a jump, handled as `RecordingPlayhead` handles one: the idle stretcher is primed at the new position and the
// output crossfades to it, while the one fading out is fed its continuation. Silence fades out and then nothing is fed.

/// One render call's view of a group's stretched reading: what it reads and the constants it reads them with.
struct StretchReader {
    let pair: StretcherPair
    let scratch: StretchScratch
    let tracks: [RenderedRecording]
    let trackIndices: [Int]
    let transposeSemitones: Double
    let rate: Double
    let sampleRate: Double
    /// `inputLatency + outputLatency × rate`: how far the input runs ahead of what the output plays.
    let lead: Double
    /// The most output frames one run covers: the scratch's, or fewer at a rate whose input would not fit.
    let runLimit: Int

    init(
        group: RecordingStretchGroup, pair: StretcherPair, scratch: StretchScratch, tracks: [RenderedRecording],
        rate: Double, sampleRate: Double,
    ) {
        self.pair = pair
        self.scratch = scratch
        self.tracks = tracks
        trackIndices = group.trackIndices
        transposeSemitones = group.transposeSemitones
        self.rate = rate
        self.sampleRate = sampleRate
        lead = Double(pair.first.inputLatency) + Double(pair.first.outputLatency) * rate
        let fitting = Int((Double(scratch.inputCapacity) - 2) / (rate * 1.5))
        runLimit = max(1, min(scratch.outputCapacity, fitting))
    }

    /// The reference frame the output should play at warped second `output`, or nil (silence) outside every segment.
    func target(atOutput output: Double, schedule: RecordingSchedule) -> Double? {
        if let seconds = schedule.sourceSeconds(atOutput: output, offset: 0) { seconds * sampleRate } else { nil }
    }

    /// A jump at the current frame: to `target` on the idle stretcher, primed there, or to silence. The stretcher that
    /// was playing fades out; a stretcher already fading out is dropped, unless the jump is from silence. `rampFrom` is
    /// how far this render call has moved the tracks' gain ramps (`fillInput`).
    func jump(to target: Double?, state: inout StretchGroupState, fadeFrames: Int, rampFrom: Int) {
        let fading = state.hasSource ? state.active : (state.fadeFramesRemaining > 0 ? state.fadingVoice : -1)
        if let target {
            let idle = 1 - state.active
            prime(idle, inputEnd: target + lead, rampFrom: rampFrom)
            state.setCursor(idle, target + lead)
            state.active = idle
            state.hasSource = true
            state.expected = target
            state.needsRestart = false
        } else {
            state.hasSource = false
        }
        state.fadingVoice = fading
        state.fadeFramesRemaining = fadeFrames
        state.fadingRemainder = 0
    }

    /// Restarts stretcher `voice` on the input that ends at reference frame `inputEnd`, retuned to the group. The input
    /// before the restart point is history, so each track's gain is held where its ramp stands.
    func prime(_ voice: Int, inputEnd: Double, rampFrom: Int) {
        let stretcher = pair[voice]
        let frames = stretcher.seekLength(rate: rate)
        fillInput(from: inputEnd - Double(frames), frames: frames, rampFrom: rampFrom, ramping: false)
        stretcher.reset()
        stretcher.setTransposeSemitones(transposeSemitones)
        stretcher.seek(left: scratch.inputLeft, right: scratch.inputRight, frames: frames, rate: rate)
    }

    /// One run of `count` output frames over which the target advanced `advance` reference frames to `expectedEnd`
    /// (nil when silent): the active stretcher is fed up to `expectedEnd + lead`, the fading one its continuation. Both
    /// read the gain ramps from `rampFrom` on. Returns how many input frames the active stretcher took, which is how
    /// far the ramps move.
    func feed(state: inout StretchGroupState, expectedEnd: Double?, advance: Double, count: Int, rampFrom: Int) -> Int {
        var fed = 0
        if state.hasSource, let expectedEnd {
            let voice = state.active
            let cursor = state.cursor(voice)
            // On target the run takes `advance` frames. A rate change moves the lead, and the difference is made up
            // within half the run again either way, so a tempo drag is followed without a jump.
            let wanted = (expectedEnd + lead - cursor).rounded()
            let low = (advance * 0.5).rounded(.down)
            let high = min((advance * 1.5).rounded(.up) + 2, Double(scratch.inputCapacity))
            fed = Int(min(max(wanted, low, 0), high))
            process(voice, from: cursor, inputFrames: fed, outputFrames: count, rampFrom: rampFrom)
            state.setCursor(voice, cursor + Double(fed))
            state.expected = expectedEnd
        }
        if state.fadingVoice >= 0, state.fadeFramesRemaining > 0 {
            let voice = state.fadingVoice
            let owed = advance + state.fadingRemainder
            let frames = Int(min(max(owed.rounded(), 0), Double(scratch.inputCapacity)))
            state.fadingRemainder = owed - Double(frames)
            process(voice, from: state.cursor(voice), inputFrames: frames, outputFrames: count, rampFrom: rampFrom)
            state.setCursor(voice, state.cursor(voice) + Double(frames))
        }
        return fed
    }

    /// Adds `count` frames of the stretchers' output at `offset`, crossfading while a fade runs. A run never outlasts a
    /// fade, so either every frame of it fades or none does.
    func mix(
        state: inout StretchGroupState, into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>, offset: Int, count: Int, fadeFrames: Int,
    ) {
        let fading = state.fadingVoice >= 0 && state.fadeFramesRemaining > 0 ? state.fadingVoice : -1
        let active = state.hasSource ? state.active : -1
        let fadingLeft = scratch.outputLeft(max(0, fading))
        let fadingRight = scratch.outputRight(max(0, fading))
        let activeLeft = scratch.outputLeft(max(0, active))
        let activeRight = scratch.outputRight(max(0, active))
        for frame in 0 ..< count {
            var weight: Float = 1
            if state.fadeFramesRemaining > 0 {
                weight = 1 - Float(state.fadeFramesRemaining) / Float(max(1, fadeFrames))
                state.fadeFramesRemaining -= 1
            }
            var sumLeft: Float = 0
            var sumRight: Float = 0
            if fading >= 0 {
                sumLeft += (1 - weight) * fadingLeft[frame]
                sumRight += (1 - weight) * fadingRight[frame]
            }
            if active >= 0 {
                sumLeft += weight * activeLeft[frame]
                sumRight += weight * activeRight[frame]
            }
            left[offset + frame] += sumLeft
            right[offset + frame] += sumRight
        }
        if state.fadeFramesRemaining == 0 { state.fadingVoice = -1 }
    }

    private func process(_ voice: Int, from start: Double, inputFrames: Int, outputFrames: Int, rampFrom: Int) {
        fillInput(from: start, frames: inputFrames, rampFrom: rampFrom, ramping: true)
        pair[voice].process(
            inputLeft: scratch.inputLeft, inputRight: scratch.inputRight, inputFrames: inputFrames,
            outputLeft: scratch.outputLeft(voice), outputRight: scratch.outputRight(voice), outputFrames: outputFrames,
        )
    }

    /// The group's input from reference frame `start` on, `frames` frames, into the scratch's input. Each track is
    /// scaled by its gain ramp as it stands `rampFrom` input frames past where this render call found it — the reader
    /// holds the track list and cannot move the ramps, so the call counts — and, when `ramping`, moved on one frame
    /// per input frame from there.
    private func fillInput(from start: Double, frames: Int, rampFrom: Int, ramping: Bool) {
        let left = scratch.inputLeft
        let right = scratch.inputRight
        left.update(repeating: 0, count: frames)
        right.update(repeating: 0, count: frames)
        for index in trackIndices {
            var gain = tracks[index].gainRamp
            gain.advance(by: rampFrom)
            guard !gain.isSilent else { continue }
            let source = tracks[index].frames
            let scale = source.sampleRate / sampleRate
            let shift = tracks[index].offsetSeconds * source.sampleRate
            for frame in 0 ..< frames {
                let sample = source.sample(at: (start + Double(frame)) * scale - shift)
                let level = ramping ? gain.next() : gain.current
                left[frame] += level * sample.left
                right[frame] += level * sample.right
            }
        }
    }
}

extension SwiftySynthBackend {
    /// Reference frames between a group's target and its continuation that still count as continuous.
    nonisolated static let stretchJumpToleranceFrames = 2.0

    /// One group's stretched reading over one chunk. `playing` is whether the group is read through its stretcher now;
    /// when it is not, the stretcher only finishes fading out. Returns the input frames the playing stretcher took,
    /// which the caller moves the group's gain ramps by: the reader holds the track list, so this cannot write it.
    /// Allocation-free.
    nonisolated static func mixStretchGroup(
        _ index: Int, playing: Bool,
        into left: UnsafeMutableBufferPointer<Float>, _ right: UnsafeMutableBufferPointer<Float>,
        clock: ChunkClock, sampleRate: Double, fadeFrames: Int,
        alignment: inout PlaybackAlignmentState,
    ) -> Int {
        guard let pair = alignment.groups[index].pair, let scratch = alignment.stretchScratch else { return 0 }
        var state = alignment.groups[index].state
        guard playing || state.hasSource || state.fadeFramesRemaining > 0 else { return 0 }
        // A draining group reads the tracks it was left with; the track list no longer has them.
        let tracks = if let drainTracks = alignment.groups[index].drainTracks { drainTracks } else { alignment.tracks }
        let reader = StretchReader(
            group: alignment.groups[index], pair: pair, scratch: scratch, tracks: tracks,
            rate: alignment.userSpeed, sampleRate: sampleRate,
        )
        let table = alignment.speedTable
        let schedule = alignment.schedule
        var frame = 0
        var fed = 0
        var output = clock.outputSeconds(atFrame: 0, table: table)
        while frame < left.count {
            let target = playing ? reader.target(atOutput: output, schedule: schedule) : nil
            if !continues(state, at: target) {
                reader.jump(to: target, state: &state, fadeFrames: fadeFrames, rampFrom: fed)
            }
            guard state.hasSource || state.fadeFramesRemaining > 0 else {
                // Silent: nothing to feed until a target returns, and none will if the group is not playing.
                guard playing else { break }
                frame += 1
                output = clock.outputSeconds(atFrame: frame, table: table)
                continue
            }
            // The run: the frames after this one that continue it, up to the end of a fade and the scratch's length.
            var limit = min(left.count, frame + reader.runLimit)
            if state.fadeFramesRemaining > 0 { limit = min(limit, frame + state.fadeFramesRemaining) }
            var end = frame + 1
            var next = clock.outputSeconds(atFrame: end, table: table)
            var expected: Double? = if let target { target + (next - output) * sampleRate } else { nil }
            while end < limit {
                let following = playing ? reader.target(atOutput: next, schedule: schedule) : nil
                guard isContinuation(following, of: expected) else { break }
                let after = clock.outputSeconds(atFrame: end + 1, table: table)
                if let following { expected = following + (after - next) * sampleRate }
                next = after
                end += 1
            }
            fed += reader.feed(
                state: &state, expectedEnd: expected, advance: (next - output) * sampleRate, count: end - frame,
                rampFrom: fed,
            )
            reader.mix(state: &state, into: left, right, offset: frame, count: end - frame, fadeFrames: fadeFrames)
            frame = end
            output = next
        }
        alignment.groups[index].state = state
        return fed
    }

    /// Whether `target` carries on what the group's stretched reading was doing: the stream it plays (within the
    /// tolerance, and not owed a retune), or silence after silence.
    nonisolated static func continues(_ state: StretchGroupState, at target: Double?) -> Bool {
        guard let target else { return !state.hasSource }
        return state.hasSource && !state.needsRestart && abs(target - state.expected) <= stretchJumpToleranceFrames
    }

    /// Whether a run's next frame, whose target is `target`, carries on from a frame whose continuation is `expected`.
    nonisolated static func isContinuation(_ target: Double?, of expected: Double?) -> Bool {
        switch (target, expected) {
        case let (target?, expected?): abs(target - expected) <= stretchJumpToleranceFrames
        case (nil, nil): true
        default: false
        }
    }
}
