import SheetMusicFoundation

/// The reader half of `DrawProgramFlat`. Split from the writer so neither file
/// carries both directions of the format at once; the layout they share is
/// documented on the enum itself.
///
/// The decoder exists mainly so the encoder can be tested — the browser reads
/// these bytes with its own `DataView`-based reader in
/// `Web/sheet-music-web/src/draw-program.ts`. A round trip here and a fixture
/// shared with that reader are what keep the two in agreement.
extension DrawProgramFlat {
    public static func decode(_ data: Data) throws -> [EncodablePage] {
        var cursor = Cursor(data: data)
        let magicValue = try cursor.readU32()
        guard magicValue == magic else { throw DecodeError.badMagic(magicValue) }
        let versionValue = try cursor.readU32()
        guard versionValue == version else { throw DecodeError.unsupportedVersion(versionValue) }
        let pageCount = try cursor.readI32()
        let strings: [String] = try cursor.readTable { bytes in
            guard let s = String(data: bytes, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
            return s
        }
        let blobs: [Data] = try cursor.readTable { $0 }

        var pages: [EncodablePage] = []
        pages.reserveCapacity(Int(max(0, pageCount)))
        for _ in 0 ..< max(0, pageCount) {
            let widthMM = try cursor.readF64()
            let heightMM = try cursor.readF64()
            let commandCount = try cursor.readI32()
            var commands: [DrawCommand] = []
            commands.reserveCapacity(Int(max(0, commandCount)))
            for _ in 0 ..< max(0, commandCount) {
                try commands.append(readCommand(&cursor, strings: strings, blobs: blobs))
            }
            pages.append(EncodablePage(widthMM: widthMM, heightMM: heightMM, commands: commands))
        }
        return pages
    }

    private static func readCommand(_ cursor: inout Cursor, strings: [String], blobs: [Data]) throws -> DrawCommand {
        let record = try Record(&cursor)
        let slots = record.slots
        let integer = record.integer
        switch record.opcode {
        case 0: return .moveTo(x: slots[0], y: slots[1])
        case 1: return .lineTo(x: slots[0], y: slots[1])
        case 2: return .stroke(width: slots[0])
        case 3: return .fillRect(x: slots[0], y: slots[1], w: slots[2], h: slots[3])
        case 4: return try .glyph(
                codepoint: integer, x: slots[0], y: slots[1], size: slots[2], fontId: record.fontID(),
            )
        case 5: return try .text(
                text: record.string(in: strings), x: slots[0], y: slots[1], size: slots[2], fontId: record.fontID(),
            )
        case 6: return .setColor(argb: integer)
        case 7: return .cubicTo(
                cx1: slots[0], cy1: slots[1], cx2: slots[2], cy2: slots[3],
                x: slots[4], y: slots[5],
            )
        case 8: return try .stretchedGlyph(
                codepoint: integer, rightEdgeX: slots[0], topY: slots[1], bottomY: slots[2],
                fontSize: slots[3], xScale: slots[4], fontId: record.fontID(),
            )
        case 9: return .setRotation(radians: slots[0], pivotX: slots[1], pivotY: slots[2])
        case 10: return .setDash(onMM: slots[0], offMM: slots[1])
        // Truncated rather than range-checked: the encoder writes a `UInt8` widened to the record's
        // `UInt32` integer slot, so the high bytes are always zero, and a stream where they are not
        // is one this decoder cannot interpret anyway. Refusing it would trade an unknown-but-inert
        // style bit for a whole page that does not draw.
        case 11: return .setTextStyle(flags: UInt8(truncatingIfNeeded: integer))
        case 12: return .fillPath
        case 13: return try .drawImage(
                data: record.blob(in: blobs), x: slots[0], y: slots[1], w: slots[2], h: slots[3],
            )
        default: throw DecodeError.unknownOpcode(record.opcode)
        }
    }

    /// One fixed-stride command record as read, before its opcode says what its fields mean.
    private struct Record {
        let opcode: Int32
        let slots: [Double]
        let stringIndex: Int32
        let integer: UInt32
        let fontIDRaw: Int32

        init(_ cursor: inout Cursor) throws {
            opcode = try cursor.readI32()
            var slots = [Double](repeating: 0, count: 6)
            for i in 0 ..< 6 {
                slots[i] = try cursor.readF64()
            }
            self.slots = slots
            stringIndex = try cursor.readI32()
            integer = try cursor.readU32()
            fontIDRaw = try cursor.readI32()
        }

        func string(in strings: [String]) throws -> String {
            guard stringIndex >= 0, Int(stringIndex) < strings.count else {
                throw DecodeError.badStringIndex(stringIndex)
            }
            return strings[Int(stringIndex)]
        }

        func fontID() throws -> DrawProgram.FontID {
            guard fontIDRaw >= 0, fontIDRaw <= Int32(UInt8.max),
                  let id = DrawProgram.FontID(rawValue: UInt8(fontIDRaw))
            else { throw DecodeError.badFontID(fontIDRaw) }
            return id
        }

        /// The picture bytes `integer` indexes in the blob table.
        func blob(in blobs: [Data]) throws -> Data {
            guard let index = Int(exactly: integer), index < blobs.count else {
                throw DecodeError.badBlobIndex(integer)
            }
            return blobs[index]
        }
    }

    /// Reads little-endian scalars off a `Data` that may be a slice, so
    /// `startIndex` is not assumed to be zero.
    private struct Cursor {
        let data: Data
        var offset = 0

        mutating func readBytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= data.count else { throw DecodeError.truncated }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: count)
            offset += count
            return Data(data[start ..< end])
        }

        mutating func readU32() throws -> UInt32 {
            let bytes = try readBytes(4)
            var v: UInt32 = 0
            for (i, byte) in bytes.enumerated() {
                v |= UInt32(byte) << (8 * i)
            }
            return v
        }

        mutating func readI32() throws -> Int32 {
            try Int32(bitPattern: readU32())
        }

        /// A side table: an `i32` count, then that many `i32 byteLen` + bytes entries, each made an `Element` by
        /// `make` (UTF-8 to a `String`, or a picture's bytes kept as they are).
        mutating func readTable<Element>(_ make: (Data) throws -> Element) throws -> [Element] {
            let count = try readI32()
            var table: [Element] = []
            table.reserveCapacity(Int(max(0, count)))
            for _ in 0 ..< max(0, count) {
                let byteLen = try readI32()
                let bytes = try readBytes(Int(byteLen))
                try table.append(make(bytes))
            }
            return table
        }

        mutating func readF64() throws -> Double {
            let bytes = try readBytes(8)
            var v: UInt64 = 0
            for (i, byte) in bytes.enumerated() {
                v |= UInt64(byte) << (8 * i)
            }
            return Double(bitPattern: v)
        }
    }
}
