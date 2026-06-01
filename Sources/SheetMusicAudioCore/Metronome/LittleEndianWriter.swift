import Foundation

/// Minimal little-endian byte buffer for building RIFF / SF2 files.
///
/// The MIDI `BinaryEncoder` in `SheetMusicMIDI` is big-endian (SMF byte
/// order), so it is intentionally not reused here — RIFF / SF2 is
/// little-endian.
struct LittleEndianWriter {
    private(set) var data = Data()

    mutating func appendUInt8(_ v: UInt8) {
        data.append(v)
    }

    mutating func appendUInt16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }

    mutating func appendInt16(_ v: Int16) {
        appendUInt16(UInt16(bitPattern: v))
    }

    mutating func appendUInt32(_ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }

    mutating func append(_ other: Data) {
        data.append(other)
    }

    /// Append a 4-byte ASCII chunk tag (e.g. "RIFF", "LIST", "smpl").
    mutating func appendTag(_ tag: String) {
        let bytes = Array(tag.utf8)
        precondition(bytes.count == 4, "RIFF tag must be 4 ASCII bytes: \(tag)")
        data.append(contentsOf: bytes)
    }

    /// Append a fixed-length field, zero-padded (or truncated) to `length`.
    /// Used for SF2's fixed 20-byte name fields.
    mutating func appendFixedString(_ s: String, length: Int) {
        var bytes = Array(s.utf8.prefix(length))
        bytes.append(contentsOf: repeatElement(UInt8(0), count: length - bytes.count))
        data.append(contentsOf: bytes)
    }
}
