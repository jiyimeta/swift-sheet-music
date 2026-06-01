import Foundation

/// A tiny RIFF reader used only by the SF2 builder tests. Locates LIST
/// sub-lists and their subchunks so tests can assert structure without a
/// full SF2 parser.
enum Sf2TestSupport {
    static func u16(_ d: Data, _ i: Int) -> UInt16 {
        let b = [UInt8](d)
        return UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    static func u32(_ d: Data, _ i: Int) -> UInt32 {
        let b = [UInt8](d)
        return UInt32(b[i]) | (UInt32(b[i + 1]) << 8)
            | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    static func tag(_ d: Data, _ i: Int) -> String {
        let b = [UInt8](d)
        return String(bytes: b[i ..< i + 4], encoding: .ascii) ?? ""
    }

    /// Find a LIST chunk whose form type matches `listType` (e.g. "pdta")
    /// and return the byte range of its inner payload (after the 4-byte
    /// form type). Searches only the top-level RIFF body.
    static func listPayloadRange(_ d: Data, listType: String) -> Range<Int>? {
        // Top-level: "RIFF" u32 size "sfbk" then LIST chunks.
        var i = 12
        let count = d.count
        while i + 8 <= count {
            let id = tag(d, i)
            let size = Int(u32(d, i + 4))
            let payloadStart = i + 8
            guard payloadStart + size <= count else { break }
            if id == "LIST", tag(d, payloadStart) == listType {
                return (payloadStart + 4) ..< (payloadStart + size)
            }
            i = payloadStart + size + (size & 1)
        }
        return nil
    }

    /// Within `range`, find a subchunk by id and return its payload range.
    static func subchunkPayloadRange(
        _ d: Data, in range: Range<Int>, id wanted: String,
    ) -> Range<Int>? {
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            let id = tag(d, i)
            let size = Int(u32(d, i + 4))
            let payloadStart = i + 8
            guard payloadStart + size <= range.upperBound else { break }
            if id == wanted {
                return payloadStart ..< (payloadStart + size)
            }
            i = payloadStart + size + (size & 1)
        }
        return nil
    }
}
