#if os(macOS)
import Foundation
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
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

    /// Realistic equivalence: layouts of a parsed mscx fixture must
    /// be byte-identical between cache-less and cache-aware paths.
    @Test("Real mscx fixture: cache-aware layout matches cache-less")
    func realFixtureEquivalence() throws {
        guard #available(macOS 15.0, *) else { return }
        let fixtures = ["midi01", "midi02", "midi03",
                        "testArpeggio", "testVoltaDynamic",
                        "testRepeatsWithKeySigs"]
        for name in fixtures {
            guard let url = Bundle.module.url(
                forResource: name, withExtension: "mscx") else {
                Issue.record("Missing fixture: \(name).mscx")
                continue
            }
            let data = try Data(contentsOf: url)
            let score = try MSCXParser.parse(data)
            let baseline = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800)
            let cache = LayoutCache()
            let cached = LayoutEngine.layout(
                score: score, options: .init(),
                availableWidth: 800, cache: cache)
            #expect(cached.systems == baseline.systems,
                    "systems differ for \(name)")
            #expect(cached.size == baseline.size,
                    "size differs for \(name)")
        }
    }

    /// On a real fixture, a warm second call must hit the cache
    /// for every measure / staff combination.
    @Test("Real mscx fixture: warm call is fully cached")
    func realFixtureWarmHitRate() throws {
        guard #available(macOS 15.0, *) else { return }
        guard let url = Bundle.module.url(
            forResource: "midi01", withExtension: "mscx") else {
            Issue.record("Missing fixture: midi01.mscx")
            return
        }
        let score = try MSCXParser.parse(try Data(contentsOf: url))
        let cache = LayoutCache()
        _ = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 800, cache: cache)
        let widthMissesCold = cache.widthMisses
        let placementMissesCold = cache.placementMisses
        _ = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 800, cache: cache)
        // Warm call: zero misses, every prior miss is now a hit.
        #expect(cache.widthMisses == 0)
        #expect(cache.placementMisses == 0)
        #expect(cache.widthHits == widthMissesCold)
        #expect(cache.placementHits == placementMissesCold)
    }

    /// Changing the staffSize (which changes `metrics.sp`) must
    /// invalidate every per-measure entry — none of the cached
    /// widths or placements remain valid at a different sp.
    @Test("Changing staffSize invalidates the entire cache")
    func staffSizeChangeInvalidates() throws {
        guard #available(macOS 15.0, *) else { return }
        guard let url = Bundle.module.url(
            forResource: "midi01", withExtension: "mscx") else {
            Issue.record("Missing fixture: midi01.mscx")
            return
        }
        let score = try MSCXParser.parse(try Data(contentsOf: url))
        let cache = LayoutCache()
        _ = LayoutEngine.layout(
            score: score, options: ScoreViewOptions(staffSize: 7),
            availableWidth: 800, cache: cache)
        _ = LayoutEngine.layout(
            score: score, options: ScoreViewOptions(staffSize: 9),
            availableWidth: 800, cache: cache)
        // sp changed → every measure should miss again.
        #expect(cache.widthHits == 0)
        #expect(cache.widthMisses > 0)
        #expect(cache.placementHits == 0)
        #expect(cache.placementMisses > 0)
    }
}
#endif
