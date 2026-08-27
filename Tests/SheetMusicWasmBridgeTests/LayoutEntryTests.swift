@testable import SheetMusicBridgeCore
import SheetMusicFoundation
import SheetMusicLayout
@testable import SheetMusicWasmBridge
import Testing

@Suite("layout entry points")
struct LayoutEntryTests {
    @Test("computeLayout returns decodable flat bytes")
    func computeLayoutReturnsFlatBytes() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        let bytes = computeLayout(
            handle: handle, pageWidthMM: 210, pageHeightMM: 297, options: layoutOptions(),
        )
        #expect(!bytes.isEmpty)
        let pages = try DrawProgramFlat.decode(bytes.bridgedData)
        let first = try #require(pages.first)
        #expect(first.widthMM == 210)
        #expect(!first.commands.isEmpty)
    }

    @Test("computeLayout for an unknown handle returns empty")
    func computeLayoutForUnknownHandleIsEmpty() {
        #expect(
            computeLayout(
                handle: 999_999, pageWidthMM: 210, pageHeightMM: 297, options: layoutOptions(),
            ).isEmpty,
        )
    }

    @Test("pageBreaks reports one more boundary than pages")
    func pageBreaksShape() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        _ = computeLayout(
            handle: handle, pageWidthMM: 210, pageHeightMM: 297, options: layoutOptions(),
        )
        let breaks = pageBreaks(handle: handle, pageHeightMM: 297)
        try #require(breaks.count >= 2)
        #expect(breaks[0] == 0)
        #expect(breaks[breaks.count - 1] > 0)
    }

    /// `pageBreaks` reads the cached document rather than re-engraving, so a
    /// handle that has never been laid out has nothing to report. Returning
    /// empty rather than laying out implicitly keeps the cost of the call
    /// predictable.
    @Test("pageBreaks before a layout returns empty")
    func pageBreaksWithoutLayoutIsEmpty() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: handle) }
        #expect(pageBreaks(handle: handle, pageHeightMM: 297).isEmpty)
    }

    @Test("releasing a score drops its cached layout")
    func releaseDropsTheCachedLayout() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        _ = computeLayout(
            handle: handle, pageWidthMM: 210, pageHeightMM: 297, options: layoutOptions(),
        )
        releaseScore(handle: handle)
        #expect(pageBreaks(handle: handle, pageHeightMM: 297).isEmpty)
    }

    @Test("page layout can produce multiple pages")
    func pageLayoutCanProduceMultiplePages() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.longScore())))
        defer { releaseScore(handle: handle) }
        let bytes = computeLayout(
            handle: handle,
            pageWidthMM: 210,
            pageHeightMM: 80,
            options: layoutOptions(layoutMode: 2),
        )
        let pages = try DrawProgramFlat.decode(bytes.bridgedData)
        #expect(pages.count > 1)
    }

    @Test("pageBreaks follows the cached layout break policy")
    func pageBreaksFollowsCachedBreakPolicy() throws {
        let handle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.pageBreakScore())))
        defer { releaseScore(handle: handle) }

        _ = computeLayout(
            handle: handle,
            pageWidthMM: 210,
            pageHeightMM: 297,
            options: layoutOptions(honorLayoutBreaks: false),
        )
        #expect(pageBreaks(handle: handle, pageHeightMM: 10000).count == 2)

        _ = computeLayout(
            handle: handle,
            pageWidthMM: 210,
            pageHeightMM: 297,
            options: layoutOptions(honorLayoutBreaks: true),
        )
        #expect(pageBreaks(handle: handle, pageHeightMM: 10000).count == 3)
    }

    @Test("transpose and hidden staves change flat bytes")
    func optionsAffectFlatBytes() throws {
        let transposedHandle = try loadScore(bytes: jsBytes(SampleScore.mscz()))
        defer { releaseScore(handle: transposedHandle) }
        let normal = computeLayout(
            handle: transposedHandle,
            pageWidthMM: 210,
            pageHeightMM: 297,
            options: layoutOptions(),
        ).bridgedData
        let transposed = computeLayout(
            handle: transposedHandle,
            pageWidthMM: 210,
            pageHeightMM: 297,
            options: layoutOptions(transposeSemitones: 2),
        ).bridgedData
        #expect(transposed != normal)

        let hiddenHandle = try loadScore(bytes: jsBytes(SampleScore.mscz(score: SampleScore.twoStaffScore())))
        defer { releaseScore(handle: hiddenHandle) }
        let visibleStaves = computeLayout(
            handle: hiddenHandle,
            pageWidthMM: 210,
            pageHeightMM: 297,
            options: layoutOptions(),
        ).bridgedData
        let hiddenStaff = computeLayout(
            handle: hiddenHandle,
            pageWidthMM: 210,
            pageHeightMM: 297,
            options: layoutOptions(hiddenStaves: [HiddenStaff(partIndex: 0, staffIndexInPart: 1)]),
        ).bridgedData
        #expect(hiddenStaff != visibleStaves)
    }

    @Test("installSMuFLMetrics rejects an empty payload")
    func installRejectsEmpty() {
        #expect(installSMuFLMetrics(bytes: jsBytes([])) == false)
    }

    @Test("installSMuFLMetrics rejects garbage")
    func installRejectsGarbage() {
        #expect(installSMuFLMetrics(bytes: jsBytes([0xFF, 0xFF, 0xFF, 0xFF])) == false)
    }

    @Test("installSMuFLMetrics accepts a well-formed table")
    func installAcceptsWellFormedTable() {
        // `installSMuFLMetrics` mutates the process-wide `FontMetrics.provider`
        // — the same global `Tests/SheetMusicTests` suites read after installing
        // the real Bravura table through `TestSupport.installFontMetrics`. Both
        // test targets link into one merged wasm test binary/process (`swift
        // package … js test` builds every declared test target together), so
        // without a restore this single-glyph synthetic table stays installed
        // for whichever `SheetMusicTests` suite happens to read
        // `FontMetrics.provider` next — silently substituting stub-shaped
        // glyph bboxes for codepoints this table never measured (e.g.
        // articulation glyphs) and failing tests that assert exact geometry,
        // with no relation to which font-metrics provider they intended to use.
        let previousProvider = FontMetrics.provider
        defer { FontMetrics.provider = previousProvider }

        // SMFT v2 with a single glyph, assembled by hand so the wasm suite needs
        // no preopened directory. Layout: magic | version | f64 referenceSize |
        // u32 count | (u32 codepoint + f32 × 5). See `SMuFLMetricsTable.swift`.
        var bytes: [UInt8] = []
        func u32(_ v: UInt32) {
            for i in 0 ..< 4 {
                bytes.append(UInt8(truncatingIfNeeded: v >> (8 * i)))
            }
        }
        func f32(_ v: Float) {
            u32(v.bitPattern)
        }
        func f64(_ v: Double) {
            let b = v.bitPattern
            for i in 0 ..< 8 {
                bytes.append(UInt8(truncatingIfNeeded: b >> (8 * i)))
            }
        }
        u32(0x534D_4654)
        u32(2)
        f64(1000)
        u32(1)
        u32(0xE0A4) // noteheadBlack
        f32(295)
        f32(0)
        f32(-125)
        f32(295)
        f32(250)
        #expect(installSMuFLMetrics(bytes: jsBytes(bytes)) == true)
    }

    private func layoutOptions(
        layoutMode: Int = 0,
        staffSize: Double = 28,
        honorLayoutBreaks: Bool = true,
        collapseMultiMeasureRests: Bool = false,
        showsInvisibleElements: Bool = false,
        showsLyrics: Bool = true,
        transposeSemitones: Int = 0,
        hiddenStaves: [HiddenStaff] = [],
        clefOverrides: [ClefOverride] = [],
    ) -> LayoutOptions {
        LayoutOptions(
            layoutMode: layoutMode,
            staffSize: staffSize,
            honorLayoutBreaks: honorLayoutBreaks,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
            showsInvisibleElements: showsInvisibleElements,
            showsLyrics: showsLyrics,
            transposeSemitones: transposeSemitones,
            hiddenStaves: hiddenStaves,
            clefOverrides: clefOverrides,
        )
    }
}
