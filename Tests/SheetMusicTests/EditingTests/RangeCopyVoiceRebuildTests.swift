@testable import SheetMusicCore
import Testing

@Suite("RangeCopyVoiceRebuild")
struct RangeCopyVoiceRebuildTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func quarter(_ pitch: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private static func piece(
        measure: Int, start: Int, elements: [VoiceElement],
        tuplets: [(range: ClosedRange<Int>, normalNotes: Int, actualNotes: Int)] = [],
    ) -> RangeCopyPlacement.Piece {
        RangeCopyPlacement.Piece(
            measureIndex: measure, startTickInMeasure: start, elements: elements, tuplets: tuplets,
        )
    }

    private static func voice(_ score: Score, _ measure: Int, _ index: Int = 0) -> Voice {
        score.parts[0].staves[0].measures[measure].voices[index]
    }

    /// The fixture is built from raw values, so every slot starts unassigned. A rebuild keeps surviving
    /// elements by identifier, so the destination has to carry real ones before a command can name them.
    private static func identifiedFixture() -> Score {
        var score = EditingFixtures.parityFixture()
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        return score
    }

    @Test("the piece replaces its tick span and leaves the rest of the bar alone")
    func replacesSpan() throws {
        var score = Self.identifiedFixture()
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(measure: 0, start: 960, elements: [Self.quarter(60), Self.quarter(62)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        #expect(Self.voice(score, 0).elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            Self.quarter(60), Self.quarter(62),
        ])
    }

    @Test("the destination elements the span does not reach keep their identifiers")
    func keepsSurvivingIdentifiers() throws {
        var score = Self.identifiedFixture()
        let before = Self.voice(score, 0).elements
        let survivors = (0 ... 2).map { before.eid(at: $0) }
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(measure: 0, start: 960, elements: [Self.quarter(60), Self.quarter(62)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let after = Self.voice(score, 0).elements
        #expect((0 ... 2).map { after.eid(at: $0) } == survivors)
        // The copied material must not reuse a destination identifier.
        #expect(!survivors.contains(after.eid(at: 3)))
        #expect(!survivors.contains(after.eid(at: 4)))
    }

    @Test("a boundary element the span half-covers is trimmed, and its head keeps its identity")
    func trimsBoundaryElements() throws {
        var score = Self.identifiedFixture()
        let headEID = Self.voice(score, 0).elements.eid(at: 3)
        // [1200, 1680) cuts the quarter rest at 960 and the quarter rest at 1440.
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(measure: 0, start: 1200, elements: [Self.quarter(60)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let elements = Self.voice(score, 0).elements
        // timeSig, q60, q62, leading trim (960..1200), the copy (1200..1680), trailing trim (1680..1920).
        #expect(elements.count == 6)
        #expect(elements.eid(at: 3) == headEID)
        #expect(elements[3] == .rest(duration: .eighth))
        #expect(elements[4] == Self.quarter(60))
        #expect(elements[5] == .rest(duration: .eighth))
        // The bar still adds up to 1920 ticks.
        let total = elements.values.reduce(0) { $0 + ($1.tickCount(division: 480) ?? 0) }
        #expect(total == 1920)
    }

    @Test("no tie crosses into or out of the copied material")
    func trimsCarryNoTieIntoTheCopy() throws {
        var score = Self.identifiedFixture()
        // Measure 2 voice 0 is two tied half notes. [1200, 1680) cuts the second one at both ends, so the
        // leading trim's head and the trailing trim's first piece both abut the copy.
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(measure: 2, start: 1200, elements: [Self.quarter(60)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let elements = Self.voice(score, 2).elements
        #expect(elements.count == 4)
        guard case let .chord(head) = elements[1], case let .chord(tail) = elements[3] else {
            Issue.record("the boundary element should have been trimmed on both sides")
            return
        }
        #expect(head.duration == .eighth)
        // The copy is not this note's continuation, so the head must not tie into it...
        #expect(head.notes[0].tieForward == nil)
        // ...while the partner it really has, in front of the span, is untouched.
        #expect(head.notes[0].tieBack == 1)
        #expect(elements[2] == Self.quarter(60))
        // Symmetrically, nothing ties back out of the copy into the trailing trim.
        #expect(tail.notes[0].tieBack == nil)
    }

    @Test("a multi-piece leading trim stays tied inside itself and stops at the copy")
    func multiPieceTrimTiesOnlyInsideItself() throws {
        var score = Self.identifiedFixture()
        // [720, 1200) cuts the FIRST half note of measure 2, whose remainder needs a quarter plus an eighth.
        // That source note carries `tieForward = 1` into its partner — which the copy now overwrites.
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(measure: 2, start: 720, elements: [Self.quarter(60)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let elements = Self.voice(score, 2).elements
        #expect(elements.count == 5)
        guard case let .chord(head) = elements[0], case let .chord(continuation) = elements[1],
              case let .chord(tail) = elements[3]
        else {
            Issue.record("the first half note should have been trimmed into two pieces")
            return
        }
        #expect(head.duration == .quarter)
        #expect(continuation.duration == .eighth)
        // The trim's own two pieces are one note, so they stay tied to each other.
        #expect(head.notes[0].tieForward == 1)
        #expect(continuation.notes[0].tieBack == 1)
        // The tie that would cross into the copy is gone, even though the source note carried one.
        #expect(continuation.notes[0].tieForward == nil)
        #expect(elements[2] == Self.quarter(60))
        #expect(tail.notes[0].tieBack == nil)
    }

    @Test("a mid-bar clef inside the replaced span survives at its tick")
    func keepsNonTimedElements() throws {
        var score = Self.identifiedFixture()
        _ = try SetClef(
            before: VoiceElementID(staff: Self.flute, measureIndex: 0, voiceIndex: 0, elementIndex: 3),
            clef: .bass,
        ).apply(to: &score)
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(measure: 0, start: 960, elements: [Self.quarter(60), Self.quarter(62)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let elements = Self.voice(score, 0).elements
        #expect(elements.contains { if case .clef = $0 { true } else { false } })
        // The clef sits at tick 960, so it must lead the copied material rather than trail it.
        #expect({ if case .clef = elements[3] { true } else { false } }())
        #expect(elements[4] == Self.quarter(60))
    }

    @Test("a locationShift inside the replaced span refuses")
    func refusesLocationShift() throws {
        var score = EditingFixtures.parityFixture()
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        var voice = Self.voice(score, 0)
        voice.elements.insert(
            .locationShift(delta: Fraction(numerator: 1, denominator: 8)), at: 3, id: ids.next(),
        )
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0] = voice
            }
        }
        #expect(throws: SheetMusicError.self) {
            _ = try RangeCopyVoiceRebuild.command(
                for: Self.piece(measure: 0, start: 960, elements: [Self.quarter(60), Self.quarter(62)]),
                staff: Self.flute, voiceIndex: 0, in: score,
            )
        }
    }

    @Test("a destination tuplet the span only partly covers refuses")
    func refusesPartialTuplet() throws {
        var score = Self.identifiedFixture()
        _ = try CreateTuplet(
            at: VoiceElementID(staff: Self.flute, measureIndex: 0, voiceIndex: 0, elementIndex: 3),
            actualNotes: 3, normalNotes: 2,
        ).apply(to: &score)
        #expect(throws: SheetMusicError.self) {
            _ = try RangeCopyVoiceRebuild.command(
                for: Self.piece(measure: 0, start: 1200, elements: [Self.quarter(60)]),
                staff: Self.flute, voiceIndex: 0, in: score,
            )
        }
    }

    @Test("a destination tuplet the span fully covers is dropped")
    func dropsContainedTuplet() throws {
        var score = Self.identifiedFixture()
        _ = try CreateTuplet(
            at: VoiceElementID(staff: Self.flute, measureIndex: 0, voiceIndex: 0, elementIndex: 3),
            actualNotes: 3, normalNotes: 2,
        ).apply(to: &score)
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(measure: 0, start: 960, elements: [Self.quarter(60)]),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        #expect(Self.voice(score, 0).tupletSpans.isEmpty)
    }

    @Test("a carried tuplet reaches the score as a real tuplet")
    func writesTuplet() throws {
        var score = Self.identifiedFixture()
        let third = VoiceElement.chord(Chord(
            duration: .fraction(Fraction(numerator: 160, denominator: 1920)),
            notes: [Note(pitch: 60, tpc: 14)],
        ))
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(
                measure: 0, start: 960, elements: [third, third, third],
                tuplets: [(range: 0 ... 2, normalNotes: 2, actualNotes: 3)],
            ),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let spans = Self.voice(score, 0).tupletSpans
        #expect(spans.count == 1)
        #expect(spans[0].actualNotes == 3)
        #expect(spans[0].endIndex - spans[0].startIndex == 2)
        #expect(spans[0].startIndex == 3)
    }

    @Test("a surviving destination tuplet and a carried one are emitted in span order")
    func ordersTupletSpans() throws {
        var score = Self.identifiedFixture()
        // A triplet on the quarter at tick 0 — entirely before the replaced span.
        _ = try CreateTuplet(
            at: VoiceElementID(staff: Self.flute, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
            actualNotes: 3, normalNotes: 2,
        ).apply(to: &score)
        let third = VoiceElement.chord(Chord(
            duration: .fraction(Fraction(numerator: 160, denominator: 1920)),
            notes: [Note(pitch: 60, tpc: 14)],
        ))
        let command = try RangeCopyVoiceRebuild.command(
            for: Self.piece(
                measure: 0, start: 960, elements: [third, third, third],
                tuplets: [(range: 0 ... 2, normalNotes: 2, actualNotes: 3)],
            ),
            staff: Self.flute, voiceIndex: 0, in: score,
        )
        _ = try command.apply(to: &score)
        let spans = Self.voice(score, 0).tupletSpans
        #expect(spans.count == 2)
        #expect(spans.map(\.startIndex) == spans.map(\.startIndex).sorted())
        #expect(spans[0].startIndex == 1)
        #expect(spans[1].startIndex == 5)
    }
}
