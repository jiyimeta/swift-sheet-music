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

    @Test("Cold call: every width and placement is a miss")
    func coldCallAllMisses() {
        guard #available(macOS 15.0, *) else { return }
        let score = Self.sampleScore()
        let cache = LayoutCache()
        _ = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 800, cache: cache)
        #expect(cache.entries.count == 3)
        #expect(cache.widthHits == 0)
        #expect(cache.widthMisses == 3)
        // Single-staff score → one placement per measure.
        #expect(cache.placementHits == 0)
        #expect(cache.placementMisses == 3)
    }

    @Test("Warm call on identical score: every lookup is a hit")
    func warmCallAllHits() {
        guard #available(macOS 15.0, *) else { return }
        let score = Self.sampleScore()
        let cache = LayoutCache()
        let first = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 800, cache: cache)
        let second = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 800, cache: cache)
        #expect(first.systems == second.systems)
        #expect(first.size == second.size)
        #expect(cache.widthHits == 3)
        #expect(cache.widthMisses == 0)
        #expect(cache.placementHits == 3)
        #expect(cache.placementMisses == 0)
    }

    @Test("Editing one measure: only that measure misses")
    func singleMeasureEditMisses() {
        guard #available(macOS 15.0, *) else { return }
        let scoreA = Self.sampleScore()
        let cache = LayoutCache()
        _ = LayoutEngine.layout(
            score: scoreA, options: .init(),
            availableWidth: 800, cache: cache)
        // Now edit measure 1: replace its content.
        var staff = scoreA.staves[0]
        var measures = staff.measures
        let editedMeasure1 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .half, notes: [
                Note(pitch: 60, tpc: 14)])),
            .rest(Rest(duration: .half))
        ])])
        measures[1] = editedMeasure1
        staff = StaffContent(id: staff.id, measures: measures)
        let scoreB = Score(division: scoreA.division, staves: [staff])
        _ = LayoutEngine.layout(
            score: scoreB, options: .init(),
            availableWidth: 800, cache: cache)
        // Measures 0 and 2 unchanged → 2 width hits; measure 1 → 1 miss.
        #expect(cache.widthHits == 2)
        #expect(cache.widthMisses == 1)
        // Placements track the same pattern: 2 hits, 1 miss.
        #expect(cache.placementHits == 2)
        #expect(cache.placementMisses == 1)
    }
}
#endif
