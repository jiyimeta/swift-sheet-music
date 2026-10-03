@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicWasmBridge
import Testing

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// `editingMeasureHit`, the browser twin of Android's `nativeEditingMeasureHitTest`.
@Suite("edit measure-hit entry point")
struct EditMeasureHitEntryTests {
    private static let ptToMM = 25.4 / 72.0

    @Test("editingMeasureHit names the bar and staff a point falls in")
    func namesTheBar() throws {
        let handle = try Self.loadedHandle(score: SampleScore.score())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297, options: Self.layoutOptions())
        let point = try #require(Self.barCentre(0, row: 0, handle: handle))

        let hit = try #require(editingMeasureHit(handle: handle, xMM: point.x, yMM: point.y))
        #expect(hit.partIndex == 0)
        #expect(hit.staffIndexInPart == 0)
        #expect(hit.firstMeasureIndex == 0)
        #expect(hit.lastMeasureIndex == 0)
    }

    @Test("editingMeasureHit re-addresses past the cached hidden staves")
    func usesTheCachedHiddenStaves() throws {
        let handle = try Self.loadedHandle(score: SampleScore.twoStaffScore())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(
            handle: handle, pageWidthMM: 210, pageHeightMM: 297,
            options: Self.layoutOptions(hiddenStaves: [HiddenStaff(partIndex: 0, staffIndexInPart: 0)]),
        )
        let point = try #require(Self.barCentre(0, row: 0, handle: handle))

        let hit = try #require(editingMeasureHit(handle: handle, xMM: point.x, yMM: point.y))
        #expect(hit.partIndex == 0)
        #expect(hit.staffIndexInPart == 1)
    }

    @Test("editingMeasureHit returns nil on empty paper and for an unknown handle")
    func missesReturnNil() throws {
        let handle = try Self.loadedHandle(score: SampleScore.score())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297, options: Self.layoutOptions())
        #expect(editingMeasureHit(handle: handle, xMM: 0, yMM: -500 * Self.ptToMM) == nil)
        #expect(editingMeasureHit(handle: 999_999, xMM: 0, yMM: 0) == nil)
    }

    /// Bar `index`'s centre on the middle line of the cached layout's row `row`, in document mm.
    private static func barCentre(_ index: Int, row: Int, handle: Int) -> (x: Double, y: Double)? {
        guard let document = LayoutDocumentCache.value(for: Int64(handle)),
              let system = document.systems.first(where: { $0.measures.contains { $0.measureIndex == index } }),
              let measure = system.measures.first(where: { $0.measureIndex == index }),
              system.staffOrigins.indices.contains(row)
        else { return nil }
        let x = system.origin.x + measure.origin.x + measure.width / 2
        let y = system.origin.y + system.staffOrigins[row].y + 2 * document.metrics.sp
        return (Double(x) * ptToMM, Double(y) * ptToMM)
    }

    private static func loadedHandle(score: Score) throws -> Int {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: score)))
        #expect(handle != 0)
        return handle
    }

    /// `EditGeometryEntryTests.layoutOptions(hiddenStaves:)`, which is file-private there.
    private static func layoutOptions(hiddenStaves: [HiddenStaff] = []) -> LayoutOptions {
        LayoutOptions(
            layoutMode: 0, staffSize: 28, breakPolicyRaw: 0,
            collapseMultiMeasureRests: false, showsInvisibleElements: false, showsLyrics: true,
            transposeSemitones: 0, hiddenStaves: hiddenStaves, clefOverrides: [],
            spacing: EngravingSpacingOptions(
                minNoteDistance: -1, spacePerQuarter: -1, systemStretch: -1,
                marginTop: -1, marginLeading: -1, marginBottom: -1, marginTrailing: -1,
                firstSystemIndent: -1, continuationSystemIndent: -1, minStaffGap: -1, systemVerticalPadding: -1,
            ),
        )
    }
}
