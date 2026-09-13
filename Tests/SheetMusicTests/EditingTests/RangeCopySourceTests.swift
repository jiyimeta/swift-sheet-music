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
        let source = try #require(try RangeCopySource(
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
        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 1, staff: Self.cello)), in: score,
        ))
        #expect(source.staves == [Self.flute, Self.cello])
        #expect(Set(source.streams.map(\.staff)) == [Self.flute, Self.cello])
    }

    @Test("a bar with two voices yields a stream per voice")
    func twoVoices() throws {
        let score = EditingFixtures.parityFixture()
        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(1, 0), end: Self.slot(1, 3)), in: score,
        ))
        let flute = source.streams.filter { $0.staff == Self.flute }
        #expect(Set(flute.map(\.voiceIndex)) == [0, 1])
    }

    @Test("a tuplet inside the range is reported with absolute tick bounds")
    func tupletBounds() throws {
        var score = EditingFixtures.parityFixture()
        _ = try CreateTuplet(at: Self.slot(0, 1), actualNotes: 3, normalNotes: 2).apply(to: &score)
        let source = try #require(try RangeCopySource(
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
        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(3, 0), end: Self.slot(3, 0)), in: score,
        ))
        let stream = try #require(source.streams.first)
        #expect(stream.elements.map(\.lengthTicks) == [1920])
    }

    /// A 4/4 bar with two voices: voice 1 is four quarters (beats 1-4); voice 0 is two quarter rests (beats 1-2),
    /// a quarter rest (beat 3), then a half note starting on beat 4 that runs 480 ticks past the bar itself. The
    /// range is anchored on voice 1's beats 3-4 (elements 2 and 3, tick 960 to 1920) — since `voiceElements(in:)`
    /// selects by onset across every voice, that also picks up voice 0's beat-3 rest and beat-4 half note, whose
    /// onset (1440) is inside the range even though it sounds through tick 2400, 480 ticks past the range's own
    /// end (1920).
    @Test("an element that sounds past the range's end is clamped to what remains, not copied whole")
    func lastElementClampedToRangeEnd() throws {
        let overhanging = Voice(elements: [
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
        ])
        let anchor = Voice(elements: [
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        let staff = Staff(defaultClefType: "G", measures: [Measure(voices: [overhanging, anchor])])
        let score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        let range = VoiceElementRange(
            start: Self.slot(0, 2, voice: 1), end: Self.slot(0, 3, voice: 1),
        )
        let source = try #require(try RangeCopySource(range: range, in: score))
        #expect(source.lengthTicks == 960)
        let overhangingStream = try #require(source.streams.first { $0.voiceIndex == 0 })
        #expect(overhangingStream.elements.map(\.absoluteTick) == [960, 1440])
        let last = try #require(overhangingStream.elements.last)
        #expect(last.lengthTicks == 480)
        #expect(last.element == .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])))
    }

    @Test("the copy's outer ties are cleared and inner ones kept")
    func outerTiesCleared() throws {
        let score = EditingFixtures.parityFixture() // bar 2 is two tied E4 halves
        let source = try #require(try RangeCopySource(
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
    func unresolvable() throws {
        let score = EditingFixtures.parityFixture()
        #expect(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(9, 0)), in: score,
        ) == nil)
    }

    /// A dotted half (three quarter beats) turned into a triplet, followed by a plain quarter. The triplet's
    /// members land at indices 0-2; the quarter is index 3.
    private static func tripletThenQuarter() throws -> Score {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .chord(Chord(
                    duration: .fraction(Fraction(numerator: 3, denominator: 4)), notes: [Note(pitch: 60, tpc: 14)],
                )),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            ])]),
        ])
        var score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        _ = try CreateTuplet(at: Self.slot(0, 0), actualNotes: 3, normalNotes: 2).apply(to: &score)
        return score
    }

    @Test("a range starting inside a tuplet is refused")
    func refusesTupletCutAtStart() throws {
        let score = try Self.tripletThenQuarter()
        // Second triplet member (index 1) through the trailing quarter (index 3): the range's low bound
        // lands after the tuplet's first member, so the tuplet is only partly covered.
        #expect(throws: SheetMusicError.self) {
            _ = try RangeCopySource(
                range: VoiceElementRange(start: Self.slot(0, 1), end: Self.slot(0, 3)), in: score,
            )
        }
    }

    @Test("a range covering a whole tuplet plus what follows is not refused")
    func toleratesWholeTupletPlusFollowingBeat() throws {
        let score = try Self.tripletThenQuarter()
        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 3)), in: score,
        ))
        let stream = try #require(source.streams.first)
        #expect(stream.tuplets.count == 1)
    }

    /// One measure, one voice, one chord carrying a non-empty `spanners` — built locally rather than by
    /// mutating the shared fixture, so `twoBeats`'s expected `Chord` literals keep meaning "no spanners".
    @Test("a chord's spanners are cleared on copy")
    func spannersCleared() throws {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 60, tpc: 14)],
                    spanners: [Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 1)],
                )),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            ])]),
        ])
        let score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 0)), in: score,
        ))
        let stream = try #require(source.streams.first)
        guard case let .chord(copied) = stream.elements[0].element else {
            Issue.record("expected a chord")
            return
        }
        #expect(copied.spanners.isEmpty)
    }

    /// Two measures, one voice: `Voice` (and `VoiceRef`) is scoped to a single measure, so this exercises the
    /// re-keying to (staff, voice) that stitches a stream across a bar line, plus the per-measure tuplet lookup
    /// landing its bounds on the SECOND measure's absolute ticks.
    @Test("a single voice spanning two measures stays one stream, ascending across the bar line")
    func twoMeasureSingleVoiceStream() throws {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            ])]),
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
            ])]),
        ])
        var score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        _ = try CreateTuplet(at: Self.slot(1, 0), actualNotes: 3, normalNotes: 2).apply(to: &score)

        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(1, 2)), in: score,
        ))
        #expect(source.streams.count == 1)
        let stream = try #require(source.streams.first)
        #expect(stream.staff == Self.flute)
        #expect(stream.voiceIndex == 0)
        #expect(stream.elements.map(\.absoluteTick) == [0, 480, 1920, 2080, 2240])
        #expect(stream.tuplets.count == 1)
        let tuplet = try #require(stream.tuplets.first)
        #expect(tuplet.startTick == 1920)
        #expect(tuplet.endTick == 2400)
        #expect(tuplet.normalNotes == 2)
        #expect(tuplet.actualNotes == 3)
    }
}
