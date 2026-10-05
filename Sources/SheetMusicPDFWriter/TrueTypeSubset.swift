import SheetMusicFoundation

/// A TrueType-outline font cut down to the glyphs a document draws, as the standalone file a PDF embeds (`FontFile2`):
/// every other glyph's outline emptied, glyph ids unchanged — so the content stream's codes, the `W` widths and the
/// `ToUnicode` map stay what they were — and only the tables a reader rasterizes from. A collection's face comes out as
/// a font of its own.
///
/// The platform UI face is a megabyte a weight and a CJK fallback ten or more; a score's labels use a few dozen glyphs
/// of either. CFF outlines are not cut: that is a CFF compiler of its own, and the bundled Bravura and Edwin are
/// embedded whole.
enum TrueTypeSubset {
    /// The tables a PDF reader needs of a TrueType program (ISO 32000-1 §9.9: `head`, `hhea`, `hmtx`, `loca`, `maxp`,
    /// `glyf`, and `cvt `, `fpgm`, `prep` where the font has them), with `OS/2` and `gasp`, which a rasterizer reads
    /// when present. The rest — `cmap` (Identity CIDs address glyphs directly), `name`, `post`, the layout tables — is
    /// left out.
    static let keptTables = ["OS/2", "cvt ", "fpgm", "gasp", "glyf", "head", "hhea", "hmtx", "loca", "maxp", "prep"]

    /// `font` keeping the outlines of `glyphs`, of the glyphs their composites are built from, and of `.notdef`.
    /// Throws `OpenTypeFont.Malformed` for CFF outlines, or for a `loca` / `glyf` that does not hold together.
    static func subset(_ font: OpenTypeFont, keeping glyphs: Set<Int>) throws -> Data {
        guard !font.hasCFFOutlines else { throw OpenTypeFont.Malformed(reason: "CFF outlines are not subset") }
        guard let head = font.tables["head"], let loca = font.tables["loca"], let glyf = font.tables["glyf"],
              head.length >= 54
        else { throw OpenTypeFont.Malformed(reason: "no head, loca or glyf table") }
        let read = BigEndianReader(bytes: [UInt8](font.data))
        let outlines = try Outlines(
            read: read, loca: loca, glyf: glyf, longOffsets: read.i16(head.offset + 50) == 1,
            count: font.glyphCount,
        )
        var kept: Set = [0]
        var pending = [0] + glyphs.filter { (0 ..< font.glyphCount).contains($0) }
        while let glyph = pending.popLast() {
            guard kept.insert(glyph).inserted || glyph == 0 else { continue }
            pending += try outlines.components(of: glyph).filter { $0 < font.glyphCount && !kept.contains($0) }
        }

        var newGlyf: [UInt8] = []
        var newLoca: [UInt8] = []
        for glyph in 0 ..< font.glyphCount {
            newLoca.appendU32(newGlyf.count)
            guard kept.contains(glyph) else { continue }
            newGlyf += try read.slice(outlines.range(of: glyph))
            while newGlyf.count % 4 != 0 {
                newGlyf.append(0)
            }
        }
        newLoca.appendU32(newGlyf.count)

        var tables: [(tag: String, bytes: [UInt8])] = []
        for tag in keptTables {
            switch tag {
            case "glyf": tables.append((tag, newGlyf))
            case "loca": tables.append((tag, newLoca))
            case "head":
                var bytes = try Array(read.slice(head.offset, head.length))
                bytes.replaceSubrange(8 ..< 12, with: [0, 0, 0, 0]) // checkSumAdjustment, set once the file is whole
                bytes.replaceSubrange(50 ..< 52, with: [0, 1]) // indexToLocFormat: long offsets
                tables.append((tag, bytes))
            default:
                if let record = font.tables[tag] {
                    try tables.append((tag, Array(read.slice(record.offset, record.length))))
                }
            }
        }
        return Data(assemble(tables))
    }

