@testable import SheetMusicAudioCore
import SheetMusicFoundation
import Testing

struct TransportSpeedTableTests {
    private typealias Span = PlaybackTimeWarp.Span

    private static func warp(_ spans: [Span]) throws -> PlaybackTimeWarp {
        try PlaybackTimeWarp(spans: spans)
    }

    @Test
    func `a nil warp is the identity`() {
        let table = TransportSpeedTable(warp: nil)
        #expect(table.stretch(atTransport: 5) == 1)
        #expect(table.outputSeconds(atTransport: 5) == 5)
        #expect(table.transportSeconds(atOutput: 5) == 5)
        #expect(table.nextBoundary(after: 0) == nil)
    }

    @Test
    func `an empty span list equals the identity`() throws {
        let table = try TransportSpeedTable(warp: Self.warp([]))
        #expect(table.stretch(atTransport: 3) == 1)
        #expect(table.outputSeconds(atTransport: 3) == 3)
        #expect(table.transportSeconds(atOutput: 3) == 3)
        #expect(table.nextBoundary(after: -1) == nil)
    }

    @Test
    func `a span lasting half its length has stretch 2 and warps linearly`() throws {
        let table = try TransportSpeedTable(warp: Self.warp([Span(start: 2, end: 4, duration: 1)]))
        #expect(table.stretch(atTransport: 3) == 2)
        #expect(table.outputSeconds(atTransport: 2) == 2)
        #expect(table.outputSeconds(atTransport: 3) == 2.5)
        #expect(table.outputSeconds(atTransport: 4) == 3)
        // Past the span the 1 s saved carries forward.
        #expect(table.outputSeconds(atTransport: 10) == 9)
        #expect(table.transportSeconds(atOutput: 2.5) == 3)
        #expect(table.transportSeconds(atOutput: 9) == 10)
    }

    @Test
    func `stretch is 1 before, between and after spans`() throws {
        let table = try TransportSpeedTable(warp: Self.warp([
            Span(start: 1, end: 2, duration: 4),
            Span(start: 5, end: 6, duration: 0.5),
        ]))
        #expect(table.stretch(atTransport: -3) == 1)
        #expect(table.stretch(atTransport: 0.5) == 1)
        #expect(table.stretch(atTransport: 1.5) == 0.25)
        #expect(table.stretch(atTransport: 3) == 1)
        #expect(table.stretch(atTransport: 5.5) == 2)
        #expect(table.stretch(atTransport: 6) == 1)
        #expect(table.stretch(atTransport: 100) == 1)
        // Gaps pass 1:1, with the first span's 3 s of added time already behind them.
        #expect(table.outputSeconds(atTransport: 3) == 6)
        #expect(table.outputSeconds(atTransport: -2) == -2)
    }

    @Test
    func `touching spans are allowed`() throws {
        let table = try TransportSpeedTable(warp: Self.warp([
            Span(start: 0, end: 2, duration: 1),
            Span(start: 2, end: 4, duration: 4),
        ]))
        #expect(table.stretch(atTransport: 1) == 2)
        #expect(table.stretch(atTransport: 2) == 0.5)
        #expect(table.outputSeconds(atTransport: 2) == 1)
        #expect(table.outputSeconds(atTransport: 4) == 5)
    }

    @Test
    func `nextBoundary returns the next span edge strictly after t`() throws {
        let table = try TransportSpeedTable(warp: Self.warp([
            Span(start: 1, end: 2, duration: 1),
            Span(start: 2, end: 4, duration: 1),
        ]))
        #expect(table.nextBoundary(after: -5) == 1)
        #expect(table.nextBoundary(after: 1) == 2)
        #expect(table.nextBoundary(after: 1.5) == 2)
        #expect(table.nextBoundary(after: 2) == 4)
        #expect(table.nextBoundary(after: 4) == nil)
        #expect(table.nextBoundary(after: 9) == nil)
    }

