import Foundation
import SheetMusicCore

/// Codec for `[RehearsalMarkEntry]` — the rehearsal-mark list surfaced to the
/// Android Reader so it can render tappable rehearsal-mark chips/menu items that
/// seek the engine.
///
/// Wire layout (little-endian, hand-rolled to match the Kotlin `RehearsalMarkCodec`
/// decoder field-for-field — the same family of hand-written codecs as
/// `SMuFLMetricsTable` / `PageBreaksWire`, NOT a `@WireFormat` macro framing):
/// ```
/// i32 count
/// count × {
///   i32  textByteCount
///   text UTF-8 bytes        (textByteCount bytes)
///   f64  fraction           (IEEE 754 bit pattern)
///   i32  cursorByteCount
///   cursor bytes            (cursorByteCount bytes, ScoreCursorCodec.encode)
/// }
/// ```
///
/// The cursor sub-blob is opaque here: it is produced by `ScoreCursorCodec.encode`
/// and consumed by `ScoreCursorCodec.decode`, so its internal framing (Wirelet
/// `@WireFormatChoice`) is independent of this list framing.
enum RehearsalMarkCodec {
    static func encode(_ entries: [RehearsalMarkEntry]) -> Data {
        var data = Data()
        appendI32(Int32(entries.count), to: &data)
        for entry in entries {
            let textBytes = Data(entry.text.utf8)
            appendI32(Int32(textBytes.count), to: &data)
            data.append(textBytes)
            appendF64(entry.fraction, to: &data)
            let cursorBytes = ScoreCursorCodec.encode(entry.cursor)
            appendI32(Int32(cursorBytes.count), to: &data)
            data.append(cursorBytes)
        }
        return data
    }

    static func decode(_ data: Data) throws -> [RehearsalMarkEntry] {
        var cursor = 0
        let count = try readI32(data, &cursor)
        var entries: [RehearsalMarkEntry] = []
        entries.reserveCapacity(Int(max(0, count)))
        for _ in 0 ..< count {
            let textLen = try Int(readI32(data, &cursor))
            let text = try readUTF8(data, &cursor, length: textLen)
            let fraction = try readF64(data, &cursor)
            let cursorLen = try Int(readI32(data, &cursor))
            let cursorBytes = try readBytes(data, &cursor, length: cursorLen)
            let scoreCursor = try ScoreCursorCodec.decode(cursorBytes)
            entries.append(RehearsalMarkEntry(text: text, fraction: fraction, cursor: scoreCursor))
        }
        return entries
    }

    // MARK: - Encode helpers (little-endian)

    private static func appendI32(_ value: Int32, to data: inout Data) {
        var v = UInt32(bitPattern: value).littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendF64(_ value: Double, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    // MARK: - Decode helpers (little-endian)

    enum DecodeError: Error { case truncated, invalidUTF8 }

    private static func readI32(_ data: Data, _ cursor: inout Int) throws -> Int32 {
        guard cursor + 4 <= data.count else { throw DecodeError.truncated }
        let base = data.index(data.startIndex, offsetBy: cursor)
        var v: UInt32 = 0
        for i in 0 ..< 4 {
            v |= UInt32(data[data.index(base, offsetBy: i)]) << (8 * i)
        }
        cursor += 4
        return Int32(bitPattern: v)
    }

    private static func readF64(_ data: Data, _ cursor: inout Int) throws -> Double {
        guard cursor + 8 <= data.count else { throw DecodeError.truncated }
        let base = data.index(data.startIndex, offsetBy: cursor)
        var v: UInt64 = 0
        for i in 0 ..< 8 {
            v |= UInt64(data[data.index(base, offsetBy: i)]) << (8 * i)
        }
        cursor += 8
        return Double(bitPattern: v)
    }

    private static func readBytes(_ data: Data, _ cursor: inout Int, length: Int) throws -> Data {
        guard length >= 0, cursor + length <= data.count else { throw DecodeError.truncated }
        let base = data.index(data.startIndex, offsetBy: cursor)
        let end = data.index(base, offsetBy: length)
        let slice = Data(data[base ..< end])
        cursor += length
        return slice
    }

    private static func readUTF8(_ data: Data, _ cursor: inout Int, length: Int) throws -> String {
        let bytes = try readBytes(data, &cursor, length: length)
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
        return text
    }
}