    /// An `sfnt` of `tables`, sorted by tag as the format requires, each at a four-byte boundary with its checksum, and
    /// `head`'s `checkSumAdjustment` set over the whole.
    static func assemble(_ tables: [(tag: String, bytes: [UInt8])]) -> [UInt8] {
        let sorted = tables.sorted { $0.tag < $1.tag }
        var power = 1
        var log = 0
        while power * 2 <= sorted.count {
            power *= 2
            log += 1
        }
        var file: [UInt8] = []
        file.appendU32(0x0001_0000)
        for value in [sorted.count, 16 * power, log, 16 * (sorted.count - power)] {
            file.appendU16(value)
        }
        var offset = 12 + 16 * sorted.count
        var bodies: [UInt8] = []
        var headOffset: Int?
        for table in sorted {
            var padded = table.bytes
            while padded.count % 4 != 0 {
                padded.append(0)
            }
            file += Array(table.tag.utf8)
            file.appendU32(Int(checksum(padded)))
            file.appendU32(offset)
            file.appendU32(table.bytes.count)
            if table.tag == "head" { headOffset = offset }
            bodies += padded
            offset += padded.count
        }
        file += bodies
        if let headOffset {
            let adjustment = 0xB1B0_AFBA &- checksum(file)
            file.replaceSubrange(headOffset + 8 ..< headOffset + 12, with: [
                UInt8(adjustment >> 24), UInt8(adjustment >> 16 & 0xFF), UInt8(adjustment >> 8 & 0xFF),
                UInt8(adjustment & 0xFF),
            ])
        }
        return file
    }

    /// The big-endian 32-bit words of `bytes` summed, the last one padded with zeros.
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        while index < bytes.count {
            var word: UInt32 = 0
            for byte in 0 ..< 4 {
                word = word << 8 | UInt32(index + byte < bytes.count ? bytes[index + byte] : 0)
            }
            sum &+= word
            index += 4
        }
        return sum
    }
}

/// A font's `glyf` outlines through its `loca` offsets.
private struct Outlines {
    let read: BigEndianReader
    let loca: OpenTypeFont.TableRecord
    let glyf: OpenTypeFont.TableRecord
    let longOffsets: Bool
    let count: Int

    /// The glyph's bytes in the file; empty for a glyph with no outline (a space).
    func range(of glyph: Int) throws -> (offset: Int, count: Int) {
        let start: Int
        let end: Int
        if longOffsets {
            start = try read.u32(loca.offset + 4 * glyph)
            end = try read.u32(loca.offset + 4 * glyph + 4)
        } else {
            start = try read.u16(loca.offset + 2 * glyph) * 2
            end = try read.u16(loca.offset + 2 * glyph + 2) * 2
        }
        guard glyph < count, start <= end, end <= glyf.length else {
            throw OpenTypeFont.Malformed(reason: "loca entry \(glyph)")
        }
        return (glyf.offset + start, end - start)
    }

    /// The glyphs a composite glyph is built from; none for a simple one.
    func components(of glyph: Int) throws -> [Int] {
        let (start, length) = try range(of: glyph)
        guard length >= 10, try read.i16(start) < 0 else { return [] }
        var offset = start + 10
        var found: [Int] = []
        while true {
            let flags = try read.u16(offset)
            try found.append(read.u16(offset + 2))
            offset += 4 + (flags & 0x0001 != 0 ? 4 : 2) // ARG_1_AND_2_ARE_WORDS
            if flags & 0x0008 != 0 { // WE_HAVE_A_SCALE
                offset += 2
            } else if flags & 0x0040 != 0 { // WE_HAVE_AN_X_AND_Y_SCALE
                offset += 4
            } else if flags & 0x0080 != 0 { // WE_HAVE_A_TWO_BY_TWO
                offset += 8
            }
            guard flags & 0x0020 != 0, offset < start + length else { return found } // MORE_COMPONENTS
        }
    }
}

extension [UInt8] {
    fileprivate mutating func appendU16(_ value: Int) {
        append(contentsOf: [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    fileprivate mutating func appendU32(_ value: Int) {
        appendU16(value >> 16 & 0xFFFF)
        appendU16(value & 0xFFFF)
    }
}

extension BigEndianReader {
    fileprivate func slice(_ range: (offset: Int, count: Int)) throws -> ArraySlice<UInt8> {
        try slice(range.offset, range.count)
    }
}
