import Foundation

/// A TrueType-flavored OpenType file built in memory, with the tables `OpenTypeFont` reads and `TrueTypeSubset` cuts —
/// the shape of the platform UI face (Segoe UI) or a CJK fallback a Windows host hands the writer, without shipping
/// one. The outlines are placeholders: each glyph a one-point contour of its own bytes, so a test can tell which
/// glyph's bytes a subset kept.
enum SyntheticTrueType {
    /// `scalars` map to glyphs 1, 2, … in sorted order, each `advance` font units wide on a 1000-unit em; glyph 0 is
    /// `.notdef`. Each `composites` entry adds a glyph after them built from the given glyph ids, mapped from its
    /// scalar.
    static func make(
        postScriptName: String = "Synthetic-Semibold", fsType: UInt16 = 0x0008, italicAngle: Int16 = 0,
        scalars: [UInt16] = Array("ALabelPiano 12".utf16), composites: [(scalar: UInt16, components: [UInt16])] = [],
        advance: UInt16 = 600,
    ) -> Data {
        let simple = Array(Set(scalars)).sorted()
        let mapped = simple + composites.map(\.scalar)
        let glyphCount = UInt16(mapped.count + 1)
        var os2 = [UInt8](repeating: 0, count: 78)
        os2.put16(fsType, at: 8)
        var post = [UInt8](repeating: 0, count: 32)
        post.put32(0x0003_0000, at: 0)
        post.put16(UInt16(bitPattern: italicAngle), at: 4)
        var hmtx: [UInt8] = []
        for _ in 0 ..< glyphCount {
            hmtx.append16(advance)
            hmtx.append16(0)
        }
        let outlines = glyf(simpleCount: simple.count, composites: composites.map(\.components))
        return Data(file([
            ("head", head()), ("hhea", hhea(glyphCount: glyphCount)), ("maxp", maxp(glyphCount: glyphCount)),
            ("hmtx", hmtx), ("cmap", cmap(mapped)), ("OS/2", os2), ("post", post), ("name", name(postScriptName)),
            ("glyf", outlines.glyf), ("loca", outlines.loca),
        ]))
    }

    /// `fonts` as one collection (`ttcf`), each table copied after the header with its offset rewritten.
    static func collection(_ fonts: [Data]) -> Data {
        var header: [UInt8] = Array("ttcf".utf8)
        header.append32(0x0001_0000)
        header.append32(UInt32(fonts.count))
        var offset = header.count + 4 * fonts.count
        var bodies: [UInt8] = []
        for font in fonts {
            header.append32(UInt32(offset))
            var bytes = [UInt8](font)
            let tableCount = Int(bytes[4]) << 8 | Int(bytes[5])
            for index in 0 ..< tableCount {
                let record = 12 + 16 * index + 8
                let old = Int(bytes[record]) << 24 | Int(bytes[record + 1]) << 16 | Int(bytes[record + 2]) << 8
                    | Int(bytes[record + 3])
                bytes.put32(UInt32(old + offset), at: record)
            }
            bodies += bytes
            offset += bytes.count
        }
        return Data(header + bodies)
    }

    /// Glyph `n`'s placeholder outline: a one-contour glyph whose single point is (n, n).
    static func simpleOutline(_ glyph: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for value in [1, 0, 0, 0, 0, 0, 0] as [UInt16] {
            bytes.append16(value)
        }
        bytes.append(0x01) // on curve, coordinates as words
        bytes.append16(UInt16(glyph))
        bytes.append16(UInt16(glyph))
        return bytes
    }

    private static func glyf(simpleCount: Int, composites: [[UInt16]]) -> (glyf: [UInt8], loca: [UInt8]) {
        var glyf: [UInt8] = []
        var loca: [UInt8] = []
        func add(_ outline: [UInt8]) {
            loca.append32(UInt32(glyf.count))
            glyf += outline
            while glyf.count % 4 != 0 {
                glyf.append(0)
            }
        }
        add(simpleOutline(0))
        for glyph in 1 ... max(simpleCount, 1) where glyph <= simpleCount {
            add(simpleOutline(glyph))
        }
        for components in composites {
            var outline: [UInt8] = []
            for value in [UInt16(bitPattern: -1), 0, 0, 0, 0] {
                outline.append16(value)
            }
            for (index, component) in components.enumerated() {
                outline.append16(index < components.count - 1 ? 0x0020 : 0) // MORE_COMPONENTS; byte arguments
                outline.append16(component)
                outline.append16(0)
            }
            add(outline)
        }
        loca.append32(UInt32(glyf.count))
        return (glyf, loca)
    }

