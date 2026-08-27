#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("KeySignatureSteps")
struct KeySignatureStepsTests {
    @Test(arguments: NotatedClef.allCases)
    func sharpsAndFlatsCoverSevenAccidentals(clef: NotatedClef) {
        #expect(KeySignatureSteps.sharps(for: clef).count == 7)
        #expect(KeySignatureSteps.flats(for: clef).count == 7)
    }

    @Test func sharpOrderStartsAtFSharpEndsAtBSharp() {
        // F♯ sits on the top line (step 4); B♯ ends on the middle line
        // (step 0).
        #expect(KeySignatureSteps.sharps(for: .treble).first == 4)
        #expect(KeySignatureSteps.sharps(for: .treble).last == 0)
    }

    @Test func flatOrderStartsAtBFlatEndsAtFFlat() {
        // B♭ sits on the middle line (step 0); F♭ ends 1.5 spaces below
        // (step -3).
        #expect(KeySignatureSteps.flats(for: .treble).first == 0)
        #expect(KeySignatureSteps.flats(for: .treble).last == -3)
    }

    /// Every table is MuseScore's `ClefInfo::lines` row for that clef
    /// (`engraving/dom/clef.cpp:50-83`) read as `step = 4 - line`.
    /// Getting these wrong puts a bass staff's accidentals on the
    /// treble positions — a whole third off, which is what a user
    /// reported seeing on an F-clef staff.
    @Test func bassClefLowersTheTrebleClusterByOneLine() {
        #expect(
            KeySignatureSteps.sharps(for: .bass)
                == [2, -1, 3, 0, -3, 1, -2],
        )
        #expect(
            KeySignatureSteps.flats(for: .bass)
                == [-2, 1, -3, 0, -4, -1, -5],
        )
        // F♯ on the 4th line (F3), B♭ on the 2nd line (B2).
        #expect(KeySignatureSteps.sharps(for: .bass).first == 2)
        #expect(KeySignatureSteps.flats(for: .bass).first == -2)
    }

    @Test func octaveVariantsShareTheirBaseClefTable() {
        for clef: NotatedClef in [.treble8va, .treble8vb, .treble15ma, .treble15mb] {
            #expect(
                KeySignatureSteps.sharps(for: clef)
                    == KeySignatureSteps.sharps(for: .treble),
            )
        }
        for clef: NotatedClef in [.bass8va, .bass8vb] {
            #expect(
                KeySignatureSteps.sharps(for: clef)
                    == KeySignatureSteps.sharps(for: .bass),
            )
        }
    }

    @Test func cClefTablesMatchMuseScore() {
        #expect(
            KeySignatureSteps.sharps(for: .alto) == [3, 0, 4, 1, -2, 2, -1],
        )
        #expect(
            KeySignatureSteps.flats(for: .alto) == [-1, 2, -2, 1, -3, 0, -4],
        )
        // Tenor is NOT a uniform shift of the treble table: F♯ drops an
        // octave to stay off ledger lines, so it sits BELOW C♯.
        #expect(
            KeySignatureSteps.sharps(for: .tenor) == [-2, 2, -1, 3, 0, 4, 1],
        )
        #expect(
            KeySignatureSteps.flats(for: .tenor) == [1, 4, 0, 3, -1, 2, -2],
        )
        #expect(
            KeySignatureSteps.sharps(for: .soprano) == [-1, 3, 0, 4, 1, 5, 2],
        )
        #expect(
            KeySignatureSteps.flats(for: .soprano) == [2, -2, 1, -3, 0, -4, -1],
        )
        #expect(
            KeySignatureSteps.sharps(for: .baritone) == [0, 4, 1, 5, 2, -1, 3],
        )
        #expect(
            KeySignatureSteps.flats(for: .baritone) == [3, -1, 2, -2, 1, -3, 0],
        )
    }

    @Test func stepsTakesOnlyTheAccidentalsInTheKey() {
        #expect(
            KeySignatureSteps.steps(sharps: 2, flats: 0, clef: .bass)
                == [2, -1],
        )
        #expect(
            KeySignatureSteps.steps(sharps: 0, flats: 3, clef: .bass)
                == [-2, 1, -3],
        )
        #expect(
            KeySignatureSteps.steps(sharps: 0, flats: 0, clef: .bass)
                .isEmpty,
        )
    }

    @Test func advanceIs1Point4Sp() {
        let sp: CGFloat = 5
        #expect(KeySignatureSteps.advance(sp: sp) == 7)
    }

    @Test func stepDyFlipsSignForYDown() {
        let sp: CGFloat = 4
        // Positive step = up = negative dy.
        #expect(KeySignatureSteps.stepDy(step: 2, sp: sp) == -4)
        #expect(KeySignatureSteps.stepDy(step: 0, sp: sp) == 0)
        #expect(KeySignatureSteps.stepDy(step: -1, sp: sp) == 2)
    }
}

/// End-to-end: the layout engine must hand the renderers the clef
/// that is in force, so an F-clef staff's flats are drawn a line
/// lower than a G-clef staff's.
@Suite("Key signature clef placement")
struct KeySignatureClefPlacementTests {
    /// `LayoutEngine.layout` asserts a real FontMetrics provider.
    private let _installFontMetrics = TestSupport.installFontMetrics

    private func keySignatureElements(
        clefType: String,
    ) -> [LayoutElement] {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let voice = Voice(elements: [
            .clef(Clef(concertClefType: clefType)),
            .keySignature(KeySignature(concertKey: -2)),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )],
        )
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 800,
        )
        return doc.systems.flatMap(\.measures)
            .flatMap(\.elements)
            .filter { if case .keySignature = $0 { true } else { false } }
    }

    @Test func layoutTagsKeySignatureWithTheClefInForce() {
        guard case let .keySignature(_, _, bassClef, _) =
            keySignatureElements(clefType: "F").first
        else {
            Issue.record("no key signature laid out for the F clef staff")
            return
        }
        #expect(bassClef == .bass)
        guard case let .keySignature(_, _, trebleClef, _) =
            keySignatureElements(clefType: "G").first
        else {
            Issue.record("no key signature laid out for the G clef staff")
            return
        }
        #expect(trebleClef == .treble)
    }
}
