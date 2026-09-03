import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicLayout
import Testing

/// The `.smft` wire format, decoded from bytes assembled by hand so the test
/// pins the layout `FontMetricsTable`'s doc comment promises rather than
/// whatever the committed table happens to contain. `ShippedMetricsTableTests`
/// covers the committed table and is Apple-only, since it reaches the file
/// through `#filePath`; this suite runs on every shape, WebAssembly included,
/// which is where a decoder that silently accepts the wrong layout does its
/// damage.
@Suite("Font metrics table wire format")
struct FontMetricsTableTests {
    struct GlyphBytes {
        var codepoint: UInt32
        var advance: Float
        var bboxX: Float
        var bboxY: Float
        var bboxW: Float
        var bboxH: Float
    }

    /// One face record: `u32 nameLen | name | f32 ascent | f32 descent |
    /// f32 leading | u32 glyphCount | entries`.
    struct FaceBytes {
        var name = "Bravura"
        var ascent: Float = 2012
        var descent: Float = 2012
        var leading: Float = 0
        var glyphs: [GlyphBytes] = [
            GlyphBytes(
                codepoint: 0xE0A4, advance: 295, // noteheadBlack
                bboxX: 0, bboxY: -125, bboxW: 295, bboxH: 250,
            ),
        ]
    }

    /// Little-endian SMFT bytes: `magic | version | f64 referenceSize |
    /// u32 faceCount | [face]`. The faces are a parameter so a v3-shaped
    /// header can be assembled for the rejection test, and every face carries
    /// at least one glyph so a header read at the wrong width shows up as a
    /// garbled entry rather than passing unnoticed.
    private static func bytes(
        version: UInt32 = FontMetricsTable.version,
        faces: [FaceBytes] = [FaceBytes()],
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
        func string(_ s: String) {
            let utf8 = Array(s.utf8)
            u32(UInt32(utf8.count))
            out.append(contentsOf: utf8)
        }
        u32(0x534D_4654)
        u32(version)
        f64(1000)
        u32(UInt32(faces.count))
        for face in faces {
            string(face.name)
            f32(face.ascent)
            f32(face.descent)
            f32(face.leading)
            u32(UInt32(face.glyphs.count))
            for glyph in face.glyphs {
                u32(glyph.codepoint)
                f32(glyph.advance)
                f32(glyph.bboxX)
                f32(glyph.bboxY)
                f32(glyph.bboxW)
                f32(glyph.bboxH)
            }
        }
        return Data(out)
    }

    private static let edwinFace = FaceBytes(
        name: "Edwin",
        ascent: 737,
        descent: 263,
        leading: 200,
        glyphs: [
            GlyphBytes(
                codepoint: 0x0041, advance: 722, // "A"
                bboxX: 20, bboxY: 0, bboxW: 680, bboxH: 700,
            ),
            GlyphBytes(
                codepoint: 0x0020, advance: 250, // space: an advance, no ink
                bboxX: 0, bboxY: 0, bboxW: 0, bboxH: 0,
            ),
        ],
    )

