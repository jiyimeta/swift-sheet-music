import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicPages
import Testing

/// `ScorePageOptions.drawsInvisibleElements`: a print of a score shown with invisible elements keeps their room and
/// draws nothing in it — `ScoreCanvasDrawing.drawSystem(drawsInvisibleElements:)` for the portable pages. The two
/// fixtures are `PDFExporterSheetsTests`' — one element parked in the measure's container, one invisible note inside a
/// visible chord — so both of the encoder's paths are covered.
@Suite("ScorePages invisible elements")
struct ScorePagesInvisibleTests {
    private static let gray: UInt32 = 0xFF80_8080

    private static func provider() throws -> any FontMetricsProvider {
        let table = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicPagesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Web/sheet-music-web/assets/sheet-music.smft")
        return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: table)))
    }

    /// One treble bar holding `chord`.
    private static func score(_ chord: Chord, system: IdentifiedArray<SystemMeasure> = []) -> Score {
        let voice = Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord),
        ])
        return Score(
            division: 480,
            parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"), staves: [Staff(measures: [Measure(voices: [voice])])],
            )],
            systemMeasures: system,
        )
    }

    /// One bar under a hidden tempo marking, which the layout parks in the measure's `invisibleElements`.
    private static let hiddenTempo = score(
        Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]),
        system: [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2, visible: false))),
        ])],
    )

    /// A quarter chord of a visible B4 and an invisible G4, which stays in the chord flagged `isInvisible`.
    private static var hiddenNoteInChord: Score {
        var hidden = Note(pitch: 67, tpc: 15)
        hidden.visible = false
        return score(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 71, tpc: 19), hidden])))
    }

    private static func pages(_ score: Score, draws: Bool) throws -> ScorePages {
        try FontMetrics.$scopedProvider.withValue(provider()) {
            ScorePages.compute(
                score: score, pageWidthMM: 210, pageHeightMM: 297,
                options: ScorePageOptions(
                    mode: .page, showsInvisibleElements: true, drawsInvisibleElements: draws,
                    pageMarginsMM: .uniform(12.7),
                ),
            )
        }
    }

    private static func commands(_ pages: ScorePages) -> [DrawCommand] {
        pages.pages.flatMap(\.commands)
    }

    private static func glyphs(_ commands: [DrawCommand]) -> Int {
        commands.count { command in
            if case .glyph = command { return true }
            return false
        }
    }

    @Test(arguments: ["hidden tempo", "hidden note in a chord"])
    func `the layout keeps the room, and only the gray goes`(fixture: String) throws {
        let score = fixture == "hidden tempo" ? Self.hiddenTempo : Self.hiddenNoteInChord
        let shown = try Self.pages(score, draws: true)
        let printed = try Self.pages(score, draws: false)
        let shownCommands = Self.commands(shown)
        let printedCommands = Self.commands(printed)

        #expect(shownCommands.contains(.setColor(argb: Self.gray)), "control: the fixture draws something gray")
        #expect(!printedCommands.contains(.setColor(argb: Self.gray)))
        #expect(printed.document == shown.document, "the layout is the same — the room stays")
        #expect(printed.pageCount == shown.pageCount)
        #expect(printedCommands.count < shownCommands.count)
        if fixture == "hidden note in a chord" {
            #expect(Self.glyphs(printedCommands) == Self.glyphs(shownCommands) - 1, "only the hidden notehead goes")
        }
    }

    @Test func `drawing invisible elements is the default`() throws {
        let defaultOptions = ScorePageOptions(mode: .page, showsInvisibleElements: true)

        #expect(defaultOptions.drawsInvisibleElements)
        #expect(try Self.commands(Self.pages(Self.hiddenTempo, draws: true)).contains(.setColor(argb: Self.gray)))
    }
}
