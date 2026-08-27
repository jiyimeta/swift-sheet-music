@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// Asserts that PDF-style layout (showsInvisibleElements == false)
/// never routes hidden annotations into `invisibleElements` — they
/// are simply dropped, so a PDF always reflects print behavior.
struct PDFInvisibleTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// Minimal one-measure score whose single system measure carries
    /// a hidden `Tempo`. Mirrors `InvisibleLayoutTests.scoreWithHiddenTempo()`.
    private func scoreWithHiddenTempo() -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let voice = Voice(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord),
        ])
        let measure = Measure(voices: [voice])
        let systemMeasure = SystemMeasure(elements: [
            PositionedSystemElement(
                position: .start,
                element: .tempo(Tempo(beatsPerSecond: 2.0, visible: false)),
            ),
        ])
        return Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [measure])],
            )],
            systemMeasures: [systemMeasure],
        )
    }

    @Test func pdfStyleLayoutDropsHiddenAnnotations() {
        let doc = LayoutEngine.layout(
            score: scoreWithHiddenTempo(),
            options: ScoreViewOptions(showsInvisibleElements: false),
            availableWidth: 800,
        )
        let invisible = doc.systems.flatMap(\.measures)
            .flatMap(\.invisibleElements)
        // Print layout must never tag invisibles — they are dropped.
        #expect(invisible.isEmpty)
    }
}
