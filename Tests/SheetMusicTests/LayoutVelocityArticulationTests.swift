import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicUI
import Testing

@Suite("LayoutEngine velocity-shaping articulation emission")
struct LayoutVelocityArticulationTests {
    private static func score(
        articulations: [ChordArticulation]
    ) -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([note]),
            articulations: articulations
        )
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
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

    @available(macOS 15.0, iOS 16.0, *)
    private static func articulationKinds(
        in doc: LayoutDocument
    ) -> [LayoutElement.ArticulationKind] {
        guard let measure = doc.systems.first?.measures.first
        else { return [] }
        return measure.elements.compactMap { el in
            if case let .articulation(kind, _, _) = el { return kind }
            return nil
        }
    }

    @Test("Accent above emits one .articulation of kind .accent")
    func accentAbove() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .accent, anchor: .above)]
        ))
        #expect(Self.articulationKinds(in: doc) == [.accent])
    }

    @Test("Marcato below emits one .articulation of kind .marcato")
    func marcatoBelow() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .marcato, anchor: .below)]
        ))
        #expect(Self.articulationKinds(in: doc) == [.marcato])
    }

    @Test("Combined accent-staccato emits ONE .articulation, not two")
    func combinedSingleEntry() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .accentStaccato, anchor: .below)]
        ))
        #expect(Self.articulationKinds(in: doc) == [.accentStaccato])
    }

    @Test("Combined marcato-staccato also single entry")
    func combinedMarcatoSingleEntry() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .marcatoStaccato, anchor: .above)]
        ))
        #expect(Self.articulationKinds(in: doc) == [.marcatoStaccato])
    }

    @Test("Glyph mapping for the eight new (kind, isAbove) pairs")
    func glyphMapping() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let cases: [(LayoutElement.ArticulationKind, Bool, Character)] = [
            (.accent, true, "\u{E4A0}"),
            (.accent, false, "\u{E4A1}"),
            (.marcato, true, "\u{E4AC}"),
            (.marcato, false, "\u{E4AD}"),
            (.accentStaccato, true, "\u{E4B0}"),
            (.accentStaccato, false, "\u{E4B1}"),
            (.marcatoStaccato, true, "\u{E4AE}"),
            (.marcatoStaccato, false, "\u{E4AF}"),
        ]
        for (kind, isAbove, expected) in cases {
            #expect(
                ArticulationRenderer.glyph(kind: kind, isAbove: isAbove) == expected,
                "kind=\(kind) isAbove=\(isAbove)"
            )
        }
    }
}
