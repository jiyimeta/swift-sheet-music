import SheetMusicFoundation

/// One font a PDF draws with: a Type0 font over a CIDFont whose program is the font file — an OpenType file with CFF
/// outlines embedded whole as `FontFile3 /OpenType` under `CIDFontType0`, one with TrueType outlines (the platform UI
/// face, a CJK fallback) cut to the glyphs drawn (`TrueTypeSubset`) as `FontFile2` under `CIDFontType2` — glyphs
/// addressed by id through `Identity-H` (two bytes a glyph in a `Tj`), and a `ToUnicode` map from each glyph used back
/// to the text it stands for, so the PDF's text can be searched and copied.
///
/// CFF whole rather than subset: Bravura and Edwin are SIL OFL, which allows it, and a CFF subsetter is a compiler of
/// its own. One embedding per face for the whole document, however many pages use it.
final class PDFFontEmbedding {
    /// What a content stream shows for one character: its two-byte code, and whether the face lacks it — then the
    /// code is one past the font's glyphs, shown as invisible text so the `ToUnicode` map can still name it.
    struct Code {
        let hex: String
        let isMissing: Bool
    }

    let font: OpenTypeFont
    /// The PostScript-style name the PDF gives it (`/BaseFont`): no spaces.
    let baseName: String
    /// Its key in a page's `/Font` resources (`F1`, …), which the content stream names in `Tf`.
    let resourceName: String
    /// A symbolic font (Bravura) has no Latin text in it to speak of; the flag tells a reader not to map its codes
    /// through a standard encoding.
    let symbolic: Bool
    /// Every code drawn, with the scalars it stands for — the first text that used it.
    private(set) var used: [Int: [UInt32]] = [:]
    /// The codes handed out for characters the face lacks, past its last glyph.
    private var missing: [UInt32: Int] = [:]

    init(font: OpenTypeFont, baseName: String, resourceName: String, symbolic: Bool) {
        self.font = font
        self.baseName = baseName
        self.resourceName = resourceName
        self.symbolic = symbolic
    }

    /// Records that `glyph` is drawn for `scalars`. A glyph used again keeps the scalars it was first used for.
    func use(_ glyph: Int, for scalars: [UInt32]) {
        if used[glyph] == nil { used[glyph] = scalars }
    }

    /// The code that shows `scalar`, recorded as used: its glyph, or for a character the face lacks a code of its own
    /// past the last glyph (the same one each time), which draws `.notdef` and so is shown invisibly.
    func code(for scalar: UInt32) -> Code {
        let glyph = font.glyph(for: scalar)
        if glyph != 0 {
            use(glyph, for: [scalar])
            return Code(hex: PDFString.hex4(UInt16(glyph)), isMissing: false)
        }
        let code = missing[scalar] ?? font.glyphCount + missing.count
        guard code <= Int(UInt16.max) else { return Code(hex: "0000", isMissing: true) }
        missing[scalar] = code
        use(code, for: [scalar])
        return Code(hex: PDFString.hex4(UInt16(code)), isMissing: true)
    }

