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
                    // Advance the score transport, dispatch due events, render.
                    sequencer.render(left: left, right: right)
                    // Mix the metronome in when it's unmuted. While muted it is
                    // NOT rendered at all (its transport freezes), so the
                    // effects-free click synth costs zero — `setMetronomeMuted`
                    // reseeks it to the score position on un-mute so it lands
                    // back on the beat.
                    mixMetronome(
                        into: left, right, shared: &shared,
                        render: { seq, l, r in seq.render(left: l, right: r) },
                    )
                } else if let synthesizer = shared.synthesizer {
                    // Paused/stopped: render release tails but don't advance the
                    // transports.
                    synthesizer.render(left: left, right: right)
                    mixMetronome(
                        into: left, right, shared: &shared,
                        render: { seq, l, r in seq.synthesizer.render(left: l, right: r) },
                    )
                } else {
                    left.update(repeating: 0)
                    right.update(repeating: 0)
                }
            }
            return noErr
        }
    }

    /// Render the metronome sequencer (or, when paused, its synth) into scratch
    /// in `scratchCapacity`-frame slices and add it onto `left`/`right`. A no-op
    /// while muted — the metronome then spends no render-thread CPU at all.
    /// Allocation-free: uses the pre-sized `shared.scratch*`.
    nonisolated static func mixMetronome(
        into left: UnsafeMutableBufferPointer<Float>,
        _ right: UnsafeMutableBufferPointer<Float>,
        shared: inout Shared,
        render: (MidiFileSequencer, UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) -> Void,
    ) {
        guard !shared.metronomeMuted,
              let metronomeSequencer = shared.metronomeSequencer
        else { return }
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
                        left[offset + i] += chunkL[i]
                        right[offset + i] += chunkR[i]
                    }
                    offset += n
                }
            }
        }
    }
}
