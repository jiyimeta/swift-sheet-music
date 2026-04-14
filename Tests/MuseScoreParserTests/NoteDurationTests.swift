@testable import MuseScoreParser
import Testing

@Suite struct NoteDurationTests {
    @Test func quarterTicksAtPPQ480() {
        #expect(NoteDuration.quarter.ticks(division: 480) == 480)
    }

    @Test func wholeIs4Quarters() {
        #expect(NoteDuration.whole.ticks(division: 480) == 1920)
    }

    @Test func sixteenthIsQuarterOver4() {
        #expect(NoteDuration.sixteenth.ticks(division: 480) == 120)
    }

    @Test func decodesFromMscxName() {
        #expect(NoteDuration(mscxName: "quarter") == .quarter)
        #expect(NoteDuration(mscxName: "16th") == .sixteenth)
        #expect(NoteDuration(mscxName: "eighth") == .eighth)
        #expect(NoteDuration(mscxName: "half") == .half)
        #expect(NoteDuration(mscxName: "whole") == .whole)
        #expect(NoteDuration(mscxName: "32nd") == .thirtySecond)
        #expect(NoteDuration(mscxName: "64th") == .sixtyFourth)
        #expect(NoteDuration(mscxName: "tubaesque") == nil)
    }
}
