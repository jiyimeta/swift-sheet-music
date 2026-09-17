import SheetMusicCore
import SheetMusicMSCX
import Testing

/// The two symbols a host needs to wire ⌘C and ⌘V, exercised the way a host reaches them.
///
/// `import SheetMusicCore` here is deliberately NOT `@testable`: every other test in this feature reaches
/// `RangeCopyPayload.score(for:in:)` through the internal name, so the public pair — the only surface a host
/// actually links against — had no coverage at all, and a change to either one's contract could not fail a test.
@Suite("Score clipboard seam")
struct ScoreClipboardSeamTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ staff: StaffAddress, _ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    // MARK: - clipboardDocument(for:)

    @Test("clipboardDocument hands back a document that encodes, parses, and pastes")
    func buildsAPayloadAHostCanUse() throws {
        // The whole host recipe in one test: build the document, encode it with `MSCXEncoder` (this package
        // cannot — `SheetMusicMSCX` depends on `SheetMusicCore`), and hand the bytes back through
        // `PasteRange`'s payload parameter with `MSCXParser.parse` as the reader.
        var score = EditingFixtures.parityFixture()
        let document = try #require(score.clipboardDocument(
            for: VoiceElementRange(start: Self.slot(Self.flute, 0, 1), end: Self.slot(Self.flute, 0, 4)),
        ))
        let text = try #require(String(data: MSCXEncoder.encode(document), encoding: .utf8))
        _ = try PasteRange(at: Self.slot(Self.flute, 1, 0), payload: text, readPayload: MSCXParser.parse)
            .apply(to: &score)
        #expect(try #require(score[Self.flute]).measures[1].voices[0].elements == [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .rest(duration: .quarter), .rest(duration: .quarter),
        ])
    }

    @Test("a note copied from the score's first bar pastes without the clef that bar opens with")
    func pastesWithoutTheOpeningClef() throws {
        let flute = Staff(defaultClefType: "G", measures: [
            Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .keySignature(KeySignature(concertKey: 0)),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
                .rest(duration: .half),
            ])]),
            Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
        ])
        var score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [flute]),
        ])
        let document = try #require(score.clipboardDocument(
            for: VoiceElementRange(start: Self.slot(Self.flute, 0, 3), end: Self.slot(Self.flute, 0, 3)),
        ))
        let text = try #require(String(data: MSCXEncoder.encode(document), encoding: .utf8))
        _ = try PasteRange(at: Self.slot(Self.flute, 1, 0), payload: text, readPayload: MSCXParser.parse)
            .apply(to: &score)
        let landed = try #require(score[Self.flute]).measures[1].voices[0].elements
        #expect(!landed.values.contains { if case .clef = $0 { true } else { false } })
        #expect(landed.values.first == .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])))
    }

    @Test("clipboardDocument refuses a range that cuts a tuplet, with nothing for a host to put on the board")
    func refusesAPartialTuplet() {
        let source = RangeCopyPayloadTests.tripletFixture()
        // Starts on the triplet's second member. `nil` here is a refusal, not an empty answer — see the symbol's
        // own doc comment — and a host must leave the pasteboard alone rather than write an empty payload.
        #expect(source.clipboardDocument(
            for: VoiceElementRange(start: Self.slot(Self.flute, 0, 2), end: Self.slot(Self.flute, 0, 6)),
        ) == nil)
    }

    @Test("clipboardDocument answers nil for a range that resolves to nothing")
    func refusesAnUnresolvableRange() {
        let source = EditingFixtures.parityFixture()
        #expect(source.clipboardDocument(
            for: VoiceElementRange(start: Self.slot(Self.flute, 0, 1), end: Self.slot(Self.flute, 9, 0)),
        ) == nil)
    }

    // MARK: - chronologicalBounds(of:)

    @Test("chronologicalBounds orders a range's bounds by onset, not by staff address")
    func ordersBoundsByOnset() throws {
        // The fact a host needs to place the ⌘V caret. The later-sounding bound is on the EARLIER staff here, so
        // anything reading the addresses would answer backwards.
        let score = EditingFixtures.parityFixture()
        let later = Self.slot(Self.cello, 1, 0)
        let earlier = Self.slot(Self.flute, 0, 1)
        let bounds = try #require(score.chronologicalBounds(of: VoiceElementRange(start: later, end: earlier)))
        #expect(bounds.earlier == earlier)
        #expect(bounds.later == later)
        // And it answers the same pair whichever way round the range was given.
        let reversed = try #require(score.chronologicalBounds(of: VoiceElementRange(start: earlier, end: later)))
        #expect(reversed.earlier == earlier)
        #expect(reversed.later == later)
    }

    @Test("chronologicalBounds answers nil when a bound does not resolve")
    func refusesAnUnresolvableBound() {
        let score = EditingFixtures.parityFixture()
        #expect(score.chronologicalBounds(of: VoiceElementRange(
            start: Self.slot(Self.flute, 0, 1), end: Self.slot(Self.flute, 9, 0),
        )) == nil)
    }
}
