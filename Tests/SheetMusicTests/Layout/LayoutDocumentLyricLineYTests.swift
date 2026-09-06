#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// Redundant, and kept only so nobody re-adds it wondering why it is
    /// missing. `SheetMusicCore` and `SheetMusicLayout` both declare `CGFloat`,
    /// but both declare it as `typealias CGFloat = Double` — the same type, so
    /// the bare name resolves without complaint.
    ///
    /// **Do not copy this line into a file that also names `CGPoint`.** There
    /// the two modules declare separate `struct`s, so the bare name really is
    /// ambiguous off Apple and needs its own alias. Copying the `CGFloat` line
    /// alone looks like the convention has been followed while leaving the one
    /// that matters missing, which is how `LayoutDocumentTextEntryOriginTests`
    /// reached main failing to compile on the wasm SDK (fixed in 080e426d).
    /// Apple shows neither the omission nor this redundancy, because there
    /// CoreGraphics supplies both names.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

@Suite("LayoutDocument lyric line Y")
struct LayoutDocumentLyricLineYTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let staffAddress = StaffAddress(
        partIndex: 0, staffIndexInPart: 0,
    )

    private static func chord(
        pitch: Int = 72,
        lyrics: [Lyric] = [],
    ) -> VoiceElement {
        .chord(Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: pitch, tpc: 14)]),
            lyrics: lyrics,
        ))
    }

    private static func measure(
        pitch: Int = 72,
        lyrics: [Lyric] = [],
    ) -> Measure {
        Measure(voices: [Voice(elements: [chord(
            pitch: pitch, lyrics: lyrics,
        )])])
    }

    private static func score(_ measures: [Measure]) -> Score {
        Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: measures)],
            )],
        )
    }

    private static func layout(_ measures: [Measure]) -> LayoutDocument {
        LayoutEngine.layout(
            score: score(measures),
            options: ScoreViewOptions(staffSize: 28),
            availableWidth: 1200,
        )
    }

    private static func elementID(measureIndex: Int = 0) -> VoiceElementID {
        VoiceElementID(
            staff: staffAddress,
            measureIndex: measureIndex,
            voiceIndex: 0,
            elementIndex: 0,
        )
    }

    private static func lyricMarks(
        in document: LayoutDocument,
        measureIndex: Int,
    ) throws -> [(verse: Int, y: CGFloat)] {
        let system = try #require(document.systems.first {
            $0.measures.contains { $0.measureIndex == measureIndex }
        })
        let measure = try #require(system.measures.first {
            $0.measureIndex == measureIndex
        })
        return measure.elements.compactMap { element in
            guard case let .textMark(
                .lyrics(_, verse, _), _, origin,
            ) = element
            else { return nil }
            return (
                verse,
                system.origin.y + measure.origin.y + origin.y,
            )
        }
    }

    private static func staffTop(
        in document: LayoutDocument,
        measureIndex: Int,
    ) throws -> CGFloat {
        let system = try #require(document.systems.first {
            $0.measures.contains { $0.measureIndex == measureIndex }
        })
        let staffIndex = try #require(system.flatIndex(for: staffAddress))
        return system.origin.y + system.staffOrigins[staffIndex].y
    }

    @Test func verseOneOnlyStillRevealsVerseZeroRow() throws {
        let document = Self.layout([Self.measure(lyrics: [
            Lyric(text: "", verse: 0),
            Lyric(text: "alto", verse: 1),
        ])])
        let mark = try #require(Self.lyricMarks(
            in: document, measureIndex: 0,
        ).first)
        let verseZeroY = try #require(document.lyricLineY(
            at: Self.elementID(), verse: 0,
        ))
        let stride = document.metrics.sp * 1.7

        #expect(mark.verse == 1)
        #expect(abs((mark.y - verseZeroY) - stride) < 0.001)
        #expect(verseZeroY < mark.y)
    }

    @Test func explicitVerseZeroAnchorsEveryRequestedRow() throws {
        let document = Self.layout([Self.measure(lyrics: [
            Lyric(text: "one", verse: 0),
            Lyric(text: "two", verse: 1),
        ])])
        let marks = try Self.lyricMarks(in: document, measureIndex: 0)
        let verseZeroMark = try #require(marks.first { $0.verse == 0 })
        let verseZeroY = try #require(document.lyricLineY(
            at: Self.elementID(), verse: 0,
        ))
        let verseOneY = try #require(document.lyricLineY(
            at: Self.elementID(), verse: 1,
        ))

        #expect(abs(verseZeroY - verseZeroMark.y) < 0.001)
        #expect(abs((verseOneY - verseZeroY) - document.metrics.sp * 1.7) < 0.001)
    }

    @Test func measureWithoutLyricsUsesStridingFallback() throws {
        let document = Self.layout([Self.measure()])
        let staffTop = try Self.staffTop(in: document, measureIndex: 0)
        let verseZeroY = try #require(document.lyricLineY(
            at: Self.elementID(), verse: 0,
        ))
        let verseTwoY = try #require(document.lyricLineY(
            at: Self.elementID(), verse: 2,
        ))

        #expect(abs(verseZeroY - (staffTop + document.metrics.sp * 6)) < 0.001)
        #expect(abs((verseTwoY - verseZeroY) - document.metrics.sp * 3.4) < 0.001)
    }

    @Test func higherVerseOnlyMeasureIsNotShiftedByAnotherMeasuresVerseZero() throws {
        let higherVerse = Self.measure(lyrics: [
            Lyric(text: "", verse: 0),
            Lyric(text: "alto", verse: 1),
        ])
        let alone = Self.layout([higherVerse])
        let besideDeepVerseZero = Self.layout([
            higherVerse,
            Self.measure(
                pitch: 36,
                lyrics: [Lyric(text: "low", verse: 0)],
            ),
        ])
        let aloneMark = try #require(Self.lyricMarks(
            in: alone, measureIndex: 0,
        ).first)
        let pairedMark = try #require(Self.lyricMarks(
            in: besideDeepVerseZero, measureIndex: 0,
        ).first)
        let aloneStaffTop = try Self.staffTop(in: alone, measureIndex: 0)
        let pairedStaffTop = try Self.staffTop(
            in: besideDeepVerseZero, measureIndex: 0,
        )

        #expect(abs(
            (aloneMark.y - aloneStaffTop) - (pairedMark.y - pairedStaffTop),
        ) < 0.001)
    }
}
