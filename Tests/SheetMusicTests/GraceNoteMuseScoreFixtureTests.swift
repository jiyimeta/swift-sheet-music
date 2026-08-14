import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// Grace-note placement read out of files **MuseScore itself wrote**.
///
/// This project's own parse → encode → parse round trip is
/// mirror-symmetric and therefore blind to every question these tests
/// ask: which chord a grace belongs to, and in which order a run of
/// them sounds. Only a MuseScore-authored fixture can answer that, so
/// the two fixtures here are upstream engraving test resources copied
/// verbatim (GPL-3.0 — see `Tests/SheetMusicTests/Resources/LICENSE`),
/// with their expectations taken from the upstream tests that consume
/// them.
@Suite("Grace notes — MuseScore-authored fixtures")
struct GraceNoteMuseScoreFixtureTests {
    /// Every chord of the score, in document order.
    private func chords(of score: Score) -> [Chord] {
        score.parts
            .flatMap(\.staves)
            .flatMap(\.measures)
            .flatMap(\.voices)
            .flatMap(\.elements)
            .compactMap { element in
                guard case let .chord(chord) = element else { return nil }
                return chord
            }
    }

    /// `midirenderer_data/grace_after.mscx` writes its `<grace8after/>`
    /// (D4) **ahead of** the C4 quarter it decorates, which is the very
    /// first chord of the measure. There is no preceding chord it could
    /// belong to, so the file settles the placement question outright:
    /// an after-grace precedes its owner, and the pre-fix decoder — which
    /// walked backwards from the grace — dropped this one entirely.
    @Test("An after-grace written ahead of the measure's first chord attaches to it")
    func afterGraceAheadOfFirstChordAttaches() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("grace_after"))
        let voiced = chords(of: score).filter { !$0.notes.isEmpty }
        let main = try #require(voiced.first)

        #expect(main.notes.map(\.pitch) == [60])
        #expect(main.graceNotesBefore.isEmpty)
        #expect(main.graceNotesAfter.map(\.graceType) == [.grace8after])
        #expect(main.graceNotesAfter.map { $0.notes.first?.pitch } == [62])
    }

    /// `playbackeventsrenderer_data/single_note_multi_appoggiatura_post`
    /// writes `<grace32after/>` A4 then `<grace16after/>` G4 ahead of its
    /// F4 quarter. Upstream's own
    /// `Engraving_PlaybackEventsRendererTests.SingleNote_MultiAppoggiatura_Post`
    /// expects that to sound F4 → G4 → A4, so the file order is the
    /// reverse of the sounding order — which is exactly what
    /// `Chord::graceNotesAfter()`'s reverse iteration produces, and what
    /// `Chord.graceNotesAfter` must hold here.
    @Test("A multi-note after-grace run decodes into sounding order, not file order")
    func multiAfterGraceRunIsReversedIntoSoundingOrder() throws {
        let score = try MSCXParser.parse(
            MSCXFixtureLoader.mscxData("single_note_multi_appoggiatura_post"),
        )
        let voiced = chords(of: score).filter { !$0.notes.isEmpty }
        let main = try #require(voiced.first)

        #expect(main.notes.map(\.pitch) == [65])
        #expect(main.graceNotesAfter.map { $0.notes.first?.pitch } == [67, 69])
        #expect(
            main.graceNotesAfter.map(\.graceType)
                == [.grace16after, .grace32after],
        )
    }

    /// Re-encoding a MuseScore-authored fixture must reproduce the grace
    /// placement MuseScore wrote — same run, same order, still ahead of
    /// the parent. This is the property that makes a file this project
    /// writes readable by MuseScore Studio, and it is checked against
    /// upstream's own bytes rather than against our own encoder.
    @Test("Re-encoding preserves MuseScore's own grace ordering")
    func reEncodingPreservesMuseScoreGraceOrdering() throws {
        for name in ["grace_after", "single_note_multi_appoggiatura_post"] {
            let original = try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
            let reEncoded = try MSCZReader.parse(
                MSCZWriter.write(score: original, options: .init(targetVersion: .v4)),
            )
            let before = chords(of: original).filter { !$0.notes.isEmpty }
            let after = chords(of: reEncoded).filter { !$0.notes.isEmpty }
            #expect(before.count == after.count, "\(name)")
            for (lhs, rhs) in zip(before, after) {
                #expect(
                    lhs.graceNotesAfter.map { $0.notes.first?.pitch }
                        == rhs.graceNotesAfter.map { $0.notes.first?.pitch },
                    "\(name)",
                )
                #expect(
                    lhs.graceNotesBefore.map { $0.notes.first?.pitch }
                        == rhs.graceNotesBefore.map { $0.notes.first?.pitch },
                    "\(name)",
                )
            }
        }
    }
}
