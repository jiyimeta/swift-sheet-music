import Foundation

/// A TrueType-flavored OpenType file built in memory, with just the tables `OpenTypeFont` reads — the shape of the
/// platform UI face (Segoe UI) a Windows host hands the writer, without shipping one. No outlines: what the tests check
/// is how the file is read and embedded, not how it draws.
enum SyntheticTrueType {
    /// `scalars` map to glyphs 1, 2, … in sorted order, each `advance` font units wide on a 1000-unit em; glyph 0 is
    /// `.notdef`.
    static func make(
        postScriptName: String = "Synthetic-Semibold", fsType: UInt16 = 0x0008, italicAngle: Int16 = 0,
        scalars: [UInt16] = Array("ALabelPiano 12".utf16), advance: UInt16 = 600,
    ) -> Data {
        let unique = Array(Set(scalars)).sorted()
        let glyphCount = UInt16(unique.count + 1)
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
        return file([
            ("head", head()), ("hhea", hhea(glyphCount: glyphCount)), ("maxp", maxp(glyphCount: glyphCount)),
            ("hmtx", hmtx), ("cmap", cmap(unique)), ("OS/2", os2), ("post", post), ("name", name(postScriptName)),
        ])
    }

    private static func head() -> [UInt8] {
        var head = [UInt8](repeating: 0, count: 54)
        head.put32(0x0001_0000, at: 0)
        head.put16(1000, at: 18) // unitsPerEm
        head.put16(UInt16(bitPattern: -100), at: 38) // yMin
        head.put16(900, at: 40) // xMax
        head.put16(800, at: 42) // yMax
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
    private static func file(_ tables: [(tag: String, data: [UInt8])]) -> Data {
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
        return Data(file + bodies)
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
