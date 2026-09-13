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

    /// A 4/4 bar with two voices. Voice 0 is a dotted half turned into a 3:2 triplet — members at ticks 0, 480
    /// and 960, each 480 long — followed by a plain quarter. Voice 1 is eight eighth rests, and the range is
    /// anchored on those: elements 0 through 4 run from tick 0 to tick 1200, so every triplet member's ONSET
    /// falls inside the range while the last member's END (1440) is 240 ticks past it.
    private static func tripletUnderAShorterRange() throws -> Score {
        let triplet = Voice(elements: [
            .chord(Chord(
                duration: .fraction(Fraction(numerator: 3, denominator: 4)), notes: [Note(pitch: 60, tpc: 14)],
            )),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ])
        let anchor = Voice(elements: (0 ..< 8).map { _ in VoiceElement.rest(duration: .eighth) })
        let staff = Staff(defaultClefType: "G", measures: [Measure(voices: [triplet, anchor])])
        var score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        _ = try CreateTuplet(at: Self.slot(0, 0), actualNotes: 3, normalNotes: 2).apply(to: &score)
        return score
    }

    @Test("a tuplet member sounding past the range's end is copied whole, not clamped")
    func tupletMemberExemptFromTheRangeEndClamp() throws {
        let score = try Self.tripletUnderAShorterRange()
        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 0, voice: 1), end: Self.slot(0, 4, voice: 1)),
            in: score,
        ))
        #expect(source.lengthTicks == 1200)
        let triplet = try #require(source.streams.first { $0.voiceIndex == 0 })
        // `read460.cpp:626-629` exempts a ChordRest inside a tuplet from the shorten-the-last-CR step ("we
        // don't allow copy of partial tuplet anyhow"). Clamping the last member would truncate and re-spell
        // it, leaving the carried bracket naming a member count the voice no longer has.
        #expect(triplet.elements.map(\.lengthTicks) == [480, 480, 480])
        let bracket = try #require(triplet.tuplets.first)
        #expect(bracket.startTick == 0)
        #expect(bracket.endTick == 1440)
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

    /// One 4/4 bar of four quarters carrying, besides the notes, a mid-bar clef and dynamic at tick 480, a key
    /// signature and a barline at tick 960, and a second dynamic at tick 960. MuseScore's paste accepts the clef
    /// and the annotation list (`read460.cpp:664-715`) and silently drops key signature, time signature, barline
    /// and rehearsal mark (`739-744`), so a copy that carried the latter would state something the paste never
    /// states.
    ///
    /// The second dynamic is what makes a range ending at tick 960 test its own end bound: it is COPYABLE and it
    /// sits exactly on the boundary, where the key signature and barline beside it would be refused on kind
    /// alone no matter how the bound were written.
    private static func barWithNonTimedElements() -> Score {
        let staff = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .clef(Clef(concertClefType: "F")),
                .dynamic(Dynamic(subtype: "mf", velocity: 64)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
                .keySignature(KeySignature(concertKey: 2)),
                .barLine(BarLine(subtype: "double")),
                .dynamic(Dynamic(subtype: "f", velocity: 96)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 19)])),
            ])]),
        ])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    @Test("the range's clefs and annotations are carried; the kinds MuseScore's paste drops are not")
    func carriesNonTimedElements() throws {
        let score = Self.barWithNonTimedElements()
        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 8)), in: score,
        ))
        let stream = try #require(source.streams.first)
        // The clef and the dynamic both stand at tick 480, ahead of the note whose segment they attach to.
        #expect(stream.elements.map(\.absoluteTick) == [0, 480, 480, 480, 960, 960, 1440])
        #expect(stream.elements.map(\.element) == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .clef(Clef(concertClefType: "F")),
            .dynamic(Dynamic(subtype: "mf", velocity: 64)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .dynamic(Dynamic(subtype: "f", velocity: 96)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 19)])),
        ])
        // A non-timed element carries no length of its own; nothing resolves a duration for it.
        #expect(stream.elements.map(\.lengthTicks) == [480, 0, 0, 480, 0, 480, 480])
    }

    @Test("a copyable non-timed element sitting exactly on the range's end tick is not carried")
    func leavesNonTimedElementsAtTheRangeEnd() throws {
        let score = Self.barWithNonTimedElements()
        // Beats 1-2 only: [0, 960). The clef and the "mf" at tick 480 are inside it; the "f" at tick 960 is a
        // kind this copy DOES carry, standing exactly on the end bound, so only the bound can keep it out.
        let source = try #require(try RangeCopySource(
            range: VoiceElementRange(start: Self.slot(0, 0), end: Self.slot(0, 3)), in: score,
        ))
        let stream = try #require(source.streams.first)
        #expect(stream.elements.map(\.absoluteTick) == [0, 480, 480, 480])
        let dynamicSubtypes = stream.elements.compactMap { copied -> String? in
            guard case let .dynamic(dynamic) = copied.element else { return nil }
            return dynamic.subtype
        }
        #expect(dynamicSubtypes == ["mf"])
        let clefCount = stream.elements.filter { if case .clef = $0.element { true } else { false } }.count
        #expect(clefCount == 1)
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
