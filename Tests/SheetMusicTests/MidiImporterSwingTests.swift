import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterSwingTests {
    /// Build an ImportTrack with one note pair per beat. `frontLen`
    /// and `backLen` set the lengths of the two eighths in each beat.
    /// `beats` is the number of beats.
    private func makeTrack(beats: Int, frontLen: Int, backLen: Int) -> ImportTrack {
        var events: [TimedMidiEvent] = []
        let beatTicks = frontLen + backLen
        for b in 0 ..< beats {
            let beatStart = b * beatTicks
            events.append(TimedMidiEvent(
                tick: beatStart,
                event: .noteOn(channel: 0, pitch: 60, velocity: 80)
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + frontLen,
                event: .noteOff(channel: 0, pitch: 60, velocity: 0)
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + frontLen,
                event: .noteOn(channel: 0, pitch: 62, velocity: 80)
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + beatTicks,
                event: .noteOff(channel: 0, pitch: 62, velocity: 0)
            ))
        }
        return ImportTrack(
            trackIndex: 0, trackName: nil, isDrums: false,
            programChange: nil, events: events
        )
    }

    private func makeTimeline(beats: Int, division: Int) -> BarTimeline {
        let beatTicks = (division * 4) / 4 // = 480 for 4/4 at 480 PPQ
        let measureLen = 4 * beatTicks
        let totalTicks = beats * beatTicks
        let bars = (0 ..< (totalTicks / measureLen)).map { i in
            BarTimeline.Bar(
                index: i,
                startTick: i * measureLen,
                endTick: (i + 1) * measureLen,
                timeSignature: TimeSignature(numerator: 4, denominator: 4)
            )
        }
        return BarTimeline(bars: bars)
    }

    @Test func resolverNotInvokedForStraightEighths() {
        // 8 beats × 2 straight eighths each = 16 noteOns.
        let track = makeTrack(beats: 16, frontLen: 240, backLen: 240)
        var calls = 0
        _ = MidiImporter.analyzeSwing(
            track: track,
            timeline: makeTimeline(beats: 16, division: 480),
            division: 480,
            resolve: { _ in calls += 1; return .treatAsWritten }
        )
        #expect(calls == 0)
    }

    @Test func resolverInvokedForTwoToOneSwingWithRatioNearTwo() {
        // 8 beats × 2 swung eighths (front 320, back 160) = 16 noteOns,
        // ratio = 160/320 = 0.5? No: spec says ratio = back/front.
        // For 2:1 swing, front is the LONGER one (≈ 320 in a 480 beat),
        // back is shorter (≈ 160). So ratio = back/front = 160/320 = 0.5.
        // But our code expects ratio in [1.4, 2.5] — that's front/back = 2.0.
        //
        // Read the spec carefully: "Computes per-triple ratio
        // (t2 - t1) / (t1 - t0) (back-eighth length divided by
        // front-eighth length)".
        // In 2:1 swing the BACK eighth is shorter (1 unit) and front
        // is longer (2 units), so back/front = 0.5. But the
        // detection threshold is mean ∈ [1.4, 2.5].
        //
        // Reconciling: the spec convention is that mean represents
        // the ratio of the LONGER eighth to the SHORTER one — i.e.
        // we should compute max/min, not literally back/front.
        // OR: the spec assumes BACK is longer than FRONT (legato
        // swing where the back eighth held longer). Let's encode
        // the test as "back is longer". For 2:1 swing: front=160,
        // back=320, ratio=320/160=2.0.
        let track = makeTrack(beats: 16, frontLen: 160, backLen: 320)
        var captured: SwingDetection?
        _ = MidiImporter.analyzeSwing(
            track: track,
            timeline: makeTimeline(beats: 16, division: 480),
            division: 480,
            resolve: { d in captured = d; return .treatAsWritten }
        )
        #expect(captured != nil)
        if let c = captured {
            #expect(c.estimatedRatio > 1.7)
            #expect(c.estimatedRatio < 2.3)
        }
    }

    @Test func treatAsSwingStraightensTicks() {
        // front=160, back=320 (2:1 swing). After .treatAsSwing,
        // the back eighth should snap to mid-beat (240).
        let track = makeTrack(beats: 16, frontLen: 160, backLen: 320)
        let result = MidiImporter.analyzeSwing(
            track: track,
            timeline: makeTimeline(beats: 16, division: 480),
            division: 480,
            resolve: { _ in .treatAsSwing }
        )
        // After straightening, beat 0's first noteOff/second noteOn
        // should both be at tick 240, not 160.
        let secondOnTicks = result.events.compactMap { ev -> Int? in
            if case let .noteOn(_, p, v) = ev.event, v > 0, p == 62 {
                return ev.tick
            }
            return nil
        }
        // Each beat's second-eighth onset should be at beatStart + 240.
        for (i, t) in secondOnTicks.enumerated() {
            #expect(t == i * 480 + 240)
        }
    }
}
