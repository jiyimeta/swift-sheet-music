import CoreGraphics
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutElement.graceChord")
struct GraceLayoutElementTests {
    @Test("Case stores hasSlash, mag, relativeX")
    func storesFields() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.graceChord(
            notes: [],
            duration: .eighth,
            stem: .up,
            stemOrigin: .zero,
            relativeX: -10,
            hasSlash: true,
            mag: 0.6,
            voiceIndex: 0,
        )
        guard case let .graceChord(_, _, _, _, relX, slash, mag, _) = element else {
            Issue.record("not graceChord"); return
        }
        #expect(relX == -10)
        #expect(slash == true)
        #expect(mag == 0.6)
    }
}

@Suite("Grace placement")
struct GracePlacementTests {
    /// Build a score with a single chord that carries graces and
    /// run it through the layout engine. Returns the placed
    /// elements of measure 0.
    @available(macOS 15.0, iOS 16.0, *)
    private func place(graces before: [GraceType]) -> [LayoutElement] {
        let mainNote = Note(pitch: 60, tpc: 14)
        let graceChords = before.map { gt in
            GraceChord(
                graceType: gt, duration: .eighth,
                notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
            )
        }
        let main = Chord(
            duration: .quarter, notes: ChordNotes([mainNote]),
            graceNotesBefore: graceChords,
        )
        let measure = Measure(voices: [Voice(elements: [.chord(main)])])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "p1",
            instrument: Instrument(id: "piano"),
            staves: [staff],
        )
        let score = Score(division: 480, parts: [part])
        let doc = LayoutEngine.layout(
            score: score, options: ScoreViewOptions(), availableWidth: 800,
        )
        return doc.systems.flatMap { sys in sys.measures.flatMap(\.elements) }
    }

    @Test("Two before-graces appear before main chord in element order")
    func twoBefore() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let elements = place(graces: [.acciaccatura, .grace16])
        let graceIndices = elements.indices.filter {
            if case .graceChord = elements[$0] { return true }; return false
        }
        guard let mainIndex = elements.firstIndex(where: {
            if case .chord = $0 { return true }; return false
        }) else { Issue.record("no main chord"); return }
        #expect(graceIndices.count == 2)
        for gi in graceIndices {
            #expect(gi < mainIndex)
        }
    }

    @Test("acciaccatura sets hasSlash = true")
    func acciaccaturaSlash() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let elements = place(graces: [.acciaccatura])
        guard let graceEl = elements.first(where: {
            if case .graceChord = $0 { return true }; return false
        }) else { Issue.record("no grace"); return }
        guard case let .graceChord(_, _, _, _, _, slash, _, _) = graceEl
        else { Issue.record("no grace"); return }
        #expect(slash == true)
    }

    @Test("Non-acciaccatura graces have hasSlash = false")
    func nonAcciaccaturaNoSlash() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let elements = place(graces: [.grace16])
        guard let graceEl = elements.first(where: {
            if case .graceChord = $0 { return true }; return false
        }) else { Issue.record("no grace"); return }
        guard case let .graceChord(_, _, _, _, _, slash, _, _) = graceEl
        else { Issue.record("no grace"); return }
        #expect(slash == false)
    }
}

@Suite("Grace spacing")
struct GraceSpacingTests {
    @Test("Three before-graces push the main chord X to the right vs. zero graces")
    func extraSpacing() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        func mainX(_ before: [GraceType]) -> CGFloat {
            let main = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                graceNotesBefore: before.map { gt in
                    GraceChord(
                        graceType: gt,
                        duration: .eighth,
                        notes: ChordNotes([Note(pitch: 62, tpc: 16)]),
                    )
                },
            )
            let measure = Measure(voices: [Voice(elements: [
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 55, tpc: 13)]),
                )),
                .chord(main),
            ])])
            let staff = Staff(measures: [measure])
            let part = Part(
                id: "p1",
                instrument: Instrument(id: "piano"),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])
            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 800,
            )
            let elements = doc.systems.flatMap { sys in sys.measures.flatMap(\.elements) }
            // Find the second chord — that's `main` (pitch 60, C4).
            // The first chord is pitch 55 (G3); `main` is the next chord.
            var chordCount = 0
            for el in elements {
                if case .chord = el {
                    chordCount += 1
                    if chordCount == 2 { return el.stemX }
                }
            }
            return 0
        }
        let withGraces = mainX([.grace16, .grace16, .grace16])
        let noGraces = mainX([])
        #expect(withGraces > noGraces)
    }
}

/// Local helper for the test above — mirrors `LayoutDocument`'s
/// internal way of grabbing a chord's stem X.
@available(macOS 15.0, iOS 16.0, *)
extension LayoutElement {
    var stemX: CGFloat {
        if case let .chord(_, _, _, so, _, _, _, _) = self { return so.x }
        return 0
    }
}
