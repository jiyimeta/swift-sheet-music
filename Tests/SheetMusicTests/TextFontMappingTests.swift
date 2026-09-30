@testable import SheetMusicBridgeCore
import SheetMusicLayout
import Testing

/// The font id a text command carries has to name the face the layout measured it in — a renderer draws at an x whose
/// anchor was resolved against that face's ink. So the mapping from a resolved `LayoutFont` is pinned as a full table:
/// every face class against every weight, upright and italic.
@Suite("TextFontMapping")
struct TextFontMappingTests {
    /// The face, and the id it must map to.
    private static let faces: [(face: String, fontId: DrawProgram.FontID)] = [
        (SMuFLFamily.bravura, .smufl),
        ("", .system),
        ("Edwin", .textRoman),
    ]

    /// The weight and slant, and the `setTextStyle` mask they must map to — spelled as the wire bits (bold 1, italic 2,
    /// semibold 4) so a renumbered flag fails here too.
    private static let styles: [(weight: FontWeight, isItalic: Bool, flags: UInt8)] = [
        (.regular, false, 0),
        (.regular, true, 2),
        (.semibold, false, 4),
        (.semibold, true, 6),
        (.bold, false, 1),
        (.bold, true, 3),
    ]

    @Test("maps face × weight × italic", arguments: faces, styles)
    func mapsTheTable(
        face: (face: String, fontId: DrawProgram.FontID),
        style: (weight: FontWeight, isItalic: Bool, flags: UInt8),
    ) {
        let font = LayoutFont(face: face.face, pointSize: 10, weight: style.weight, isItalic: style.isItalic)
        let wire = TextFontMapping.wire(for: font)
        #expect(wire.fontId == face.fontId)
        #expect(wire.style == style.flags)
    }

    /// Point size is the layout's business; it never changes which face or style the wire names.
    @Test("ignores the point size")
    func ignoresThePointSize() {
        let small = TextFontMapping.wire(for: LayoutFont(face: "", pointSize: 6, weight: .semibold))
        let large = TextFontMapping.wire(for: LayoutFont(face: "", pointSize: 40, weight: .semibold))
        #expect(small.fontId == large.fontId)
        #expect(small.style == large.style)
    }
}