    /// Writes the Type0 font, its CIDFont, the font descriptor, the font program and the `ToUnicode` map into
    /// `writer`, and returns the Type0 font's object number for the pages' resources.
    func embed(into writer: PDFObjectWriter) throws -> Int {
        let type0 = writer.reserve()
        let cidFont = writer.reserve()
        let descriptor = writer.reserve()
        let program = writer.reserve()
        let toUnicode = writer.reserve()
        let glyphs = used.keys.sorted()
        // A subset is named with a tag of its own, as ISO 32000-1 §9.6.4 requires, so a reader never takes it for the
        // whole font — or for another document's subset of it.
        let name = font.hasCFFOutlines ? baseName : "\(Self.subsetTag(glyphs))+\(baseName)"
        // A missing character's code is no glyph of the font's: a full em, for a reader that selects the text.
        let widths = glyphs.map { "\($0) [\($0 < font.glyphCount ? font.width(of: $0) : 1000)]" }
            .joined(separator: " ")
        writer.object(
            type0,
            "<< /Type /Font /Subtype /Type0 /BaseFont /\(name) /Encoding /Identity-H "
                + "/DescendantFonts [\(cidFont) 0 R] /ToUnicode \(toUnicode) 0 R >>",
        )
        writer.object(
            cidFont,
            "<< /Type /Font /Subtype /\(font.hasCFFOutlines ? "CIDFontType0" : "CIDFontType2") /BaseFont /\(name) "
                + "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> "
                + "/FontDescriptor \(descriptor) 0 R /DW 0 /W [\(widths)]"
                + (font.hasCFFOutlines ? "" : " /CIDToGIDMap /Identity") + " >>",
        )
        let box = font.bbox
        // Symbolic or nonsymbolic, and italic when the face leans.
        let flags = (symbolic ? 4 : 32) | (font.italicAngle != 0 ? 64 : 0)
        writer.object(
            descriptor,
            "<< /Type /FontDescriptor /FontName /\(name) /Flags \(flags) "
                + "/FontBBox [\(font.thousandths(box.minX)) \(font.thousandths(box.minY)) "
                + "\(font.thousandths(box.maxX)) \(font.thousandths(box.maxY))] "
                + "/ItalicAngle \(PDFPageWalker.number(font.italicAngle)) /Ascent \(font.thousandths(font.ascender)) "
                + "/Descent \(font.thousandths(font.descender)) /CapHeight \(font.thousandths(font.ascender)) "
                + "/StemV 80 /\(font.hasCFFOutlines ? "FontFile3" : "FontFile2") \(program) 0 R >>",
        )
        if font.hasCFFOutlines {
            try writer.stream(program, dictionary: "/Subtype /OpenType", data: font.data, compress: true)
        } else {
            // Only the glyphs drawn; `Length1` is the uncompressed length a TrueType program's stream must state.
            let subset = try TrueTypeSubset.subset(font, keeping: Set(glyphs))
            try writer.stream(program, dictionary: "/Length1 \(subset.count)", data: subset, compress: true)
        }
        try writer.stream(toUnicode, dictionary: "", data: Data(toUnicodeMap(glyphs).utf8), compress: true)
        return type0
    }

    /// Six uppercase letters from the glyphs a subset keeps (FNV-1a over their ids): the same subset is always named
    /// the same, and two different ones almost never are.
    static func subsetTag(_ glyphs: [Int]) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for glyph in glyphs {
            hash = (hash ^ UInt64(glyph)) &* 0x0100_0000_01B3
        }
        var tag = ""
        for _ in 0 ..< 6 {
            tag.append(Character(Unicode.Scalar(UInt8(65 + hash % 26))))
            hash /= 26
        }
        return tag
    }

    /// The `ToUnicode` CMap (ISO 32000-1 §9.10.3): two-byte glyph ids to UTF-16BE, a hundred `bfchar` entries a block
    /// as the format limits them.
    private func toUnicodeMap(_ glyphs: [Int]) -> String {
        var map = """
        /CIDInit /ProcSet findresource begin
        12 dict begin
        begincmap
        /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def
        /CMapName /Adobe-Identity-UCS def
        /CMapType 2 def
        1 begincodespacerange
        <0000> <FFFF>
        endcodespacerange

        """
        let mapped = glyphs.compactMap { glyph -> (Int, [UInt32])? in
            guard let scalars = used[glyph], !scalars.isEmpty else { return nil }
            return (glyph, scalars)
        }
        for start in stride(from: 0, to: mapped.count, by: 100) {
            let block = mapped[start ..< min(start + 100, mapped.count)]
            map += "\(block.count) beginbfchar\n"
            for (glyph, scalars) in block {
                let units = scalars.compactMap(Unicode.Scalar.init).flatMap { Array(String($0).utf16) }
                map += "<\(PDFString.hex4(UInt16(glyph)))> <\(units.map(PDFString.hex4).joined())>\n"
            }
            map += "endbfchar\n"
        }
        map += """
        endcmap
        CMapName currentdict /CMap defineresource pop
        end
        end

        """
        return map
    }
}
