import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutEngine fermata anchor placement")
struct FermataLayoutTests {
    /// Build a one-measure score whose voice contains
    /// `[chord(C4), fermata, chord(D4)]` — the canonical MusicXML
    /// ordering where the fermata appears BEFORE its target chord.
    private static func fermataBeforeTargetScore() -> Score {
        let cChord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)])
        )
        let dChord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 62, tpc: 16)])
        )
        let fermata = Fermata(subtype: "fermataAbove")
        let voice = Voice(elements: [
            .chord(cChord),
            .fermata(fermata),
            .chord(dChord),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [staff]
            )]
        )
    }

    /// Build the inverse layout: `[chord(C4), chord(D4), fermata]` —
    /// the MSCX shape where Fermata is a sibling AFTER its target.
    /// The backward fallback should anchor the fermata to D4.
    private static func fermataAfterTargetScore() -> Score {
        let cChord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)])
        )
        let dChord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 62, tpc: 16)])
        )
        let fermata = Fermata(subtype: "fermataAbove")
        let voice = Voice(elements: [
            .chord(cChord),
            .chord(dChord),
            .fermata(fermata),
        ])
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [staff]
            )]
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func laidOut(_ s: Score) -> LayoutDocument {
        let opts = ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false
        )
        let natW = LayoutEngine.naturalContentWidth(score: s, options: opts)
        return LayoutEngine.layout(
            score: s, options: opts, availableWidth: natW
        )
    }

    /// Pull (fermataX, chordXs) from the first measure.
    @available(macOS 15.0, iOS 16.0, *)
    private static func fermataAndChordXs(
        _ doc: LayoutDocument
    ) -> (CGFloat, [CGFloat])? {
        guard let measure = doc.systems.first?.measures.first
        else { return nil }
        var fermataX: CGFloat?
        var chordXs: [CGFloat] = []
        for el in measure.elements {
            switch el {
            case let .fermata(_, origin):
                fermataX = origin.x
            case let .chord(_, _, _, stemOrigin, _, _, _, _):
                chordXs.append(stemOrigin.x)
            default:
                break
            }
        }
        guard let fx = fermataX else { return nil }
        return (fx, chordXs)
    }

    @Test("Fermata before chord anchors to the FOLLOWING chord (MusicXML order)")
    func anchorForward() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.fermataBeforeTargetScore())
        let (fermataX, chordXs) = try #require(
            Self.fermataAndChordXs(doc)
        )
        try #require(chordXs.count == 2)
        // Expectation: fermata anchors to D4 (second chord), NOT C4 (first).
        #expect(
            abs(fermataX - chordXs[1]) < 0.001,
            "fermata x \(fermataX) should match D4 x \(chordXs[1]); C4 x is \(chordXs[0])"
        )
        #expect(
            abs(fermataX - chordXs[0]) > 0.5,
            "fermata x \(fermataX) should NOT match C4 x \(chordXs[0])"
        )
    }

    @Test("Fermata after chord falls back to PRECEDING chord (MSCX order)")
    func anchorBackwardFallback() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.fermataAfterTargetScore())
        let (fermataX, chordXs) = try #require(
            Self.fermataAndChordXs(doc)
        )
        try #require(chordXs.count == 2)
        // No following chord exists, so the backward fallback must
        // anchor to the most recent chord (D4 — the second one).
        #expect(
            abs(fermataX - chordXs[1]) < 0.001,
            "fermata x \(fermataX) should match D4 x \(chordXs[1])"
        )
    }
}
