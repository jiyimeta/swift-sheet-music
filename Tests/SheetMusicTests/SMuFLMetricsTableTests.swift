import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
import Testing

/// The `.smft` wire format, decoded from bytes assembled by hand so the test
/// pins the layout `SMuFLMetricsTable`'s doc comment promises rather than
/// whatever the committed table happens to contain. `BravuraMetricsTableTests`
/// covers the committed table and is Apple-only, since it reaches the file
/// through `#filePath`; this suite runs on every shape, WebAssembly included,
/// which is where a decoder that silently accepts the wrong layout does its
/// damage.
@Suite("SMuFL metrics table wire format")
struct SMuFLMetricsTableTests {
    /// Little-endian SMFT bytes: `magic | version | f64 referenceSize |
    /// [f32 ascent | f32 descent] | u32 count | one noteheadBlack entry`.
    /// The ascent/descent pair is optional so a v2-shaped header can be
    /// assembled for the rejection test, and the single glyph is there so a
    /// header read at the wrong width shows up as a garbled entry rather than
    /// passing unnoticed.
    private static func bytes(
        version: UInt32,
        ascent: Float? = 2012,
        descent: Float? = 2012,
        glyphCount: UInt32 = 1,
    ) -> Data {
        var out: [UInt8] = []
        func u32(_ v: UInt32) {
            for i in 0 ..< 4 {
                out.append(UInt8(truncatingIfNeeded: v >> (8 * i)))
            }
        }
        func f32(_ v: Float) {
            u32(v.bitPattern)
        }
        func f64(_ v: Double) {
            let b = v.bitPattern
            for i in 0 ..< 8 {
                out.append(UInt8(truncatingIfNeeded: b >> (8 * i)))
            }
        }
        u32(0x534D_4654)
        u32(version)
        f64(1000)
        if let ascent {
            f32(ascent)
        }
        if let descent {
            f32(descent)
        }
        u32(glyphCount)
        if glyphCount > 0 {
            u32(0xE0A4) // noteheadBlack
            f32(295) // advance
            f32(0) // bboxX
            f32(-125) // bboxY
            f32(295) // bboxW
            f32(250) // bboxH
        }
        return Data(out)
    }

    @Test("a v2 table, which carries no ascent or descent, is refused")
    func rejectsVersion2() {
        #expect(throws: SMuFLMetricsTable.DecodeError.unsupportedVersion(2)) {
            try SMuFLMetricsTable.decode(Self.bytes(version: 2, ascent: nil, descent: nil))
        }
    }

    @Test("a v3 header cut off before its descent is truncated, not misread")
    func rejectsHeaderTruncatedBeforeDescent() {
        var data = Self.bytes(version: 3, glyphCount: 0)
        // Drop `u32 count` and `f32 descent`; what remains ends after `ascent`.
        data.removeLast(8)
        #expect(throws: SMuFLMetricsTable.DecodeError.truncated) {
            try SMuFLMetricsTable.decode(data)
        }
    }

    /// Asymmetric values on purpose: Bravura's real pair is symmetric, so a
    /// decoder that swapped the two fields would pass against it.
    @Test("a v3 table carries the face's ascent and descent at the reference size")
    func decodesAscentAndDescent() throws {
        let table = try SMuFLMetricsTable.decode(
            Self.bytes(version: 3, ascent: 2012, descent: 500),
        )
        #expect(table.referenceSize == 1000)
        #expect(table.ascent == 2012)
        #expect(table.descent == 500)
        // The glyph loop starts after the widened header, or this is garbage.
        #expect(table.entries[0xE0A4]?.bboxY == -125)
    }

    @Test("the provider scales Bravura's ascent and descent from the table")
    func providerServesBravuraAscentAndDescentFromTheTable() throws {
        let table = try SMuFLMetricsTable.decode(
            Self.bytes(version: 3, ascent: 2012, descent: 500),
        )
        let provider = makeSMuFLMetricsTableProvider(table: table)
        let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        #expect(abs(Double(provider.ascent(font: bravuraEm)) - 8.048) < 1e-9)
        #expect(abs(Double(provider.descent(font: bravuraEm)) - 2.0) < 1e-9)
    }

    /// The table measures one face. Text faces keep the stub's formula, the
    /// same boundary `glyphPathBoundingBox` and `typographicWidth` draw.
    @Test("the provider leaves faces other than Bravura on the stub")
    func providerLeavesOtherFacesOnTheStub() throws {
        let table = try SMuFLMetricsTable.decode(Self.bytes(version: 3))
        let provider = makeSMuFLMetricsTableProvider(table: table)
        let stub = StubFontMetricsProvider()
        let edwin = LayoutFont(face: "Edwin", pointSize: 10)
        #expect(provider.ascent(font: edwin) == stub.ascent(font: edwin))
        #expect(provider.descent(font: edwin) == stub.descent(font: edwin))
    }
}
