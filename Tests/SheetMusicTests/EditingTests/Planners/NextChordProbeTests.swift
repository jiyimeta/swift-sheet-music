@testable import SheetMusicCore
import Testing

/// `NextChordProbe` — the two forward lookups group 4 shares: the two-note tremolo's in-measure partner and the
/// glissando's cross-measure destination.
@Suite("NextChordProbe")
struct NextChordProbeTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    @Test("the next timed element skips the marks between two chords")
    func skipsNonTimed() {
        var score = EditingFixtures.parityFixture()
        // m0: [ts, C4, D4, r, r] -> [ts, C4, dynamic, D4, r, r]
        score.parts[0].staves[0].measures[0].voices[0].elements
            .insert(.dynamic(Dynamic(subtype: "p", velocity: 49)), at: 2)
        let next = NextChordProbe.nextTimedElement(after: Self.slot(0, 1), in: score)
        #expect(next == .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])))
    }

    @Test("the next timed element does not cross the bar line")
    func stopsAtTheBarLine() {
        let score = EditingFixtures.parityFixture()
        // m0's last element is a rest; nothing follows it inside the bar.
        #expect(NextChordProbe.nextTimedElement(after: Self.slot(0, 4), in: score) == nil)
        // m2 is [E4 h, E4 h]: the tail has no in-bar follower.
        #expect(NextChordProbe.nextTimedElement(after: Self.slot(2, 1), in: score) == nil)
    }

    @Test("the next timed element may be a rest — the caller decides whether that is acceptable")
    func yieldsRests() {
        let score = EditingFixtures.parityFixture()
        #expect(NextChordProbe.nextTimedElement(after: Self.slot(0, 2), in: score) == .rest(duration: .quarter))
    }

    @Test("hasFollowingChord walks into later measures and wants a SOUNDING chord")
    func followingChordCrossesBars() {
        let score = EditingFixtures.parityFixture()
        // m0's C4 is followed by D4 in the same bar.
        #expect(NextChordProbe.hasFollowingChord(after: Self.slot(0, 1), in: score))
        // m0's D4 is followed only by rests in m0 and m1, but m2's tied E4s are chords.
        #expect(NextChordProbe.hasFollowingChord(after: Self.slot(0, 2), in: score))
        // m2's tail is the last sounding chord of the staff: m3 is a measure rest.
        #expect(!NextChordProbe.hasFollowingChord(after: Self.slot(2, 1), in: score))
    }

    @Test("a missing voice or element answers nil / false rather than trapping")
    func outOfRange() {
        let score = EditingFixtures.parityFixture()
        #expect(NextChordProbe.nextTimedElement(after: Self.slot(9, 0), in: score) == nil)
        #expect(!NextChordProbe.hasFollowingChord(after: Self.slot(0, 99), in: score))
    }
}