    private static func head() -> [UInt8] {
        var head = [UInt8](repeating: 0, count: 54)
        head.put32(0x0001_0000, at: 0)
        head.put16(1000, at: 18) // unitsPerEm
        head.put16(UInt16(bitPattern: -100), at: 38) // yMin
        head.put16(900, at: 40) // xMax
        head.put16(800, at: 42) // yMax
        head.put16(1, at: 50) // indexToLocFormat: long
        return head
    }

    private static func hhea(glyphCount: UInt16) -> [UInt8] {
        var hhea = [UInt8](repeating: 0, count: 36)
        hhea.put32(0x0001_0000, at: 0)
        hhea.put16(800, at: 4)
        hhea.put16(UInt16(bitPattern: -200), at: 6)
        hhea.put16(glyphCount, at: 34)
        return hhea
    }

    private static func maxp(glyphCount: UInt16) -> [UInt8] {
        var maxp = [UInt8](repeating: 0, count: 6)
        maxp.put32(0x0000_5000, at: 0)
        maxp.put16(glyphCount, at: 4)
        return maxp
    }

    /// One Windows Unicode subtable in format 4: a segment per character, then the closing 0xFFFF segment.
    private static func cmap(_ scalars: [UInt16]) -> [UInt8] {
        let segments = scalars.count + 1
        var table: [UInt8] = []
        for value in [0, 1, 3, 1] as [UInt16] {
            table.append16(value)
        }
        table.append32(12)
        for value in [4, UInt16(16 + 8 * segments), 0, UInt16(2 * segments), 0, 0, 0] as [UInt16] {
            table.append16(value)
        }
        let ends = scalars + [0xFFFF]
        let deltas = scalars.enumerated().map { UInt16($0.offset + 1) &- $0.element } + [1]
        for value in ends + [0] + ends + deltas + Array(repeating: 0, count: segments) {
            table.append16(value)
        }
        return table
    }

    /// One Windows-platform record for name id 6, UTF-16BE.
    private static func name(_ postScriptName: String) -> [UInt8] {
        let utf16 = postScriptName.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        var table: [UInt8] = []
        for value in [0, 1, 6 + 12, 3, 1, 0x0409, 6, UInt16(utf16.count), 0] as [UInt16] {
            table.append16(value)
        }
        return table + utf16
    }

    /// The table directory and the tables, each at a four-byte boundary.
    private static func file(_ tables: [(tag: String, data: [UInt8])]) -> [UInt8] {
        var file: [UInt8] = []
        file.append32(0x0001_0000)
        for value in [UInt16(tables.count), 0, 0, 0] {
            file.append16(value)
        }
        var offset = 12 + 16 * tables.count
        var bodies: [UInt8] = []
        for table in tables {
            file.append(contentsOf: Array(table.tag.utf8))
            file.append32(0) // checksum: OpenTypeFont does not read it
            file.append32(UInt32(offset))
            file.append32(UInt32(table.data.count))
            var padded = table.data
            while padded.count % 4 != 0 {
                padded.append(0)
            }
            bodies += padded
            offset += padded.count
        }
        return file + bodies
    }
}

/// An `sfnt`'s tables by tag, read back from its directory: what a subset kept, for the tests to look at.
enum SFNTTables {
    static func read(_ data: Data) -> [String: [UInt8]] {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        var tables: [String: [UInt8]] = [:]
        for index in 0 ..< (Int(bytes[4]) << 8 | Int(bytes[5])) {
            let record = 12 + 16 * index
            let tag = String(bytes[record ..< record + 4].map { Character(Unicode.Scalar($0)) })
            tables[tag] = Array(bytes[u32(record + 8) ..< u32(record + 8) + u32(record + 12)])
        }
        return tables
    }

    /// Glyph `glyph`'s bytes through a long-format `loca`.
    static func glyph(_ glyph: Int, in tables: [String: [UInt8]]) -> [UInt8] {
        guard let loca = tables["loca"], let glyf = tables["glyf"] else { return [] }
        func u32(_ at: Int) -> Int {
            Int(loca[at]) << 24 | Int(loca[at + 1]) << 16 | Int(loca[at + 2]) << 8 | Int(loca[at + 3])
        }
        return Array(glyf[u32(4 * glyph) ..< u32(4 * glyph + 4)])
    }
}

extension [UInt8] {
    fileprivate mutating func append16(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    fileprivate mutating func append32(_ value: UInt32) {
        append16(UInt16(value >> 16))
        append16(UInt16(value & 0xFFFF))
    }

    fileprivate mutating func put16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value >> 8)
        self[offset + 1] = UInt8(value & 0xFF)
    }

    fileprivate mutating func put32(_ value: UInt32, at offset: Int) {
        put16(UInt16(value >> 16), at: offset)
        put16(UInt16(value & 0xFFFF), at: offset + 2)
    }
}
