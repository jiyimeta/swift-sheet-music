#if os(macOS)
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicUI
import Testing

@Suite("Spanner segmentation")
struct SpannerSegmentationTests {

    @Test("Slur spanning two measures produces one anchor")
    func slurAnchor() {
        guard #available(macOS 15.0, *) else { return }
        let note = Note(pitch: 60, tpc: 14)
        let slur = Spanner(
            kind: .slur, rawType: "Slur", nextMeasuresOffset: 1)
        let m1 = Measure(voices: [Voice(elements: [
            .spanner(slur),
            .chord(Chord(duration: .quarter, notes: [note])),
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [note])),
        ])])
        let staff = StaffContent(id: 1, measures: [m1, m2])
        let score = Score(division: 480, staves: [staff])
        let anchors = LayoutEngine.collectSpanners(score: score)
        #expect(anchors.count == 1)
        #expect(anchors.first?.endMeasure == 1)
    }

    @Test("Volta with endings is preserved in the anchor")
    func voltaEndings() {
        guard #available(macOS 15.0, *) else { return }
        let note = Note(pitch: 60, tpc: 14)
        let v1 = Spanner(
            kind: .volta, rawType: "Volta",
            nextMeasuresOffset: 0,
            voltaEndings: [1])
        let m = Measure(voices: [Voice(elements: [
            .spanner(v1),
            .chord(Chord(duration: .quarter, notes: [note])),
        ])])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(division: 480, staves: [staff])
        let anchors = LayoutEngine.collectSpanners(score: score)
        #expect(anchors.first?.voltaEndings == [1])
    }
}
#endif
