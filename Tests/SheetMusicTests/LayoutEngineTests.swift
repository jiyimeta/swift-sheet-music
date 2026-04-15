#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import Testing

@Suite("LayoutEngine")
struct LayoutEngineTests {

    @Test("Empty score produces zero systems")
    func emptyScore() {
        guard #available(macOS 15.0, *) else { return }
        let score = Score(division: 480)
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(),
            availableWidth: 800)
        #expect(doc.systems.isEmpty)
    }

    @Test("Single measure with a whole note produces one system")
    func oneWholeNote() {
        guard #available(macOS 15.0, *) else { return }
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let measure = Measure(
            voices: [Voice(elements: [.chord(chord)])])
        let staff = StaffContent(id: 1, measures: [measure])
        let score = Score(division: 480, staves: [staff])
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800)
        #expect(doc.systems.count == 1)
        #expect(doc.systems[0].measures.count == 1)
        let chordCount = doc.systems[0].measures[0].elements.filter {
            if case .chord = $0 { true } else { false }
        }.count
        #expect(chordCount == 1)
    }

    @Test("Many measures at narrow width wrap to multiple systems")
    func manyMeasuresWrap() {
        guard #available(macOS 15.0, *) else { return }
        let note = Note(pitch: 60, tpc: 14)
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [note])),
            .chord(Chord(duration: .whole, notes: [note])),
            .chord(Chord(duration: .whole, notes: [note])),
        ])])
        let staff = StaffContent(
            id: 1, measures: [m, m, m, m, m, m, m, m])
        let score = Score(division: 480, staves: [staff])
        let doc = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 120)
        #expect(doc.systems.count >= 2)
    }

    @Test("Piano (2 staves) stacks staff origins vertically")
    func pianoTwoStaves() {
        guard #available(macOS 15.0, *) else { return }
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let m = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff1 = StaffContent(id: 1, measures: [m])
        let staff2 = StaffContent(id: 2, measures: [m])
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "piano", longName: "Piano", shortName: "Pno.")
        )
        let score = Score(
            division: 480,
            parts: [part],
            staves: [staff1, staff2]
        )
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800)
        #expect(doc.systems.count == 1)
        #expect(doc.systems[0].staffOrigins.count == 2)
        #expect(doc.systems[0].staffOrigins[0].y
                < doc.systems[0].staffOrigins[1].y)
    }

    @Test("Part labels: long name on first system, short name after")
    func partLabelsFirstVsLater() throws {
        guard #available(macOS 15.0, *) else { return }
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let m = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = StaffContent(
            id: 1, measures: [m, m, m, m, m, m, m, m])
        let part = Part(
            id: "P1",
            trackName: "Violin",
            instrument: Instrument(
                id: "violin", longName: "Violin", shortName: "Vln.")
        )
        let score = Score(
            division: 480,
            parts: [part],
            staves: [staff]
        )
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 180)
        try #require(doc.systems.count >= 2)
        #expect(doc.systems[0].partLabels.first?.text == "Violin")
        #expect(doc.systems[1].partLabels.first?.text == "Vln.")
    }
}
#endif
