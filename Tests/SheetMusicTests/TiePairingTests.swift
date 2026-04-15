#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import Testing

@Suite("Tie pairing")
struct TiePairingTests {

    @Test("Two quarter notes tied with number 1 produce one TiePair")
    func twoQuartersTied() {
        guard #available(macOS 15.0, *) else { return }
        let a = Note(pitch: 60, tpc: 14, tieForward: 1)
        let b = Note(pitch: 60, tpc: 14, tieBack: 1)
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [a])),
            .chord(Chord(duration: .quarter, notes: [b])),
        ])])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(division: 480, staves: [staff])
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800)
        let ties = LayoutEngine.resolveTies(for: doc, score: score)
        #expect(ties.count == 1)
    }

    @Test("Unmatched tieForward with no tieBack produces no pair")
    func unmatchedTie() {
        guard #available(macOS 15.0, *) else { return }
        let a = Note(pitch: 60, tpc: 14, tieForward: 1)
        let b = Note(pitch: 60, tpc: 14)  // no tieBack
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [a])),
            .chord(Chord(duration: .quarter, notes: [b])),
        ])])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(division: 480, staves: [staff])
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800)
        let ties = LayoutEngine.resolveTies(for: doc, score: score)
        #expect(ties.isEmpty)
    }
}
#endif