    @Test("a v3 table, whose header carries one face's metrics, is refused")
    func rejectsVersion3() {
        #expect(throws: FontMetricsTable.DecodeError.unsupportedVersion(3)) {
            try FontMetricsTable.decode(Self.bytes(version: 3))
        }
    }

    @Test("a face record cut off before its glyph count is truncated, not misread")
    func rejectsFaceTruncatedBeforeGlyphCount() {
        var data = Self.bytes(faces: [FaceBytes(glyphs: [])])
        // Drop `u32 glyphCount` and `f32 leading`; what remains ends after
        // `descent`.
        data.removeLast(8)
        #expect(throws: FontMetricsTable.DecodeError.truncated) {
            try FontMetricsTable.decode(data)
        }
    }

    /// Asymmetric values on purpose: Bravura's real pair is symmetric, so a
    /// decoder that swapped the two fields would pass against it.
    @Test("a face carries its ascent, descent and leading at the reference size")
    func decodesTheVerticalMetrics() throws {
        let table = try FontMetricsTable.decode(
            Self.bytes(faces: [
                FaceBytes(ascent: 2012, descent: 500, leading: 42),
            ]),
        )
        #expect(table.referenceSize == 1000)
        let face = try #require(table.face(named: "Bravura"))
        #expect(face.ascent == 2012)
        #expect(face.descent == 500)
        #expect(face.leading == 42)
        // The glyph loop starts after the widened face record, or this is
        // garbage.
        #expect(face.entries[0xE0A4]?.bboxY == -125)
    }

    @Test("every face in the table keeps its own metrics and its own glyphs")
    func decodesSeveralFaces() throws {
        let table = try FontMetricsTable.decode(
            Self.bytes(faces: [FaceBytes(), Self.edwinFace]),
        )
        #expect(table.faces.count == 2)
        let bravura = try #require(table.face(named: "Bravura"))
        let edwin = try #require(table.face(named: "Edwin"))
        #expect(bravura.ascent == 2012)
        #expect(edwin.ascent == 737)
        // Neither face's glyphs leaked into the other's map.
        #expect(bravura.entries[0xE0A4] != nil)
        #expect(bravura.entries[0x0041] == nil)
        #expect(edwin.entries[0x0041] != nil)
        #expect(edwin.entries[0xE0A4] == nil)
    }

    /// A score's `<font face="…">` is author-supplied text.
    @Test("a face is found whatever case the score spells it in")
    func facesAreMatchedCaseInsensitively() throws {
        let table = try FontMetricsTable.decode(
            Self.bytes(faces: [Self.edwinFace]),
        )
        #expect(table.face(named: "edwin")?.name == "Edwin")
        #expect(table.face(named: "EDWIN")?.name == "Edwin")
        #expect(table.face(named: "Helvetica") == nil)
    }

    @Test("the provider scales Bravura's ascent and descent from the table")
    func providerServesBravuraAscentAndDescentFromTheTable() throws {
        let table = try FontMetricsTable.decode(
            Self.bytes(faces: [FaceBytes(ascent: 2012, descent: 500)]),
        )
        let provider = makeFontMetricsTableProvider(table: table)
        let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        #expect(abs(Double(provider.ascent(font: bravuraEm)) - 8.048) < 1e-9)
        #expect(abs(Double(provider.descent(font: bravuraEm)) - 2.0) < 1e-9)
    }

    /// The stub reports no line gap at all, so a text face measured into the
    /// table is the only way a non-Apple host stacks multi-line annotations
    /// the way CoreText does.
    @Test("the provider scales the text face's metrics, line gap included")
    func providerServesTheTextFaceFromTheTable() throws {
        let table = try FontMetricsTable.decode(
            Self.bytes(faces: [FaceBytes(), Self.edwinFace]),
        )
        let provider = makeFontMetricsTableProvider(table: table)
        let edwin = LayoutFont(face: "Edwin", pointSize: 10)
        #expect(abs(Double(provider.ascent(font: edwin)) - 7.37) < 1e-9)
        #expect(abs(Double(provider.descent(font: edwin)) - 2.63) < 1e-9)
        #expect(abs(Double(provider.leading(font: edwin)) - 2.0) < 1e-9)
        // …and the advance comes from the table, not the stub's 0.65 em
        // uppercase bucket.
        #expect(abs(Double(provider.typographicWidth(text: "A", font: edwin)) - 7.22) < 1e-9)
    }

    /// A glyph with an advance but no ink moves the pen and claims no width,
    /// or a trailing space would pad every rehearsal-mark frame.
    @Test("a blank glyph advances the pen without claiming ink")
    func blankGlyphsAdvanceWithoutInk() throws {
        let table = try FontMetricsTable.decode(
            Self.bytes(faces: [Self.edwinFace]),
        )
        let provider = makeFontMetricsTableProvider(table: table)
        let edwin = LayoutFont(face: "Edwin", pointSize: 10)
        #expect(abs(Double(provider.typographicWidth(text: "A ", font: edwin)) - 9.72) < 1e-9)
        let ink = provider.inkBounds(text: "A ", font: edwin)
        #expect(abs(Double(ink.leftBearing) - 0.2) < 1e-9)
        #expect(abs(Double(ink.width) - 6.8) < 1e-9)
    }

    /// Edwin has no CJK at all, so a Japanese lyric has to keep degrading to
    /// the estimate a platform with no table would have used — 1 em per
    /// ideograph, not the 0.5 em a flat per-glyph fallback would have given.
    @Test("a codepoint the face lacks falls back per scalar, not to a flat guess")
    func missingCodepointsFallBackToTheStubPerScalar() throws {
        let table = try FontMetricsTable.decode(
            Self.bytes(faces: [Self.edwinFace]),
        )
        let provider = makeFontMetricsTableProvider(table: table)
        let stub = StubFontMetricsProvider()
        let edwin = LayoutFont(face: "Edwin", pointSize: 10)
        let kanji = "歌"
        #expect(
            provider.typographicWidth(text: kanji, font: edwin)
                == stub.typographicWidth(text: kanji, font: edwin),
        )
        #expect(abs(Double(provider.typographicWidth(text: kanji, font: edwin)) - 10) < 1e-9)
    }

    /// The table carries the faces this library bundles. Anything else — a
    /// score naming Times New Roman, say — keeps the stub's formula, the same
    /// boundary `glyphPathBoundingBox` and `typographicWidth` draw.
    @Test("the provider leaves a face the table does not carry on the stub")
    func providerLeavesUnknownFacesOnTheStub() throws {
        let table = try FontMetricsTable.decode(Self.bytes())
        let provider = makeFontMetricsTableProvider(table: table)
        let stub = StubFontMetricsProvider()
        let times = LayoutFont(face: "Times New Roman", pointSize: 10)
        #expect(provider.ascent(font: times) == stub.ascent(font: times))
        #expect(provider.descent(font: times) == stub.descent(font: times))
        #expect(provider.leading(font: times) == stub.leading(font: times))
    }
}
