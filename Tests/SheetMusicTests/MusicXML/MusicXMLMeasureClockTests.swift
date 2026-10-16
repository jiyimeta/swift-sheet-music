import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML measure clock")
struct MusicXMLMeasureClockTests {
    private static func quarters(_ count: Int) -> Fraction {
        Fraction(numerator: count, denominator: 4)
    }

    @Test("notes advance the clock and the furthest point with it")
    func advances() {
        var clock = MusicXMLMeasureClock()
        clock.advance(by: Self.quarters(2))
        #expect(clock.now == Self.quarters(2))
        #expect(clock.furthest == Self.quarters(2))
    }

    @Test("a backup moves back and the furthest point stays")
    func backupKeepsFurthest() {
        var clock = MusicXMLMeasureClock()
        clock.advance(by: Self.quarters(4))
        clock.backup(by: Self.quarters(3), divisionsPerQuarter: 480)
        #expect(clock.now == Self.quarters(1))
        #expect(clock.furthest == Self.quarters(4))
    }

    @Test("a backup past the start stops at the start")
    func backupClamps() {
        var clock = MusicXMLMeasureClock()
        clock.advance(by: Self.quarters(1))
        clock.backup(by: Self.quarters(2), divisionsPerQuarter: 480)
        #expect(clock.now == Fraction.zeroTick)
        #expect(clock.furthest == Self.quarters(1))
    }

    @Test("a backup that leaves less than one division snaps to the start")
    func tinyRemainderSnaps() {
        var clock = MusicXMLMeasureClock()
        clock.advance(by: Self.quarters(1))
        clock.backup(by: Fraction(numerator: 999, denominator: 4000), divisionsPerQuarter: 480)
        #expect(clock.now == Fraction.zeroTick)
        #expect(clock.furthest == Self.quarters(1))
    }
}
