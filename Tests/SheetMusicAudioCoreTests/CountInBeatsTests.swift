import Foundation
@testable import SheetMusicAudioCore
import SheetMusicCore
import Testing

struct CountInBeatsTests {
    /// division 480 throughout.
    private static let division = 480

    /// Build a score whose measures each declare `ts` (as the first voice-0 element) and that carries
    /// `beatsPerSecond` tempo from the start. `anacrusisActualLength`/`anacrusisIrregular` shorten measure 0
    /// via the MuseScore encoding; `anacrusisContent` appends real voice-0 timed elements to measure 0 so the
    /// MusicXML content-sum pickup encoding (no `actualLength`, not `irregular`) can be exercised.
    private static func score(
        measureCount: Int,
        ts: TimeSignature = TimeSignature(numerator: 4, denominator: 4),
        beatsPerSecond: Double = 2.0,
        anacrusisActualLength: Fraction? = nil,
        anacrusisIrregular: Bool = false,
        anacrusisContent: [VoiceElement] = [],
        tsChanges: [Int: TimeSignature] = [:],
    ) -> Score {
        var measures: [Measure] = []
        for i in 0 ..< measureCount {
            let measureTS = tsChanges[i] ?? (i == 0 ? ts : nil)
            var elements: [VoiceElement] = []
            if let measureTS { elements.append(.timeSignature(measureTS)) }
            if i == 0 { elements.append(contentsOf: anacrusisContent) }
            if i == 0, anacrusisActualLength != nil || anacrusisIrregular {
                measures.append(Measure(
                    voices: [Voice(elements: elements)],
                    actualLength: anacrusisActualLength,
                    irregular: anacrusisIrregular,
                ))
            } else {
                measures.append(Measure(voices: [Voice(elements: elements)]))
            }
        }
        let part = Part(
            id: "P0",
            instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
            staves: [Staff(measures: measures)],
        )
        let systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: beatsPerSecond))),
        ])] + Array(repeating: SystemMeasure(), count: max(0, measureCount - 1))
        return Score(division: division, parts: [part], systemMeasures: systemMeasures, metaTags: [:])
    }

    @Test func fourFourFromMeasureStartYieldsFourClicksOneStrong() {
        let result = CountInBeats.compute(
            score: Self.score(measureCount: 4),
            startCursor: .beat(measureIndex: 2, tickInMeasure: 0),
        )
        #expect(result?.preRollTicks == 1920)
        #expect(result?.beats.count == 4)
        #expect(result?.beats.map(\.isDownbeat) == [true, false, false, false])
    }

    @Test func midMeasureLeadInAtBeatThreeYieldsSixClicks() { // the spec example
        let result = CountInBeats.compute(
            score: Self.score(measureCount: 4),
            startCursor: .beat(measureIndex: 1, tickInMeasure: 960),
        )
        #expect(result?.preRollTicks == 2880)
        #expect(result?.beats.count == 6)
        #expect(result?.beats.map(\.isDownbeat) == [true, false, false, false, true, false])
    }

    @Test func threeFourStartOnBeatTwo() {
        let result = CountInBeats.compute(
            score: Self.score(measureCount: 3, ts: TimeSignature(numerator: 3, denominator: 4)),
            startCursor: .beat(measureIndex: 1, tickInMeasure: 480),
        )
        #expect(result?.preRollTicks == 1920)
        #expect(result?.beats.count == 4)
        #expect(result?.beats.map(\.isDownbeat) == [true, false, false, true])
    }

    @Test func compoundSixEightClicksAtEighthSpacing() {
        let result = CountInBeats.compute(
            score: Self.score(measureCount: 2, ts: TimeSignature(numerator: 6, denominator: 8)),
            startCursor: .beat(measureIndex: 0, tickInMeasure: 0),
        )
        #expect(result?.preRollTicks == 1440)
        #expect(result?.beats.count == 6)
        #expect(result?.beats.map(\.tick) == [0, 240, 480, 720, 960, 1200])
        #expect(result?.beats.map(\.isDownbeat) == [true, false, false, false, false, false])
    }

    @Test func cutTimeTwoTwoClicksAtHalfNoteSpacing() {
        let result = CountInBeats.compute(
            score: Self.score(measureCount: 2, ts: TimeSignature(numerator: 2, denominator: 2)),
            startCursor: .beat(measureIndex: 0, tickInMeasure: 0),
        )
        #expect(result?.preRollTicks == 1920)
        #expect(result?.beats.count == 2)
        #expect(result?.beats.map(\.tick) == [0, 960])
    }

    @Test func museScoreAnacrusisRightAlignsThePickupAsAnUpbeat() {
        // 4/4, 1-beat pickup: 1-2-3-4 | 1-2-3 [pickup] = 7 clicks, strong at 0 and 4.
        let result = CountInBeats.compute(
            score: Self.score(
                measureCount: 3,
                anacrusisActualLength: Fraction(numerator: 1, denominator: 4),
                anacrusisIrregular: true,
            ),
            startCursor: .beat(measureIndex: 0, tickInMeasure: 0),
        )
        #expect(result?.preRollTicks == 3360)
        #expect(result?.beats.count == 7)
        #expect(result?.beats.map(\.isDownbeat) == [true, false, false, false, true, false, false])
    }

    @Test func musicXMLAnacrusisRightAlignsViaContentSum() {
        // MusicXML pickup: measure 0 carries one quarter of real content (480 of 1920 nominal ticks), with
        // NO actualLength and NOT irregular. The content-sum fallback must detect 480 < 1920 ⇒ shim 1440,
        // yielding the SAME upbeat right-alignment as the MuseScore encoding: 7 clicks, strong at 0 and 4.
        let result = CountInBeats.compute(
            score: Self.score(measureCount: 3, anacrusisContent: [.rest(duration: .quarter)]),
            startCursor: .beat(measureIndex: 0, tickInMeasure: 0),
        )
        #expect(result?.preRollTicks == 3360)
        #expect(result?.beats.count == 7)
        #expect(result?.beats.map(\.isDownbeat) == [true, false, false, false, true, false, false])
    }

    @Test func pickupStartMidPieceAppliesNoShim() {
        let result = CountInBeats.compute(
            score: Self.score(
                measureCount: 3,
                anacrusisActualLength: Fraction(numerator: 1, denominator: 4),
                anacrusisIrregular: true,
            ),
            startCursor: .beat(measureIndex: 2, tickInMeasure: 0),
        )
        #expect(result?.preRollTicks == 1920)
        #expect(result?.beats.count == 4)
    }

    @Test func readsTheStartMeasureMeterAcrossAMidScoreChange() {
        // m0-m2 in 4/4, m3 in 3/4; starting at m3 must count 3, not 4 (proves not-always-m2).
        let result = CountInBeats.compute(
            score: Self.score(measureCount: 4, tsChanges: [
                0: TimeSignature(numerator: 4, denominator: 4),
                3: TimeSignature(numerator: 3, denominator: 4),
            ]),
            startCursor: .beat(measureIndex: 3, tickInMeasure: 0),
        )
        #expect(result?.preRollTicks == 1440)
        #expect(result?.beats.count == 3)
    }

    @Test func quarterBpmReflectsTheTempoAtTheStartCursor() {
        let result = CountInBeats.compute(
            score: Self.score(measureCount: 2, beatsPerSecond: 2.0), // 2.0 beats/sec == 120 BPM
            startCursor: .beat(measureIndex: 0, tickInMeasure: 0),
        )
        #expect(result?.quarterBpm == 120.0)
    }

    @Test func emptyScoreReturnsNil() {
        let empty = Score(division: 480, parts: [], systemMeasures: [], metaTags: [:])
        #expect(CountInBeats.compute(score: empty, startCursor: nil) == nil)
    }
}
