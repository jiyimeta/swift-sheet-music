#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterGlyphGeometryTests {
        @Test func geometryIsHashableAndValueEqual() {
            let a = GlyphGeometry(
                origin: CGPoint(x: 10, y: 20), advance: 5,
                renderedSize: 12, pageIndex: 0, fontSize: 20,
            )
            let b = GlyphGeometry(
                origin: CGPoint(x: 10, y: 20), advance: 5,
                renderedSize: 12, pageIndex: 0, fontSize: 20,
            )
            let c = GlyphGeometry(
                origin: CGPoint(x: 11, y: 20), advance: 5,
                renderedSize: 12, pageIndex: 0, fontSize: 20,
            )
            #expect(a == b)
            #expect(Set([a, b, c]).count == 2)
        }

        @Test func classifiedGlyphHashesOnGeometryAndSemantic() {
            let geo = GlyphGeometry(
                origin: CGPoint(x: 10, y: 20), advance: 5,
                renderedSize: 12, pageIndex: 0, fontSize: 20,
            )
            let head = ClassifiedGlyph(
                raw: RawGlyph(
                    codepoint: 0xE0A4, fontName: "Bravura", fontSize: 20,
                    origin: geo.origin, advance: 5, pageIndex: 0,
                ),
                semantic: .noteheadBlack,
            )
            let rest = ClassifiedGlyph(
                raw: RawGlyph(
                    codepoint: 0xE4E5, fontName: "Bravura", fontSize: 20,
                    origin: geo.origin, advance: 5, pageIndex: 0,
                ),
                semantic: .rest(.quarter),
            )
            // Same geometry, different semantic ⇒ distinct keys.
            #expect(Set([head, rest]).count == 2)
        }
    }
#endif
