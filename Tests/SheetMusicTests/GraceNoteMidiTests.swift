@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite("MidiRenderer.playbackTicks")
struct GracePlaybackTicksTests {
    private let division = 480 // PPQ used by every other MIDI test

    @Test("acciaccatura → 1/32 of a quarter note (= division/8)")
    func acciaccatura() {
        let g = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        #expect(MidiRenderer.playbackTicks(
            for: g, mainTicks: division, division: division
        ) == division / 8)
    }

    @Test("appoggiatura → half of mainTicks")
    func appoggiatura() {
        let g = GraceChord(graceType: .appoggiatura, duration: .quarter, notes: [])
        #expect(MidiRenderer.playbackTicks(
            for: g, mainTicks: division, division: division
        ) == division / 2)
    }

    @Test("grace4 / grace16 / grace32 use fixed durations")
    func fixedFractions() {
        let mk = { (gt: GraceType) in
            GraceChord(graceType: gt, duration: .eighth, notes: [])
        }
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace4), mainTicks: division, division: division
        ) == division)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace16), mainTicks: division, division: division
        ) == division / 4)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace32), mainTicks: division, division: division
        ) == division / 8)
    }

    @Test("grace8/16/32after use 1/8, 1/16, 1/32 of a quarter")
    func afterFixed() {
        let mk = { (gt: GraceType) in
            GraceChord(graceType: gt, duration: .eighth, notes: [])
        }
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace8after), mainTicks: division, division: division
        ) == division / 2)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace16after), mainTicks: division, division: division
        ) == division / 4)
        #expect(MidiRenderer.playbackTicks(
            for: mk(.grace32after), mainTicks: division, division: division
        ) == division / 8)
    }
}

@Suite("MidiRenderer.totalSteal")
struct GraceTotalStealTests {
    private let division = 480

    @Test("totalStealFromPrev = sum of acciaccatura ticks only")
    func stealPrev() {
        let g1 = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        let g2 = GraceChord(graceType: .grace16, duration: .sixteenth, notes: [])
        #expect(MidiRenderer.totalStealFromPrev([g1, g2], division: division)
            == division / 8)
    }

    @Test("totalStealFromMainHead = sum of non-acciaccatura before-grace ticks")
    func stealHead() {
        let g1 = GraceChord(graceType: .acciaccatura, duration: .eighth, notes: [])
        let g2 = GraceChord(graceType: .grace16, duration: .sixteenth, notes: [])
        #expect(MidiRenderer.totalStealFromMainHead(
            [g1, g2], mainTicks: division, division: division
        ) == division / 4)
    }

    @Test("Head steal capped at mainTicks/2 when graces overflow")
    func headCap() {
        // Three grace4 → 3 * 480 = 1440, but main is 480 → cap to 240.
        let four = (0 ..< 3).map { _ in
            GraceChord(graceType: .grace4, duration: .quarter, notes: [])
        }
        #expect(MidiRenderer.totalStealFromMainHead(
            four, mainTicks: division, division: division
        ) == division / 2)
    }

    @Test("totalStealFromMainTail sums after-grace ticks (capped at half)")
    func stealTail() {
        let g = GraceChord(graceType: .grace8after, duration: .eighth, notes: [])
        #expect(MidiRenderer.totalStealFromMainTail(
            [g], mainTicks: division, division: division
        ) == division / 2)
        let many = (0 ..< 4).map { _ in g }
        #expect(MidiRenderer.totalStealFromMainTail(
            many, mainTicks: division, division: division
        ) == division / 2) // capped
    }
}
