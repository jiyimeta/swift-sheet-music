import Foundation
@testable import SheetMusicCore
import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// The tempo map's text pass is MuseScore's (`Score::rebuildTempoAndTimeSigMaps`, `engraving/dom/score.cpp:579-600`):
/// a muted marking sets nothing, "a tempo" reinstates the tempo in force where it stands, "tempo primo" the first
/// ordinary marking's — each only while it follows its text — and one position holds one point.
@Suite("Resolved tempo map — MuseScore's text rules")
struct ResolvedTempoMapRulesTests {
    private static func map(_ lane: [TempoMapFixtures.LaneEntry], measures: Int = 4) -> ResolvedTempoMap {
        TempoMapFixtures.score(measures: measures, lane: lane).resolvedTempoMap()
    }

    private static func quarter80() -> Tempo {
        Tempo(beatsPerSecond: 1.333333)
    }

    @Test("a marking left out of playback sets nothing")
    func mutedMarkingIsSkipped() {
        var muted = Tempo(beatsPerSecond: 3)
        muted.playsBack = false
        let map = Self.map([TempoMapFixtures.tempo(0, 0, Self.quarter80()), TempoMapFixtures.tempo(1, 0, muted)])
        #expect(map.points.map(\.measureIndex) == [0])
        #expect(map.beatsPerSecond(atMeasure: 1, tickInMeasure: 0) == 1.333333)
    }

    @Test("a tempo that follows its text reinstates the tempo in force where it stands")
    func aTempoReinstatesTheTempoBeforeIt() {
        let aTempo = Tempo(beatsPerSecond: 2, text: "a tempo", textType: .aTempo)
        let allegro = Tempo(beatsPerSecond: 2.4, text: "Allegro", followText: false)
        let map = Self.map([
            TempoMapFixtures.tempo(0, 0, Self.quarter80()),
            TempoMapFixtures.tempo(1, 0, allegro),
            TempoMapFixtures.tempo(2, 0, aTempo),
        ])
        #expect(map.beatsPerSecond(atMeasure: 2, tickInMeasure: 0) == 2.4)
        #expect(Self.map([TempoMapFixtures.tempo(0, 0, aTempo)]).points.first?.beatsPerSecond == 2)
    }

    @Test("a tempo that does not follow its text plays its own number")
    func aTempoWithoutFollowTextPlaysItsOwnNumber() {
        let aTempo = Tempo(beatsPerSecond: 1.5, text: "a tempo", followText: false, textType: .aTempo)
        let map = Self.map([TempoMapFixtures.tempo(0, 0, Self.quarter80()), TempoMapFixtures.tempo(1, 0, aTempo)])
        #expect(map.beatsPerSecond(atMeasure: 1, tickInMeasure: 0) == 1.5)
    }

