import SheetMusicFoundation

/// The parts of an OpenType font a PDF needs to embed it whole and place its glyphs: the em, the bounding box, the
/// vertical metrics, each glyph's advance, and the Unicode `cmap` — read from the table directory and `head`, `hhea`,
/// `maxp`, `hmtx` and `cmap` (format 12 when the font has one, which Bravura's private-use repertoire needs, else
/// format 4) — and, from the optional `OS/2`, `post` and `name`, whether its license lets it be embedded, its slant and
/// its PostScript name. Every read is bounds-checked: a font that does not hold together throws `Malformed` rather
/// than trapping.
struct OpenTypeFont {
    struct Malformed: Error, Equatable {
        let reason: String
    }

    let data: Data
    let unitsPerEm: Int
    /// `head`'s xMin, yMin, xMax, yMax in font units.
    let bbox: (minX: Int, minY: Int, maxX: Int, maxY: Int)
    let ascender: Int
    let descender: Int
    /// Whether the outlines are CFF (`OTTO`) rather than TrueType: which CIDFont subtype a PDF embeds it as.
    let hasCFFOutlines: Bool
    /// `OS/2`'s embedding permissions (`fsType`); 0, installable, for a font without the table.
    let fsType: Int
    /// `post`'s italic angle in degrees, counter-clockwise from vertical: negative for a face that leans right.
    let italicAngle: Double
    /// `name` id 6, which a PDF names the font by; nil when the font has none it can read.
    let postScriptName: String?
    private let advances: [Int]
    private let cmap: [UInt32: Int]

    init(_ data: Data) throws {
        let read = BigEndianReader(bytes: [UInt8](data))
        let version = try read.u32(0)
        guard version == 0x0001_0000 || version == 0x4F54_544F else { // TrueType 1.0 or "OTTO"
            throw Malformed(reason: "not an OpenType font")
        }
        var tables: [String: Int] = [:]
        for index in try 0 ..< (read.u16(4)) {
            let record = 12 + 16 * index
            let tag = try String(read.slice(record, 4).map { Character(Unicode.Scalar($0)) })
            tables[tag] = try read.u32(record + 8)
        }
        func table(_ tag: String) throws -> Int {
            guard let offset = tables[tag] else { throw Malformed(reason: "no \(tag) table") }
            return offset
        }
        let head = try table("head")
        let hhea = try table("hhea")
        unitsPerEm = try read.u16(head + 18)
        guard unitsPerEm > 0 else { throw Malformed(reason: "unitsPerEm is 0") }
        bbox = try (read.i16(head + 36), read.i16(head + 38), read.i16(head + 40), read.i16(head + 42))
        ascender = try read.i16(hhea + 4)
        descender = try read.i16(hhea + 6)
        let metricCount = try read.u16(hhea + 34)
        let glyphCount = try read.u16(table("maxp") + 4)
        guard metricCount > 0, metricCount <= glyphCount else { throw Malformed(reason: "hhea metric count") }
        let hmtx = try table("hmtx")
        // Glyphs past the last full metric repeat its advance.
        advances = try (0 ..< glyphCount).map { try read.u16(hmtx + 4 * min($0, metricCount - 1)) }
        cmap = try Self.unicodeMap(read, table: table("cmap"))
        hasCFFOutlines = version == 0x4F54_544F
        fsType = try tables["OS/2"].map { try read.u16($0 + 8) } ?? 0
        italicAngle = try tables["post"].map { try Double(read.i16($0 + 4)) + Double(read.u16($0 + 6)) / 65536 } ?? 0
        postScriptName = try tables["name"].flatMap { try Self.postScriptName(read, table: $0) }
        self.data = data
    }

    /// How many glyphs the font has; ids run from 0 (`.notdef`) below it.
    var glyphCount: Int {
        advances.count
    }

    /// Whether the license lets a document carry the font (`fsType`): not when it is restricted-license only (bit 1
    /// with neither the preview-and-print nor the editable bit, which would lift it) or bitmap-only (bit 9), since a
    /// PDF embeds the outlines.
    var isEmbeddable: Bool {
        fsType & 0x000E != 0x0002 && fsType & 0x0200 == 0
    }

    /// The glyph `scalar` maps to; 0 (`.notdef`) when the font has none.
    func glyph(for scalar: UInt32) -> Int {
        cmap[scalar] ?? 0
    }

    /// The glyph's advance in font units; 0 for a glyph the font does not have.
    func advance(of glyph: Int) -> Int {
        advances.indices.contains(glyph) ? advances[glyph] : 0
    }

    /// The glyph's advance in a PDF's text space, thousandths of an em.
    func width(of glyph: Int) -> Int {
        Int((Double(advance(of: glyph)) * 1000 / Double(unitsPerEm)).rounded())
    }

    /// A length in font units in thousandths of an em.
    func thousandths(_ units: Int) -> Int {
        Int((Double(units) * 1000 / Double(unitsPerEm)).rounded())
    }

    // MARK: - name

