@testable import SheetMusicCore
import Testing

@Suite("RangeCopyPlacement")
struct RangeCopyPlacementTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func stream(
        _ elements: [(Int, VoiceElement)],
        tuplets: [(startTick: Int, endTick: Int, normalNotes: Int, actualNotes: Int)] = [],
    ) -> RangeCopySource.Stream {
        RangeCopySource.Stream(
            staff: flute, voiceIndex: 0,
            elements: elements.map { pair in
                // Every chord fixture below carries a plain duration, so its length is its own tick count. A
                // non-timed element has no length at all, which is how `RangeCopySource` stamps one.
                guard case let .chord(chord) = pair.1 else {
                    return (absoluteTick: pair.0, lengthTicks: 0, element: pair.1)
                }
                return (absoluteTick: pair.0, lengthTicks: chord.duration.ticks(division: 480), element: pair.1)
            },
            tuplets: tuplets,
            spanners: [],
        )
    }

    private static func quarter(_ pitch: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private static func context() -> RangeCopyGeometry {
        RangeCopyGeometry(staff: flute, in: EditingFixtures.parityFixture())
    }

    @Test("a stream that fits in one bar becomes one piece")
    func oneBar() throws {
        let geometry = Self.context()
        let pieces = try #require(RangeCopyPlacement.pieces(
            of: Self.stream([(0, Self.quarter(60)), (480, Self.quarter(62))]),
            at: 960, sourceStartTick: 0, geometry: geometry, division: 480,
        ))
        #expect(pieces.count == 1)
        #expect(pieces[0].measureIndex == 0)
        #expect(pieces[0].startTickInMeasure == 960)
        #expect(pieces[0].elements == [Self.quarter(60), Self.quarter(62)])
    }

    @Test("a stream crossing a barline splits into two pieces")
    func crossesBarline() throws {
        let geometry = Self.context()
        let pieces = try #require(RangeCopyPlacement.pieces(
            of: Self.stream([(0, Self.quarter(60)), (480, Self.quarter(62))]),
            at: 1440, sourceStartTick: 0, geometry: geometry, division: 480,
        ))
        #expect(pieces.count == 2)
        #expect(pieces[0].measureIndex == 0)
        #expect(pieces[0].startTickInMeasure == 1440)
        #expect(pieces[0].elements == [Self.quarter(60)])
        #expect(pieces[1].measureIndex == 1)
        #expect(pieces[1].startTickInMeasure == 0)
        #expect(pieces[1].elements == [Self.quarter(62)])
    }

    @Test("a chord straddling a barline becomes a tied chain on both sides")
    func tiedAcrossBarline() throws {
        let geometry = Self.context()
        let half = VoiceElement.chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)]))
        let pieces = try #require(RangeCopyPlacement.pieces(
            of: Self.stream([(0, half)]), at: 1440, sourceStartTick: 0, geometry: geometry, division: 480,
        ))
        #expect(pieces.count == 2)
        guard case let .chord(first) = pieces[0].elements[0], case let .chord(second) = pieces[1].elements[0]
        else { Issue.record("expected chords"); return }
        #expect(first.duration.ticks(division: 480) == 480)
        #expect(second.duration.ticks(division: 480) == 480)
        #expect(first.notes[0].tieForward == 1)
        #expect(second.notes[0].tieBack == 1)
    }

    @Test("a tuplet that lands inside one piece is carried as an index range")
    func tupletCarried() throws {
        let geometry = Self.context()
        let third = VoiceElement.chord(Chord(
            duration: .fraction(Fraction(numerator: 160, denominator: 1920)),
            notes: [Note(pitch: 60, tpc: 14)],
        ))
        let pieces = try #require(RangeCopyPlacement.pieces(
            of: Self.stream(
                [(0, third), (160, third), (320, third)],
                tuplets: [(startTick: 0, endTick: 480, normalNotes: 2, actualNotes: 3)],
            ),
            at: 960, sourceStartTick: 0, geometry: geometry, division: 480,
        ))
        #expect(pieces.count == 1)
        #expect(pieces[0].tuplets.count == 1)
        #expect(pieces[0].tuplets[0].range == 0 ... 2)
        #expect(pieces[0].tuplets[0].actualNotes == 3)
    }

    @Test("an element that fits is copied verbatim, dots and all")
    func doesNotDecomposeWhatFits() throws {
        let geometry = Self.context()
        let dotted = VoiceElement.chord(Chord(
            duration: .fraction(Fraction(numerator: 3, denominator: 8)),
            notes: [Note(pitch: 60, tpc: 14)],
        ))
        let pieces = try #require(RangeCopyPlacement.pieces(
            of: Self.stream([(0, dotted)]), at: 0, sourceStartTick: 0, geometry: geometry, division: 480,
        ))
        #expect(pieces.count == 1)
        #expect(pieces[0].elements == [dotted])
    }

    @Test("placement measures from the range start, so a voice's leading gap survives")
    func keepsLeadingGap() throws {
        let geometry = Self.context()
        // The range starts at tick 0 but this voice's first selected note is on beat 2.
        let pieces = try #require(RangeCopyPlacement.pieces(
            of: Self.stream([(480, Self.quarter(60))]), at: 1920, sourceStartTick: 0, geometry: geometry,
            division: 480,
        ))
        #expect(pieces.count == 1)
        #expect(pieces[0].measureIndex == 1)
        #expect(pieces[0].startTickInMeasure == 480)
    }

    @Test("a zero-length element lands at its offset and does not move the cursor")
    func placesNonTimedElements() throws {
        let geometry = Self.context()
        let clef = VoiceElement.clef(Clef(concertClefType: "F"))
        let pieces = try #require(RangeCopyPlacement.pieces(
            of: Self.stream([(0, Self.quarter(60)), (480, clef), (480, Self.quarter(62))]),
            at: 960, sourceStartTick: 0, geometry: geometry, division: 480,
        ))
        #expect(pieces.count == 1)
        #expect(pieces[0].startTickInMeasure == 960)
        // The clef sits between the two quarters rather than after them: it consumed none of the bar's budget,
        // so the second quarter still starts one beat after the first.
        #expect(pieces[0].elements == [Self.quarter(60), clef, Self.quarter(62)])
    }

    @Test("a zero-length element landing on a destination barline opens the next piece")
    func nonTimedElementOpensThePieceItLandsIn() throws {
        let geometry = Self.context()
        let clef = VoiceElement.clef(Clef(concertClefType: "F"))
        let pieces = try #require(RangeCopyPlacement.pieces(
            of: Self.stream([(0, Self.quarter(60)), (480, clef), (480, Self.quarter(62))]),
            at: 1440, sourceStartTick: 0, geometry: geometry, division: 480,
        ))
        #expect(pieces.count == 2)
        #expect(pieces[0].elements == [Self.quarter(60)])
        #expect(pieces[1].measureIndex == 1)
        #expect(pieces[1].startTickInMeasure == 0)
        #expect(pieces[1].elements == [clef, Self.quarter(62)])
    }

    @Test("a destination past the last bar has no placement")
    func pastTheEnd() {
        let geometry = Self.context()
        #expect(RangeCopyPlacement.pieces(
            of: Self.stream([(0, Self.quarter(60))]),
            at: 7680, sourceStartTick: 0, geometry: geometry, division: 480,
        ) == nil)
    }
}
