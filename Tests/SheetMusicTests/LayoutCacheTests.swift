#if os(macOS)
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutCache")
struct LayoutCacheTests {
    /// Builds a tiny multi-measure score for cache exercises.
    private static func sampleScore() -> Score {
        let note = Note(pitch: 60, tpc: 14)
        let m1 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [note]))
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .half, notes: [note])),
            .chord(Chord(duration: .half, notes: [note])),
        ])])
        let m3 = Measure(voices: [Voice(elements: [
            .rest(Rest(duration: .whole))
        ])])
        return Score(
            division: 480,
            staves: [StaffContent(id: 1, measures: [m1, m2, m3])])
    }

    @Test("Cold cache produces same document as cache-less layout")
    func coldCacheEquivalence() {
        guard #available(macOS 15.0, *) else { return }
        let score = Self.sampleScore()
        let baseline = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800)
        let cache = LayoutCache()
        let cached = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 800, cache: cache)
        #expect(cached.systems == baseline.systems)
        #expect(cached.size == baseline.size)
    }
}
#endif