    @Test("tempo primo brings back the first ordinary marking, in its beat")
    func tempoPrimoBringsBackTheFirstOrdinaryMarking() throws {
        let dotted = Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1)
        let primo = Tempo(beatsPerSecond: 2.5, text: "tempo primo", textType: .tempoPrimo)
        let map = Self.map([
            TempoMapFixtures.tempo(0, 0, dotted),
            TempoMapFixtures.tempo(1, 0, Tempo(beatsPerSecond: 3)),
            TempoMapFixtures.tempo(2, 0, primo),
        ])
        let point = try #require(map.point(inForceAtMeasure: 2, tickInMeasure: 0))
        #expect(point.beatsPerSecond == 2)
        #expect(point.beatDots == 1)
        #expect(point.beatsPerMinute == 80)
    }

    @Test("tempo primo with no ordinary marking before it is 120")
    func tempoPrimoWithoutAnOrdinaryMarkingIs120() {
        let primo = Tempo(beatsPerSecond: 2.5, text: "tempo primo", textType: .tempoPrimo)
        #expect(Self.map([TempoMapFixtures.tempo(1, 0, primo)]).points.first?.beatsPerSecond == 2)
    }

    @Test("a muted marking is never tempo primo")
    func mutedMarkingIsNotPrimo() {
        var muted = Tempo(beatsPerSecond: 3)
        muted.playsBack = false
        let primo = Tempo(beatsPerSecond: 2.5, text: "tempo primo", textType: .tempoPrimo)
        let map = Self.map([
            TempoMapFixtures.tempo(0, 0, muted),
            TempoMapFixtures.tempo(1, 0, Tempo(beatsPerSecond: 1.5)),
            TempoMapFixtures.tempo(2, 0, primo),
        ])
        #expect(map.beatsPerSecond(atMeasure: 2, tickInMeasure: 0) == 1.5)
    }

    @Test("one position holds one point: the last marking there wins")
    func onePointPerPositionLastWins() {
        let map = Self.map([
            TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2)),
            TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 1)),
        ])
        #expect(map.points.map(\.beatsPerSecond) == [1])
    }

    @Test("what plays is the map's point; the governing marking is still the marking")
    func effectiveTempoIsWhatPlays() throws {
        let score = TempoMapFixtures.score(measures: 3, lane: [
            TempoMapFixtures.tempo(0, 0, Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1)),
            TempoMapFixtures.tempo(1, 0, Tempo(beatsPerSecond: 3)),
            TempoMapFixtures.tempo(2, 0, Tempo(beatsPerSecond: 2.5, text: "tempo primo", textType: .tempoPrimo)),
        ])
        let cursor = ScoreCursor.beat(measureIndex: 2, tickInMeasure: 240)
        let playing = try #require(score.effectiveTempo(at: cursor))
        #expect(playing.beatsPerMinute == 80)
        #expect(score.effectiveQuarterBpm(at: cursor) == 120)
        #expect(score.governingTempo(at: cursor)?.textType == .tempoPrimo)
        #expect(score.effectiveTempo(at: nil)?.beatDots == 1)
    }

    /// `tempo-texts`: ♩=80 | — | a tempo | Allegro (no follow) | tempo primo | ♩=♪ | muted ♩=180 | Allegro ♩=144 |
    /// ♩.=80 | hidden 150 | Lento ♩=50 — what MuseScore 4 plays for each.
    @Test("the tempo-texts fixture plays what MuseScore plays")
    func fixtureMatchesMuseScore() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("tempo-texts"))
        let map = score.resolvedTempoMap()
        #expect(map.points.map(\.measureIndex) == [0, 2, 3, 4, 5, 7, 8, 9, 10])
        #expect(map.points.map(\.beatsPerSecond) == [
            1.333333, 1.333333, 2.4, 1.333333, 0.666667, 2.4, 2, 2.5, 0.833333,
        ])
    }

    /// The reported bug, end to end: MuseScore's "a tempo" (measure 2) after ♩ = 80 stores a meaningless
    /// `<tempo>2</tempo>`; the SMF must carry 80 BPM (750000 µs per quarter) at that downbeat, not 120 (500000), and
    /// so must the BPM readout.
    @Test("a MuseScore file's \"a tempo\" after ♩ = 80 plays 80 in the SMF, not 120")
    func aTempoAfterEightyPlaysEightyInTheSMF() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("tempo-texts"))
        let midi = try MidiRenderer.render(score: score)
        let events = midi.tracks.first?.events ?? []
        let measureTwoTick = 2 * 4 * score.division
        let atMeasureTwo = events.compactMap { timed -> Int? in
            guard timed.tick == measureTwoTick, case let .meta(.tempo(micros)) = timed.event else { return nil }
            return micros
        }
        #expect(atMeasureTwo == [750_000])
        let bpm = score.effectiveQuarterBpm(at: .beat(measureIndex: 2, tickInMeasure: 0))
        #expect(abs(bpm - 80) < 0.001)
    }
}
