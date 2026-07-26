#if canImport(CoreGraphics)
    import CoreGraphics
    import CoreText
#endif
import Foundation
import SheetMusicLayoutApple

/// Reference descriptors for Tier 4 nearest-neighbor classification, rendered
/// from the bundled Bravura (SIL OFL) reference font.
///
/// Built from the SAME codepoint list `PDFImporter.smuflSemantic` recognizes,
/// so the exemplar set and the label set cannot drift apart.
enum BravuraExemplars {
    static let all: [(semantic: SMuFLSemantic, descriptor: ShapeDescriptor)] = build()

    /// Every codepoint `smuflSemantic` classifies. Keep in sync with
    /// `PDFImporter+SMuFL.swift`; `buildsExemplarForEveryClassifiableSemantic`
    /// in the test suite fails if a semantic loses its exemplar.
    static let codepoints: [UInt32] = {
        var out: [UInt32] = [
            0xE000, 0xE003, 0xE043, 0xE047, 0xE048,
            0xE050, 0xE051, 0xE052, 0xE053, 0xE054,
            0xE05C, 0xE062, 0xE063, 0xE064, 0xE065, 0xE066, 0xE069,
            0xE08A, 0xE08B,
            0xE0A1, 0xE0A2, 0xE0A3, 0xE0A4,
            0xE0A7, 0xE0A8, 0xE0A9, 0xE0B7, 0xE1B9,
            0xE1E7,
            0xE240, 0xE241, 0xE242, 0xE243, 0xE244, 0xE245, 0xE246, 0xE247,
            0xE260, 0xE261, 0xE262, 0xE263, 0xE264,
            0xE4C0,
            0xE4E3, 0xE4E4, 0xE4E5, 0xE4E6, 0xE4E7, 0xE4E8, 0xE4E9,
        ]
        out.append(contentsOf: (0 ... 9).map { 0xE080 + UInt32($0) })
        return out
    }()

    private static func build() -> [(SMuFLSemantic, ShapeDescriptor)] {
        guard let font = referenceFont() else { return [] }
        var out: [(SMuFLSemantic, ShapeDescriptor)] = []
        for cp in codepoints {
            let semantic = PDFImporter.smuflSemantic(codepoint: cp)
            if case .unknown = semantic { continue }
            guard let scalar = Unicode.Scalar(cp) else { continue }
            var chars = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: chars.count)
            guard CTFontGetGlyphsForCharacters(
                font, &chars, &glyphs, chars.count,
            ), let glyph = glyphs.first, glyph != 0 else { continue }
            guard let path = CTFontCreatePathForGlyph(font, glyph, nil),
                  !path.isEmpty else { continue }
            out.append((semantic, makeDescriptor(path: path)))
        }
        return out
    }

    /// The bundled Bravura face at a large size so outlines are well resolved.
    ///
    /// Uses the codebase's established pattern (see
    /// `ShapeDescriptorTests.bravuraGlyphPath` /
    /// `AppleFontMetricsProvider.swift:19`): touch `BravuraFont.register` (a
    /// `static let`, so registration happens once, lazily) then resolve the
    /// family by name. `BravuraFont` requires macOS 15 (this package's
    /// deployment target is macOS 14), so the availability check has to be a
    /// local guard rather than an attribute on this enum.
    private static func referenceFont() -> CTFont? {
        guard #available(macOS 15.0, *), BravuraFont.register else { return nil }
        return CTFontCreateWithName(
            BravuraFont.familyName as CFString, 1000, nil,
        )
    }
}
