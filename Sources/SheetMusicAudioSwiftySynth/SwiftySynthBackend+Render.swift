import AVFoundation
import os
import SwiftySynth

/// The `AVAudioSourceNode` render factory and the metronome mix — split out of
/// `SwiftySynthBackend.swift` so each file keeps one responsibility. Both are
/// `nonisolated static` so the render block never inherits `@MainActor`.
extension SwiftySynthBackend {
    /// Build the render source node in a `nonisolated` context so its render
    /// block does NOT inherit `@MainActor` isolation — a main-actor closure
    /// traps (EXC_BREAKPOINT) the first time the real audio render thread pulls
    /// it. The block only captures the `Sendable` lock.
    nonisolated static func makeSourceNode(
        lock: OSAllocatedUnfairLock<Shared>, sampleRate: Double,
    ) -> AVAudioSourceNode {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2,
        ) else {
            preconditionFailure("stereo float32 format unavailable at \(sampleRate) Hz")
        }
        return AVAudioSourceNode(format: format) { _, _, frameCount, abListPtr in
            let abl = UnsafeMutableAudioBufferListPointer(abListPtr)
            guard abl.count >= 2,
                  let leftRaw = abl[0].mData,
                  let rightRaw = abl[1].mData
            else { return noErr }
            let count = Int(frameCount)
            let left = UnsafeMutableBufferPointer(
                start: leftRaw.assumingMemoryBound(to: Float.self), count: count,
            )
            let right = UnsafeMutableBufferPointer(
                start: rightRaw.assumingMemoryBound(to: Float.self), count: count,
            )
            lock.withLockUnchecked { shared in
                if shared.isPlaying, let sequencer = shared.sequencer {
                    renderPlaying(
                        into: left, right, sequencer: sequencer, sampleRate: sampleRate, shared: &shared,
                    )
                } else if let synthesizer = shared.synthesizer {
                    // Paused/stopped: render release tails but don't advance the
                    // transports. The recordings are silent, and fade in when play resumes.
                    synthesizer.render(left: left, right: right)
                    mixMetronome(
                        into: left, right, shared: &shared,
                        render: { seq, l, r in seq.synthesizer.render(left: l, right: r) },
                    )
                    shared.alignment.silenceRecordings()
                } else {
                    left.update(repeating: 0)
                    right.update(repeating: 0)
                    shared.alignment.silenceRecordings()
                }
            }
            return noErr
        }
    }

    /// One block of an active playback.
    ///
    /// A count-in splits it at the frame the pre-roll runs out: up to there the score transport
    /// is HELD while the metronome transport counts, and from there on both run normally.
    /// Splitting on the frame rather than on the buffer is what keeps the downbeat where the
    /// count says it is — and keeps a muted-metronome playback from leaking the body's first
    /// click through the tail of a too-long pre-roll window.
    nonisolated static func renderPlaying(
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        sequencer: MidiFileSequencer,
        sampleRate: Double,
        shared: inout Shared,
    ) {
        let count = left.count
        let preRoll = min(max(shared.preRollFramesRemaining, 0), count)
        if preRoll > 0 {
            // A count-in started under a warp runs at the speed it was given (`play(afterCountInSeconds:)`); a table
            // swap during it applies from the body on.
            if let speed = shared.alignment.countInSpeed {
                shared.metronomeSequencer?.speed = speed
            }
            renderCountIn(into: left, right, upTo: preRoll, shared: &shared)
            shared.preRollFramesRemaining -= preRoll
            // Nothing of the recordings sounds under the count: the body fades them in.
            shared.alignment.silenceRecordings()
        }
        guard preRoll < count else { return }
        let bodyL = UnsafeMutableBufferPointer(rebasing: left[preRoll ..< count])
        let bodyR = UnsafeMutableBufferPointer(rebasing: right[preRoll ..< count])
        renderBody(into: bodyL, bodyR, sequencer: sequencer, sampleRate: sampleRate, shared: &shared)
    }

    /// The body of a playing buffer — score transport, recordings, metronome — in chunks, so both transports' speed
    /// can follow the speed table: at each chunk that starts on a sequencer block start, the speed is set to the
    /// user's rate × the stretch where the block's middle falls. Without a warp the speed never changes, and the
    /// chunks (one, or two when the buffer starts mid-block) render sample for sample what one call always did.
    /// Allocation-free.
    nonisolated static func renderBody(
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        sequencer: MidiFileSequencer,
        sampleRate: Double,
        shared: inout Shared,
    ) {
        let count = left.count
        let blockSize = sequencer.synthesizer.blockSize
        var offset = 0
        while offset < count {
            let position = sequencer.position.components
            let now = shared.alignment.transportSeconds(
                quantized: Double(position.seconds) + Double(position.attoseconds) * 1e-18,
                sampleRate: sampleRate, blockSize: blockSize,
            )
            if shared.alignment.blockPhase == 0 {
                let middle = now + Double(blockSize) / 2 * sequencer.speed / sampleRate
                let speed = shared.alignment.speed(atTransport: middle)
                if sequencer.speed != speed { sequencer.speed = speed }
                if let metronome = shared.metronomeSequencer, metronome.speed != speed { metronome.speed = speed }
                shared.alignment.blockSpeed = speed
            }
            let speed = shared.alignment.blockSpeed
            let chunk = max(1, shared.alignment.framesBeforeSpeedDecision(
                at: now, speed: speed, sampleRate: sampleRate, blockSize: blockSize, limit: count - offset,
            ))
            let chunkL = UnsafeMutableBufferPointer(rebasing: left[offset ..< offset + chunk])
            let chunkR = UnsafeMutableBufferPointer(rebasing: right[offset ..< offset + chunk])
            // Advance the score transport, dispatch due events, render.
            sequencer.render(left: chunkL, right: chunkR)
            mixRecordings(
                into: chunkL, chunkR, transportStart: now, transportPerFrame: speed / sampleRate,
                sampleRate: sampleRate, alignment: &shared.alignment,
            )
            // Mix the metronome in when it's audible. While muted or at zero gain it is NOT rendered
            // at all (its transport freezes), so the effects-free click synth costs zero —
            // `setMetronomeMuted` / `setMetronomeVolume` reseek it to the score position when it
            // becomes audible again, so it lands back on the beat.
            mixMetronome(
                into: chunkL, chunkR, shared: &shared,
                render: { seq, l, r in seq.render(left: l, right: r) },
            )
            shared.alignment.advance(frames: chunk, blockSize: blockSize)
            offset += chunk
        }
    }

    /// The count-in window: the first `frames` frames of this buffer, during
    /// which the score transport must NOT advance. Its synth still renders, so
    /// a note left ringing by the previous playback decays naturally instead of
    /// being cut when the count starts, and the metronome transport advances —
    /// forced audible, because a count-in is requested explicitly and must sound
    /// even with the metronome toggle off.
    nonisolated static func renderCountIn(
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        upTo frames: Int,
        shared: inout Shared,
    ) {
        let countL = UnsafeMutableBufferPointer(rebasing: left[0 ..< frames])
        let countR = UnsafeMutableBufferPointer(rebasing: right[0 ..< frames])
        if let synthesizer = shared.synthesizer {
            synthesizer.render(left: countL, right: countR)
        } else {
            countL.update(repeating: 0)
            countR.update(repeating: 0)
        }
        mixMetronome(
            into: countL, countR, shared: &shared, forceAudible: true,
            render: { seq, l, r in seq.render(left: l, right: r) },
        )
    }

    /// Render the metronome sequencer (or, when paused, its synth) into scratch
    /// in `scratchCapacity`-frame slices and add it onto `left`/`right`, scaled
    /// by the strip's `metronomeGain`. A no-op while muted or at zero gain —
    /// the metronome then spends no render-thread CPU at all, and its transport
    /// freezes until `resyncMetronome` reseeks it.
    /// Allocation-free: uses the pre-sized `shared.scratch*`.
    ///
    /// `forceAudible` overrides the mute flag (not the gain) for a count-in
    /// pre-roll.
    nonisolated static func mixMetronome(
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        shared: inout Shared,
        forceAudible: Bool = false,
        render: (MidiFileSequencer, UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) -> Void,
    ) {
        guard !shared.metronomeMuted || forceAudible,
              let metronomeSequencer = shared.metronomeSequencer
        else { return }
        let gain = shared.metronomeGain
        guard gain > 0 else { return }
        let count = left.count
        shared.scratchL.withUnsafeMutableBufferPointer { sl in
            shared.scratchR.withUnsafeMutableBufferPointer { sr in
                var offset = 0
                while offset < count {
                    let n = min(sl.count, count - offset)
                    guard n > 0 else { return }
                    let chunkL = UnsafeMutableBufferPointer(rebasing: sl[0 ..< n])
                    let chunkR = UnsafeMutableBufferPointer(rebasing: sr[0 ..< n])
                    render(metronomeSequencer, chunkL, chunkR)
                    for i in 0 ..< n {
                        left[offset + i] += chunkL[i] * gain
                        right[offset + i] += chunkR[i] * gain
                    }
                    offset += n
                }
            }
        }
    }
}
