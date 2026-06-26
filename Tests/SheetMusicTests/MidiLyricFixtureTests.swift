import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// Real-fixture round-trip: `test_lyrics.mscz` (a project-authored,
/// MIT-licensed score under Resources/own/) carries two verses
/// (Japanese solfège + note names, UTF-8), hyphenated syllables, and a
/// melisma. Parsing it, rendering to SMF, and re-importing must
/// reconstruct the same lyric content.
struct MidiLyricFixtureTests {
    private struct Syllable: Equatable, CustomStringConvertible {
        var text: String
        var syllabic: Syllabic
        var verse: Int
        var description: String {
            "\(text)[\(syllabic) v\(verse)]"
        }
    }

    /// Non-empty lyric syllables across the score, in document order.
    private func syllables(in score: Score) -> [Syllable] {
        score.parts
            .flatMap(\.staves)
            .flatMap(\.measures)
            .flatMap(\.voices)
            .flatMap(\.elements)
            .compactMap { element -> [Lyric]? in
                if case let .chord(chord) = element, !chord.notes.isEmpty {
                    return chord.lyrics
                }
                return nil
            }
            .flatMap(\.self)
            .filter { !$0.text.isEmpty }
            .map { Syllable(text: $0.text, syllabic: $0.syllabic, verse: $0.verse) }
    }

    private func loadFixture() throws -> Score {
        let url = try #require(
            Bundle.module.url(forResource: "test_lyrics", withExtension: "mscz"),
        )
        return try MSCZReader.parse(Data(contentsOf: url))
    }

    @Test func fixtureLyricsSurviveMidiRoundTrip() throws {
        let source = try loadFixture()
        let bytes = try MidiWriter.write(MidiRenderer.render(score: source))
        let imported = try MidiImporter.parse(bytes)

        let sourceSyllables = syllables(in: source)
        let importedSyllables = syllables(in: imported)

        #expect(!sourceSyllables.isEmpty)
        #expect(importedSyllables == sourceSyllables)
    }

    @Test func fixtureHasMultipleVersesAndHyphenation() throws {
        // Guards that the fixture itself still exercises every dimension,
        // so the round-trip test above stays meaningful.
        let source = try loadFixture()
        let syllables = syllables(in: source)
        #expect(Set(syllables.map(\.verse)) == [0, 1])
        #expect(syllables.contains { $0.syllabic == .begin })
        #expect(syllables.contains { $0.syllabic == .middle })
        #expect(syllables.contains { $0.syllabic == .end })
    }

    @Test func fixtureMelismaSurvivesAsMelisma() throws {
        let source = try loadFixture()
        let bytes = try MidiWriter.write(MidiRenderer.render(score: source))
        let imported = try MidiImporter.parse(bytes)

        func melismaTexts(_ score: Score) -> Set<String> {
            Set(
                score.parts
                    .flatMap(\.staves).flatMap(\.measures)
                    .flatMap(\.voices).flatMap(\.elements)
                    .compactMap { element -> [Lyric]? in
                        if case let .chord(chord) = element { return chord.lyrics }
                        return nil
                    }
                    .flatMap(\.self)
                    .filter { $0.ticks > 0 }
                    .map(\.text),
            )
        }

        let sourceMelismas = melismaTexts(source)
        #expect(!sourceMelismas.isEmpty)
        // The same syllables remain melismas after the round trip.
        #expect(melismaTexts(imported) == sourceMelismas)
    }
}
