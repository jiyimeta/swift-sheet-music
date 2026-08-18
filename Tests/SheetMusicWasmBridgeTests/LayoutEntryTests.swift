@testable import SheetMusicBridgeCore
import SheetMusicFoundation
@testable import SheetMusicWasmBridge
import Testing

@Suite("layout entry points")
struct LayoutEntryTests {
    @Test("computeLayout returns decodable flat bytes")
    func computeLayoutReturnsFlatBytes() throws {
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        let bytes = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        #expect(!bytes.isEmpty)
        let pages = try DrawProgramFlat.decode(Data(bytes))
        let first = try #require(pages.first)
        #expect(first.widthMM == 210)
        #expect(!first.commands.isEmpty)
    }

    @Test("computeLayout for an unknown handle returns empty")
    func computeLayoutForUnknownHandleIsEmpty() {
        #expect(computeLayout(handle: 999_999, pageWidthMM: 210, pageHeightMM: 297).isEmpty)
    }

    @Test("pageBreaks reports one more boundary than pages")
    func pageBreaksShape() throws {
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
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
        let handle = try loadScore(bytes: SampleScore.mscz())
        defer { releaseScore(handle: handle) }
        #expect(pageBreaks(handle: handle, pageHeightMM: 297).isEmpty)
    }

    @Test("releasing a score drops its cached layout")
    func releaseDropsTheCachedLayout() throws {
        let handle = try loadScore(bytes: SampleScore.mscz())
        _ = computeLayout(handle: handle, pageWidthMM: 210, pageHeightMM: 297)
        releaseScore(handle: handle)
        #expect(pageBreaks(handle: handle, pageHeightMM: 297).isEmpty)
    }

    @Test("installSMuFLMetrics rejects an empty payload")
    func installRejectsEmpty() {
        #expect(installSMuFLMetrics(bytes: []) == false)
    }

    @Test("installSMuFLMetrics rejects garbage")
    func installRejectsGarbage() {
        #expect(installSMuFLMetrics(bytes: [0xFF, 0xFF, 0xFF, 0xFF]) == false)
    }

    @Test("installSMuFLMetrics accepts a well-formed table")
    func installAcceptsWellFormedTable() {
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
        #expect(installSMuFLMetrics(bytes: bytes) == true)
    }
}
