import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutSystem.eventColumns")
struct LayoutSystemEventColumnsTests {
    private func sample() -> Score {
        let chord = { (p: Int) -> VoiceElement in
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: p, tpc: 14)]))
        }
        let measure = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                chord(60), .rest(duration: .quarter),
                chord(64), chord(65)
            ])
        ])
        return Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "piano", longName: "Piano"),
                staffDeclarations: [StaffDeclaration(
                    staffType: "stdNormal",
                    group: "pitched",
                    defaultClefType: "G")])],
            staves: [StaffContent(id: 1, measures: [measure])])
    }

    @Test("Index has one entry per chord + rest, sorted by centerX")
    func indexShapeAndOrder() throws {
        guard #available(macOS 15.0, *) else { return }
        let doc = LayoutEngine.layout(
            score: sample(),
            options: ScoreViewOptions(),
            availableWidth: 600)
        let system = try #require(doc.systems.first)

        // 3 chords + 1 rest from `sample()`, no clef entry.
        #expect(system.eventColumns.count == 4)
        let xs = system.eventColumns.map(\.centerX)
        #expect(xs == xs.sorted())

        // Each entry's id matches a chord/rest in the underlying
        // measure layout.
        let kinds = Set(system.eventColumns.map { col -> String in
            switch col.id {
            case .note: return "note"
            case .rest: return "rest"
            case .tuplet: return "tuplet"
            }
        })
        #expect(kinds == ["note", "rest"])

        // The fixture is single-voice (voice 0); confirm the
        // column → element wiring carries the voiceIndex through.
        #expect(system.eventColumns.allSatisfy { $0.voiceIndex == 0 })
    }

    @Test("maxBBoxHalfWidth is the max of all column bboxes")
    func maxBBoxHalfWidthInvariant() throws {
        guard #available(macOS 15.0, *) else { return }
        let doc = LayoutEngine.layout(
            score: sample(),
            options: ScoreViewOptions(),
            availableWidth: 600)
        let system = try #require(doc.systems.first)

        let expected = system.eventColumns
            .map { $0.bbox.width / 2 }
            .max() ?? 0
        #expect(abs(system.maxBBoxHalfWidth - expected) < 0.001)
    }
}
