#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF
    import Testing

    /// A measure that changes clef, key or time gets those elements prepended to its first voice. Rebuilding the voice
    /// used to drop its tuplets, so every triplet in such a measure lost its span, its members were written as
    /// `<durationType>measure</durationType>`, and the converted `.mscx` could not be read back.
    struct PDFImporterScoreStatePrefixTests {
        private static let triplet = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))

        private static func note(_ pitch: Int, _ duration: NoteDuration) -> VoiceElement {
            .chord(Chord(duration: duration, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
        }

        private static let voice = Voice(
            elements: [
                note(60, .quarter), note(62, triplet), note(64, triplet), note(65, triplet),
                note(67, .quarter), note(69, triplet), note(71, triplet), note(72, triplet),
            ],
            tuplets: [
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3),
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 5, endIndex: 7),
            ],
        )

        @Test func `prepending a key change keeps the tuplets on the same members`() {
            let (voices, leading) = PDFImporter.prependingScoreState(
                [Self.voice], clef: nil, key: KeySignature(concertKey: 2), time: nil,
            )
            #expect(leading == 1)
            #expect(voices[0].tupletSpans.map { [$0.startIndex, $0.endIndex] } == [[2, 4], [6, 8]])
        }

        @Test func `a measure that changes clef, key and time still writes an mscx that reads back`() throws {
            let (voices, _) = PDFImporter.prependingScoreState(
                [Self.voice], clef: Clef(concertClefType: "G"), key: KeySignature(concertKey: 2),
                time: TimeSignature(numerator: 4, denominator: 4),
            )
            #expect(voices[0].tupletSpans.map { [$0.startIndex, $0.endIndex] } == [[4, 6], [8, 10]])
            let part = Part(
                id: "P0",
                instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                staves: [Staff(measures: [Measure(voices: voices)])],
            )
            _ = try MSCXParser.parse(MSCXEncoder.encode(Score(division: 480, parts: [part])))
        }
    }
#endif
