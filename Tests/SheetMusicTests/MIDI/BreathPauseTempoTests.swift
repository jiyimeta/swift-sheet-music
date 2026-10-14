@testable import SheetMusicAudioCore
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// A caesura's pause lasts its seconds at the tempo where it stands, and an arpeggio spreads at that tempo, on every
/// staff and in the cursor timeline alike (import-fidelity F2.9). Every expectation below is hand-derived from the
/// tempo map's value at the breath (`ResolvedTempoMap.beatsPerSecond(atMeasure:tickInMeasure:)`) at division 480.
@Suite("Breath pauses and arpeggios at the map's tempo")
struct BreathPauseTempoTests {
    private static let division = 480

    private static func chord(_ duration: NoteDuration, _ pitches: [Int], arpeggio: Bool = false) -> VoiceElement {
        .chord(Chord(
            duration: duration, notes: ChordNotes(pitches.map { Note(pitch: $0, tpc: 14) }),
            arpeggio: arpeggio ? Arpeggio(subtype: 0) : nil,
        ))
    }

    /// A one-second caesura.
    private static let caesura = VoiceElement.breath(Breath(kind: .caesura(.normal), pause: 1))

    /// Two identical staves of 4/4 bars, `lane` giving the system tempo lane as `(measure, quarter, element)`.
    private static func score(bars: [[VoiceElement]], lane: [TempoMapFixtures.LaneEntry]) -> Score {
        let meter = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
        let measures = bars.enumerated().map { index, elements in
            Measure(voices: [Voice(elements: (index == 0 ? [meter] : []) + elements)])
        }
        let parts: [Part] = ["1", "2"].map { id in
            Part(id: id, instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])
        }
        let systemMeasures = bars.indices.map { index in
            SystemMeasure(elements: lane.filter { $0.measure == index }.map { entry in
                PositionedSystemElement(
                    position: MeasurePosition(numerator: entry.quarter, denominator: 4), element: entry.element,
                )
            })
        }
        return Score(division: division, parts: IdentifiedArray(parts), systemMeasures: IdentifiedArray(systemMeasures))
    }

    private static func onsets(_ track: MidiTrack) -> [Int] {
        track.events.compactMap { event -> Int? in
            guard case let .noteOn(_, _, velocity) = event.event, velocity > 0 else { return nil }
            return event.tick
        }
        .sorted()
    }

    /// Seconds to `tick` in a track's tempo metas (120 BPM before the first), the last meta at a tick winning.
    private static func smfSeconds(atTick tick: Int, events: [TimedMidiEvent]) -> Double {
        var seconds = 0.0
        var lastTick = 0
        var micros = 500_000
        for event in events where event.tick <= tick {
            guard case let .meta(.tempo(value)) = event.event else { continue }
            seconds += Double(event.tick - lastTick) * Double(micros) / 1_000_000 / Double(division)
            lastTick = event.tick
            micros = value
        }
        return seconds + Double(tick - lastTick) * Double(micros) / 1_000_000 / Double(division)
    }

    /// Every staff's note-ons are at `expected`, the cursor timeline has a frame at each tick of `frameTicks` (the
    /// onsets by default — an arpeggio's spread notes have none of their own), and the timeline's clock reads the same
    /// seconds there as the SMF's tempo metas do. Returns the timeline's seconds at `frameTicks`.
    @discardableResult
    private static func expectAgreement(
        _ score: Score, onsets expected: [Int], frameTicks: [Int]? = nil,
    ) throws -> [Double] {
        let midi = try MidiRenderer.render(score: score)
        try #require(midi.tracks.count == 2)
        for track in midi.tracks {
            #expect(Self.onsets(track) == expected)
        }
        let frames = PlaybackTimeline(score: score).frames
        var seconds: [Double] = []
        for tick in frameTicks ?? expected {
            let frame = try #require(frames.first { $0.tick == tick })
            let smf = Self.smfSeconds(atTick: tick, events: midi.tracks[0].events)
            #expect(abs(frame.timeSeconds - smf) < 1e-6, "tick \(tick)")
            seconds.append(frame.timeSeconds)
        }
        return seconds
    }

    private static func tempo(_ measure: Int, _ quarter: Int, _ bps: Double) -> TempoMapFixtures.LaneEntry {
        TempoMapFixtures.tempo(measure, quarter, Tempo(beatsPerSecond: bps))
    }

    @Test("the pause is one second at ♩ = 60 — 480 ticks — on every staff")
    func breathPauseUsesTheMapTempo() throws {
        // | C♩ caesura D♩ E𝅗𝅥 | G𝅝 |: the pause 1 s × 1 bps × 480 = 480 ticks, so D at 480 + 480 = 960, E at 1440, and
        // the bar is 1920 + 480 = 2400 long.
        let score = Self.score(
            bars: [
                [Self.chord(.quarter, [60]), Self.caesura, Self.chord(.quarter, [62]), Self.chord(.half, [64])],
                [Self.chord(.whole, [67])],
            ],
            lane: [Self.tempo(0, 0, 1)],
        )
        let seconds = try Self.expectAgreement(score, onsets: [0, 960, 1440, 2400])
        // ♩ = 60 throughout: a quarter is a second, so the clock reads the ticks divided by 480.
        #expect(zip(seconds, [0.0, 2.0, 3.0, 5.0]).map { abs($0 - $1) < 1e-3 } == [true, true, true, true])
    }

    @Test("a tempo marking before the breath in the same bar sets the pause")
    func tempoChangeBeforeTheBreathInTheBar() throws {
        // | C♩ D♩ [♩ = 90] caesura E♩ F♩ | G𝅝 |: nothing states a tempo until the third beat, so C and D play at
        // 120 and the breath, at nominal tick 960, reads the 90 BPM marking standing there (1.5 bps): 1 × 1.5 × 480 =
        // 720 ticks (not the 960 of 120 BPM). E at 960 + 720 = 1680, F at 2160, the bar is 1920 + 720 = 2640 long.
        let score = Self.score(
            bars: [
                [
                    Self.chord(.quarter, [60]), Self.chord(.quarter, [62]), Self.caesura,
                    Self.chord(.quarter, [64]), Self.chord(.quarter, [65]),
                ],
                [Self.chord(.whole, [67])],
            ],
            lane: [Self.tempo(0, 2, 1.5)],
        )
        let seconds = try Self.expectAgreement(score, onsets: [0, 480, 1680, 2160, 2640])
        // Two beats at 2 bps = 1 s (D at 0.5 s), then 720 ticks at 1.5 bps = 1 s, then a beat at 1.5 bps = 2/3 s twice.
        let expected = [0.0, 0.5, 2.0, 2.0 + 2.0 / 3, 2.0 + 4.0 / 3]
        #expect(zip(seconds, expected).map { abs($0 - $1) < 1e-3 } == [true, true, true, true, true])
    }

    @Test("a breath inside a gradual ramp pauses at the ramp step in force")
    func breathInsideAGradualRamp() throws {
        // Bar 1 is a ritardando to half its starting tempo: ♩ = 120 (2 bps) → 1 bps in eight steps of 240 ticks, step i
        // at 240 i with bps 2 − i/8. The breath stands at nominal 960 + 120 = 1080 (after a quarter, a
        // quarter and a sixteenth); in force there is step 4 (tick 960, 1.5 bps): 1 × 1.5 × 480 = 720 ticks. Bar 1
        // starts at 1920: C 1920, D 2400, E 2880, F at 1920 + 1080 + 720 = 3720, G𝅘𝅥𝅯 at 3720 + 720 = 4440.
        let ritardando = TempoMapFixtures.ritardando(measures: 1, factor: 0.5)
        let score = Self.score(
            bars: [
                [Self.chord(.whole, [60])],
                [
                    .spanner(ritardando), Self.chord(.quarter, [62]), Self.chord(.quarter, [64]),
                    Self.chord(.sixteenth, [65]), Self.caesura,
                    Self.chord(.quarter.dotted(1), [67]), Self.chord(.sixteenth, [69]),
                ],
            ],
            lane: [Self.tempo(0, 0, 2)],
        )
        let map = score.resolvedTempoMap()
        #expect(map.beatsPerSecond(atMeasure: 1, tickInMeasure: 1080) == 1.5)
        try Self.expectAgreement(score, onsets: [0, 1920, 2400, 2880, 3720, 4440])
    }

    @Test("a breath after an a tempo pauses at the tempo it reinstates, not the ramp's last step")
    func breathAfterATempo() throws {
        // | 𝅝 ♩ = 90 | 𝅝 rit. to half | a tempo: C♩ caesura D♩ E♩ F♩ |: the a tempo reinstates the text pass's last
        // tempo, 1.5 bps, not the ramp's last step; 1 × 1.5 × 480 = 720 ticks. Bar 2 starts at 3840: C 3840,
        // D at 3840 + 480 + 720 = 5040, E 5520, F 6000.
        let aTempo = Tempo(beatsPerSecond: 2, text: "a tempo", textType: .aTempo)
        let ritardando = TempoMapFixtures.ritardando(measures: 1, factor: 0.5)
        let score = Self.score(
            bars: [
                [Self.chord(.whole, [60])],
                [.spanner(ritardando), Self.chord(.whole, [62])],
                [
                    Self.chord(.quarter, [64]), Self.caesura, Self.chord(.quarter, [65]),
                    Self.chord(.quarter, [67]), Self.chord(.quarter, [69]),
                ],
            ],
            lane: [Self.tempo(0, 0, 1.5), TempoMapFixtures.tempo(2, 0, aTempo)],
        )
        let map = score.resolvedTempoMap()
        #expect(map.beatsPerSecond(atMeasure: 2, tickInMeasure: 480) == 1.5)
        let seconds = try Self.expectAgreement(score, onsets: [0, 1920, 3840, 5040, 5520, 6000])
        // C → D: the quarter's 480 ticks and the pause's 720, both at 1.5 bps = 2/3 s + 1 s.
        #expect(abs((seconds[3] - seconds[2]) - (2.0 / 3 + 1.0)) < 1e-3)
    }

    @Test("an arpeggio spreads at the map's tempo: absolute offsets at ♩ = 60, on every staff")
    func arpeggioReadsTheMapTempo() throws {
        // MuseScore `compatmidirender.cpp:305`: the spread scales by tempo / DEFAULT_TEMPO — 1 / 2 at ♩ = 60. A
        // whole-note chord of four (1920 ticks): l = 64 (64 × 4 ≤ 1920); note j's offset is
        // ot = (64 j × 1000 / 1920, integer) × 0.5, truncated = 0, 16, 33, 50; on = ot × 1920 / 1000 = 0, 30, 63, 96.
        // (At 120 BPM it would be 0, 63, 126, 192.) The next bar's G starts at 1920.
        let score = Self.score(
            bars: [[Self.chord(.whole, [60, 64, 67, 72], arpeggio: true)], [Self.chord(.whole, [67])]],
            lane: [Self.tempo(0, 0, 1)],
        )
        try Self.expectAgreement(score, onsets: [0, 30, 63, 96, 1920], frameTicks: [0, 1920])
    }
}