    @Test
    func `the inverse round-trips over a 30-span table`() throws {
        let spans = (0 ..< 30).map { index -> Span in
            let start = Double(index) * 2.5
            return Span(start: start, end: start + 2, duration: 0.4 + Double(index % 7) * 0.45)
        }
        let table = try TransportSpeedTable(warp: Self.warp(spans))
        var previous = -Double.infinity
        for step in 0 ..< 1000 {
            let t = -2 + Double(step) * 0.0803
            let out = table.outputSeconds(atTransport: t)
            #expect(out > previous)
            previous = out
            #expect(abs(table.transportSeconds(atOutput: out) - t) < 1e-9)
        }
    }

    @Test
    func `overlapping or descending spans throw with the later span's index`() {
        #expect(throws: PlaybackTimeWarpError.notAscending(index: 1)) {
            try PlaybackTimeWarp(spans: [
                Span(start: 0, end: 3, duration: 1),
                Span(start: 2, end: 4, duration: 1),
            ])
        }
        #expect(throws: PlaybackTimeWarpError.notAscending(index: 2)) {
            try PlaybackTimeWarp(spans: [
                Span(start: 0, end: 1, duration: 1),
                Span(start: 5, end: 6, duration: 1),
                Span(start: 1, end: 2, duration: 1),
            ])
        }
    }

    @Test
    func `a non-finite, empty or zero-duration span throws invalidSpan`() {
        let bad: [Span] = [
            Span(start: .nan, end: 1, duration: 1),
            Span(start: 0, end: .infinity, duration: 1),
            Span(start: 0, end: 1, duration: .nan),
            Span(start: 0, end: 1, duration: 0),
            Span(start: 0, end: 1, duration: -1),
            Span(start: 1, end: 1, duration: 1),
            Span(start: 2, end: 1, duration: 1),
        ]
        for span in bad {
            #expect(throws: PlaybackTimeWarpError.invalidSpan(index: 1)) {
                try PlaybackTimeWarp(spans: [Span(start: -1, end: -0.5, duration: 1), span])
            }
        }
    }

    @Test
    func `a count-in without a span lasts its own seconds at any rate`() {
        let countIn = TransportSpeedTable(warp: nil).countIn(seconds: 2, userSpeed: 0.5, bodyStart: 4)
        #expect(countIn.duration == 2)
        #expect(countIn.speed == nil)
    }

    @Test
    func `a count-in under a warp runs at the speed of the stretch its body starts in`() throws {
        // Transport 0–2 s lasts 2.5 s (stretch 0.8), 2–4 s lasts 2 s (stretch 1).
        let table = try TransportSpeedTable(warp: Self.warp([
            Span(start: 0, end: 2, duration: 2.5), Span(start: 2, end: 4, duration: 2),
        ]))
        // Parked half a tick (at 120 BPM, division 480) before the onset, as a seek leaves the transport.
        let first = table.countIn(seconds: 2, userSpeed: 1, bodyStart: -0.0005)
        #expect(abs(first.duration - 2.5) < 1e-12)
        #expect(first.speed.map { abs($0 - 0.8) < 1e-12 } == true)
        // At 70 % the count into the second measure runs at 0.7 and lasts 2 / 0.7 s.
        let second = table.countIn(seconds: 2, userSpeed: 0.7, bodyStart: 2 - 0.0005)
        #expect(abs(second.duration - 2 / 0.7) < 1e-12)
        #expect(second.speed.map { abs($0 - 0.7) < 1e-12 } == true)
    }

    @Test
    func `lookups on a 3600-span table stay fast`() throws {
        let spans = (0 ..< 3600).map { index -> Span in
            let start = Double(index) * 2
            return Span(start: start, end: start + 1.5, duration: 1 + Double(index % 3) * 0.25)
        }
        let table = try TransportSpeedTable(warp: Self.warp(spans))
        var sink = 0.0
        // Regression tripwire, not a benchmark: a linear scan over 3 600 spans takes orders of magnitude longer.
        let elapsed = ContinuousClock().measure {
            for call in 0 ..< 10000 {
                let t = Double(call) * 0.72
                sink += table.stretch(atTransport: t)
                sink += table.outputSeconds(atTransport: t)
                sink += table.transportSeconds(atOutput: t)
                sink += table.nextBoundary(after: t) ?? 0
            }
        }
        #expect(sink > 0)
        #expect(elapsed < .milliseconds(100))
    }
}
