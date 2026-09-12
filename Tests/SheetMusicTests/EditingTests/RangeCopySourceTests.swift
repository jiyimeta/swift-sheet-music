@testable import SheetMusicCore
import Testing

@Suite("RangeCopySource")
struct RangeCopySourceTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0, staff: StaffAddress = flute)
        -> VoiceElementID
    {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    @Test("two beats of one voice become one stream with absolute ticks")
    func twoBeats() throws {
        let score = EditingFixtures.parityFixture()
        let source = try #require(RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 2)), in: score,
        ))
        #expect(source.startTick == 0)
        #expect(source.lengthTicks == 960)
        #expect(source.streams.count == 1)
        let stream = try #require(source.streams.first)
        #expect(stream.staff == Self.flute)
        #expect(stream.voiceIndex == 0)
        #expect(stream.elements.map(\.absoluteTick) == [0, 480])
        #expect(stream.elements.map(\.element) == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ])
        #expect(stream.tuplets.isEmpty)
    }

    @Test("a range covering two staves yields a stream per staff")
    func twoStaves() throws {
        let score = EditingFixtures.parityFixture()
        let source = try #require(RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 1, staff: Self.cello)), in: score,
        ))
        #expect(source.staves == [Self.flute, Self.cello])
        #expect(Set(source.streams.map(\.staff)) == [Self.flute, Self.cello])
    }

    @Test("a bar with two voices yields a stream per voice")
    func twoVoices() throws {
        let score = EditingFixtures.parityFixture()
        let source = try #require(RangeCopySource(
            range: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 3)), in: score,
        ))
        let flute = source.streams.filter { $0.staff == Self.flute }
        #expect(Set(flute.map(\.voiceIndex)) == [0, 1])
    }

    @Test("a tuplet inside the range is reported with absolute tick bounds")
    func tupletBounds() throws {
        var score = EditingFixtures.parityFixture()
        _ = try CreateTuplet(at: Self.slot(0, 1), actualNotes: 3, normalNotes: 2).apply(to: &score)
        let source = try #require(RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 3)), in: score,
        ))
        let stream = try #require(source.streams.first)
        #expect(stream.tuplets.count == 1)
        let tuplet = try #require(stream.tuplets.first)
        #expect(tuplet.startTick == 0)
        #expect(tuplet.endTick == 480)
        #expect(tuplet.actualNotes == 3)
        #expect(tuplet.normalNotes == 2)
    }

    @Test("a whole-bar rest is measured, not crashed on")
    func measureRestLength() throws {
        let score = EditingFixtures.parityFixture()
        let source = try #require(RangeCopySource(
            range: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)), in: score,
        ))
        let stream = try #require(source.streams.first)
        #expect(stream.elements.map(\.lengthTicks) == [1920])
    }

    @Test("the copy's outer ties are cleared and inner ones kept")
    func outerTiesCleared() throws {
        let score = EditingFixtures.parityFixture() // bar 2 is two tied E4 halves
        let source = try #require(RangeCopySource(
            range: VoiceElementRange(start: Self.slot(2, 0), end: Self.slot(2, 1)), in: score,
        ))
        let stream = try #require(source.streams.first)
        guard case let .chord(first) = stream.elements[0].element,
              case let .chord(second) = stream.elements[1].element
        else { Issue.record("expected chords"); return }
        #expect(first.notes[0].tieBack == nil)
        #expect(first.notes[0].tieForward == 1)
        #expect(second.notes[0].tieBack == 1)
        #expect(second.notes[0].tieForward == nil)
    }

    @Test("a range that resolves to nothing yields nil")
    func unresolvable() {
        let score = EditingFixtures.parityFixture()
        #expect(RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0)), in: score,
        ) == nil)
    }
}
