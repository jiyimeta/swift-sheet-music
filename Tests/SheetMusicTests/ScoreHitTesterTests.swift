#if os(macOS)
import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicUI
import Testing

@Suite("ScoreHitTester")
struct ScoreHitTesterTests {
    private func sample() -> Score {
        let chord = { (p: Int) -> VoiceElement in
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: p, tpc: 14)]))
        }
        let measure = Measure(voices: [
            Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                chord(60), .rest(Rest(duration: .quarter)),
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

    @Test("Tap on a notehead returns the matching ScoreItemID")
    func hitsNotehead() throws {
        guard #available(macOS 15.0, *) else { return }
        let score = sample()
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 600)
        let tester = ScoreHitTester(document: doc)

        let system = try #require(doc.systems.first)
        var target: (x: CGFloat, y: CGFloat, id: NoteID)?
        for measure in system.measures {
            for el in measure.elements {
                guard case .chord(let notes, _, _, _, _, _, _, _) = el,
                      let n = notes.first
                else { continue }
                let ax = system.origin.x + measure.origin.x + n.origin.x
                let ay = system.origin.y + measure.origin.y + n.origin.y
                target = (ax, ay, n.noteID)
                break
            }
            if target != nil { break }
        }
        let hit = try #require(target)
        let id = tester.itemID(at: CGPoint(x: hit.x, y: hit.y))
        #expect(id == .note(hit.id))
    }

    @Test("Tap on a rest returns its RestID")
    func hitsRest() throws {
        guard #available(macOS 15.0, *) else { return }
        let score = sample()
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 600)
        let tester = ScoreHitTester(document: doc)

        let system = try #require(doc.systems.first)
        var target: (x: CGFloat, y: CGFloat, id: RestID)?
        for measure in system.measures {
            for el in measure.elements {
                guard case let .rest(_, origin, _, rid, _) = el
                else { continue }
                let ax = system.origin.x + measure.origin.x + origin.x
                let ay = system.origin.y + measure.origin.y + origin.y
                target = (ax, ay, rid)
                break
            }
            if target != nil { break }
        }
        let hit = try #require(target)
        let id = tester.itemID(at: CGPoint(x: hit.x, y: hit.y))
        #expect(id == .rest(hit.id))
    }

    @Test("Tap on empty space returns nil")
    func missesEmptySpace() {
        guard #available(macOS 15.0, *) else { return }
        let score = sample()
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 600)
        let tester = ScoreHitTester(document: doc)
        // Far above the system — definitely no notes or rests.
        let id = tester.itemID(at: CGPoint(x: 0, y: -500))
        #expect(id == nil)
    }
}
#endif
