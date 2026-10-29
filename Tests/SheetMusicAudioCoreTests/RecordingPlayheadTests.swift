@testable import SheetMusicAudioCore
import Testing

struct RecordingPlayheadTests {
    /// 400 stereo frames: left = frame × 50, right = −left. Every value is a multiple of 50 / 32768, so the
    /// expected samples below are exact.
    private static let samples: [Int16] = (0 ..< 400).flatMap { frame -> [Int16] in
        [Int16(frame * 50), Int16(-frame * 50)]
    }

    private static func left(_ frame: Int) -> Float {
        Float(frame * 50) / 32768
    }

    private static func withFrames(_ body: (PCMFrames) -> Void) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else {
                Issue.record("the sample buffer has no storage")
                return
            }
            body(PCMFrames(base: base, frameCount: 400, sampleRate: 48000))
        }
    }

    // MARK: PCMFrames

    @Test
    func `a whole frame reads the stored samples divided by 32768`() {
        Self.withFrames { frames in
            let s = frames.sample(at: 7)
            #expect(s.left == Float(350) / 32768)
            #expect(s.right == Float(-350) / 32768)
        }
    }

    @Test
    func `a fractional frame interpolates linearly between its neighbors`() {
        Self.withFrames { frames in
            let s = frames.sample(at: 7.25)
            #expect(s.left == Float(362.5) / 32768)
            #expect(s.right == Float(-362.5) / 32768)
        }
    }

    @Test
    func `positions outside the readable range are silence and never trap`() {
        Self.withFrames { frames in
            for position in [-0.5, 399, 399.5, 1e12, -1e12, Double.nan, Double.infinity, -Double.infinity] {
                let s = frames.sample(at: position)
                #expect(s.left == 0)
                #expect(s.right == 0)
            }
            #expect(frames.sample(at: 398.5).left == Float(19925) / 32768)
            #expect(frames.sample(at: 0).left == 0)
        }
    }

    // MARK: RecordingPlayhead

    @Test
    func `a continuous read after the fade-in equals the source`() {
        Self.withFrames { frames in
            var playhead = RecordingPlayhead()
            var position = 50.0
            for index in 0 ..< 12 {
                let out = playhead.render(target: position, step: 1, from: frames, fadeFrames: 4)
                if index >= 4 {
                    #expect(out.left == Self.left(Int(position)))
                    #expect(out.right == -Self.left(Int(position)))
                }
                position += 1
            }
        }
    }

    @Test
    func `silence to audio fades in linearly over fadeFrames`() {
        Self.withFrames { frames in
            var playhead = RecordingPlayhead()
            let weights: [Float] = [0, 0.25, 0.5, 0.75, 1, 1]
            for (index, weight) in weights.enumerated() {
                let out = playhead.render(target: Double(20 + index), step: 1, from: frames, fadeFrames: 4)
                #expect(out.left == weight * Self.left(20 + index))
            }
        }
    }

    @Test
    func `a jump crossfades from the continuation and the midpoint is the average`() {
        Self.withFrames { frames in
            var playhead = RecordingPlayhead()
            // Settle: fade-in over 4 frames, then 4 plain frames; the continuation is then frame 28.
            for index in 0 ..< 8 {
                _ = playhead.render(target: Double(20 + index), step: 1, from: frames, fadeFrames: 4)
            }
            let weights: [Float] = [0, 0.25, 0.5, 0.75, 1]
            for (k, weight) in weights.enumerated() {
                let out = playhead.render(target: Double(200 + k), step: 1, from: frames, fadeFrames: 4)
                // The old stream keeps advancing under the fade, at `step`.
                let expected = (1 - weight) * Self.left(28 + k) + weight * Self.left(200 + k)
                #expect(out.left == expected)
                if k == 2 {
                    #expect(out.left == (Self.left(30) + Self.left(202)) / 2)
                }
            }
            // Afterwards only the new stream is heard.
            let after = playhead.render(target: 205, step: 1, from: frames, fadeFrames: 4)
            #expect(after.left == Self.left(205))
        }
    }

    @Test
    func `a jump within two frames of the continuation is not a discontinuity`() {
        Self.withFrames { frames in
            var playhead = RecordingPlayhead()
            for index in 0 ..< 8 {
                _ = playhead.render(target: Double(20 + index), step: 1, from: frames, fadeFrames: 4)
            }
            let out = playhead.render(target: 30, step: 1, from: frames, fadeFrames: 4)
            #expect(out.left == Self.left(30))
        }
    }

    @Test
    func `a jump arriving mid-fade restarts from the newer stream's continuation`() {
        Self.withFrames { frames in
            var playhead = RecordingPlayhead()
            for index in 0 ..< 8 {
                _ = playhead.render(target: Double(20 + index), step: 1, from: frames, fadeFrames: 4)
            }
            _ = playhead.render(target: 200, step: 1, from: frames, fadeFrames: 4)
            _ = playhead.render(target: 201, step: 1, from: frames, fadeFrames: 4)
            // Mid-fade a second jump: weight restarts at 0 and the old stream is the 200-stream's continuation (202).
            let restart = playhead.render(target: 300, step: 1, from: frames, fadeFrames: 4)
            #expect(restart.left == Self.left(202))
            let next = playhead.render(target: 301, step: 1, from: frames, fadeFrames: 4)
            #expect(next.left == 0.75 * Self.left(203) + 0.25 * Self.left(301))
        }
    }

    @Test
    func `audio to silence fades out linearly then stays silent`() {
        Self.withFrames { frames in
            var playhead = RecordingPlayhead()
            for index in 0 ..< 8 {
                _ = playhead.render(target: Double(20 + index), step: 1, from: frames, fadeFrames: 4)
            }
            let weights: [Float] = [0, 0.25, 0.5, 0.75, 1, 1]
            for (k, weight) in weights.enumerated() {
                let out = playhead.render(target: nil, step: 1, from: frames, fadeFrames: 4)
                #expect(out.left == (1 - weight) * Self.left(28 + k))
            }
            #expect(playhead.render(target: nil, step: 1, from: frames, fadeFrames: 4).left == 0)
        }
    }

    @Test
    func `a target past the last frame is silence`() {
        Self.withFrames { frames in
            var playhead = RecordingPlayhead()
            for target in [450.0, 451, 452, 1e9, .infinity, .nan] {
                let out = playhead.render(target: target, step: 1, from: frames, fadeFrames: 1)
                #expect(out.left == 0)
                #expect(out.right == 0)
            }
        }
    }

    @Test
    func `reset makes the next frame fade in again`() {
        Self.withFrames { frames in
            var playhead = RecordingPlayhead()
            for index in 0 ..< 8 {
                _ = playhead.render(target: Double(20 + index), step: 1, from: frames, fadeFrames: 4)
            }
            playhead.reset()
            let first = playhead.render(target: 28, step: 1, from: frames, fadeFrames: 4)
            let second = playhead.render(target: 29, step: 1, from: frames, fadeFrames: 4)
            #expect(first.left == 0)
            #expect(second.left == 0.25 * Self.left(29))
        }
    }

    // MARK: RecordingSchedule

    private static let schedule = RecordingSchedule(segments: [
        RecordingSegment(sourceStart: 10, sourceEnd: 20, outputStart: 0),
        RecordingSegment(sourceStart: 40, sourceEnd: 50, outputStart: 12),
    ])

    @Test
    func `sourceSeconds maps output time into the segment's reference time`() {
        #expect(Self.schedule.sourceSeconds(atOutput: 0, offset: 0) == 10)
        #expect(Self.schedule.sourceSeconds(atOutput: 5, offset: 0) == 15)
        #expect(Self.schedule.sourceSeconds(atOutput: 12, offset: 0) == 40)
        #expect(Self.schedule.sourceSeconds(atOutput: 21.5, offset: 0) == 49.5)
    }

    @Test
    func `sourceSeconds is nil in a gap, past sourceEnd and before the first segment`() {
        #expect(Self.schedule.sourceSeconds(atOutput: 10, offset: 0) == nil)
        #expect(Self.schedule.sourceSeconds(atOutput: 11, offset: 0) == nil)
        #expect(Self.schedule.sourceSeconds(atOutput: 22, offset: 0) == nil)
        #expect(Self.schedule.sourceSeconds(atOutput: 100, offset: 0) == nil)
        #expect(Self.schedule.sourceSeconds(atOutput: -1, offset: 0) == nil)
        #expect(Self.schedule.sourceSeconds(atOutput: .nan, offset: 0) == nil)
    }

    @Test
    func `sourceSeconds honors a track offset and is nil before the stem starts`() {
        // A stem starting 1.5 s into the mix.
        #expect(Self.schedule.sourceSeconds(atOutput: 0, offset: 1.5) == 8.5)
        let early = RecordingSchedule(segments: [RecordingSegment(sourceStart: 1, sourceEnd: 5, outputStart: 0)])
        #expect(early.sourceSeconds(atOutput: 0, offset: 1.5) == nil)
        #expect(early.sourceSeconds(atOutput: 0.5, offset: 1.5) == 0)
        #expect(early.sourceSeconds(atOutput: 1, offset: 1.5) == 0.5)
    }

    @Test
    func `segments given out of order are sorted`() {
        let shuffled = RecordingSchedule(segments: [
            RecordingSegment(sourceStart: 40, sourceEnd: 50, outputStart: 12),
            RecordingSegment(sourceStart: 10, sourceEnd: 20, outputStart: 0),
        ])
        #expect(shuffled.sourceSeconds(atOutput: 5, offset: 0) == 15)
        #expect(shuffled.sourceSeconds(atOutput: 13, offset: 0) == 41)
    }

    @Test
    func `an empty schedule is silence`() {
        #expect(RecordingSchedule(segments: []).sourceSeconds(atOutput: 0, offset: 0) == nil)
    }
}