    /// Name id 6 from a Windows (UTF-16BE) or Unicode record, else a Macintosh (Roman) one, kept only if it is
    /// printable ASCII without a PDF delimiter — what a PostScript name is, and what a PDF name carries unescaped.
    private static func postScriptName(_ read: BigEndianReader, table: Int) throws -> String? {
        let storage = try table + read.u16(table + 4)
        var found: [Int: String] = [:]
        for index in try 0 ..< read.u16(table + 2) {
            let record = table + 6 + 12 * index
            let platform = try read.u16(record)
            guard try read.u16(record + 6) == 6, found[platform] == nil else { continue }
            let bytes = try read.slice(storage + read.u16(record + 10), read.u16(record + 8))
            // UTF-16BE keeps only units whose high byte is zero; anything else fails the ASCII check below.
            let pairs = stride(from: bytes.startIndex, to: bytes.endIndex - 1, by: 2)
            let scalars: [UInt8] = platform == 1 ? Array(bytes) : pairs.map { bytes[$0] == 0 ? bytes[$0 + 1] : 0 }
            let delimiters = Array("()<>[]{}/%#".utf8)
            guard !scalars.isEmpty, scalars.allSatisfy({ (0x21 ... 0x7E).contains($0) && !delimiters.contains($0) })
            else { continue }
            found[platform] = String(scalars.map { Character(Unicode.Scalar($0)) })
        }
        return found[3] ?? found[0] ?? found[1]
    }

    // MARK: - cmap

    /// The Unicode subtable: format 12 (the full repertoire) when the font has one, else format 4.
    private static func unicodeMap(_ read: BigEndianReader, table: Int) throws -> [UInt32: Int] {
        var format4: Int?
        var format12: Int?
        for index in try 0 ..< (read.u16(table + 2)) {
            let record = table + 4 + 8 * index
            let platform = try read.u16(record)
            let encoding = try read.u16(record + 2)
            let offset = try table + read.u32(record + 4)
            guard platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10)) else { continue }
            switch try read.u16(offset) {
            case 12: format12 = format12 ?? offset
            case 4: format4 = format4 ?? offset
            default: break
            }
        }
        if let format12 { return try Self.format12(read, at: format12) }
        if let format4 { return try Self.format4(read, at: format4) }
        throw Malformed(reason: "no Unicode cmap")
    }

    /// Sequential groups: start, end, first glyph.
    private static func format12(_ read: BigEndianReader, at offset: Int) throws -> [UInt32: Int] {
        var map: [UInt32: Int] = [:]
        let groups = try read.u32(offset + 12)
        guard offset + 16 + 12 * groups <= read.bytes.count else { throw Malformed(reason: "cmap 12 groups") }
        for group in 0 ..< groups {
            let record = offset + 16 + 12 * group
            let start = try read.u32(record)
            let end = try read.u32(record + 4)
            let glyph = try read.u32(record + 8)
            // Unicode ends at U+10FFFF; a group past it, or running backwards, is not a font's.
            guard start <= end, end <= 0x10FFFF else { throw Malformed(reason: "cmap 12 group \(group)") }
            for code in start ... end {
                map[UInt32(code)] = glyph + code - start
            }
        }
        return map
    }

    /// Segments of the Basic Multilingual Plane, by delta or through the glyph id array.
    private static func format4(_ read: BigEndianReader, at offset: Int) throws -> [UInt32: Int] {
        var map: [UInt32: Int] = [:]
        let segments = try read.u16(offset + 6) / 2
        let ends = offset + 14
        let starts = ends + 2 * segments + 2
        let deltas = starts + 2 * segments
        let rangeOffsets = deltas + 2 * segments
        for segment in 0 ..< segments {
            let start = try read.u16(starts + 2 * segment)
            let end = try read.u16(ends + 2 * segment)
            let delta = try read.i16(deltas + 2 * segment)
            let rangeOffset = try read.u16(rangeOffsets + 2 * segment)
            guard start != 0xFFFF, start <= end else { continue }
            for code in start ... end {
                if rangeOffset == 0 {
                    map[UInt32(code)] = (code + delta) & 0xFFFF
                } else {
                    let raw = try read.u16(rangeOffsets + 2 * segment + rangeOffset + 2 * (code - start))
                    if raw != 0 { map[UInt32(code)] = (raw + delta) & 0xFFFF }
                }
            }
        }
        return map
    }
}

/// Big-endian reads at byte offsets, as every OpenType table is laid out; out of bounds throws.
struct BigEndianReader {
    let bytes: [UInt8]

    func u16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { throw OpenTypeFont.Malformed(reason: "read past the end") }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    func i16(_ offset: Int) throws -> Int {
        try Int(Int16(bitPattern: UInt16(u16(offset))))
    }

    func u32(_ offset: Int) throws -> Int {
        try u16(offset) << 16 | u16(offset + 2)
    }

    func slice(_ offset: Int, _ count: Int) throws -> ArraySlice<UInt8> {
        guard offset >= 0, offset + count <= bytes.count else {
            throw OpenTypeFont.Malformed(reason: "read past the end")
        }
        return bytes[offset ..< offset + count]
    }
}
