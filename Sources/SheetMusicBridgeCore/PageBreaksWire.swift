import Foundation

/// Wire format for `nativePageBreaks`: `i32 count` (big-endian) then `count × f64`
/// (big-endian IEEE 754), each value being a document-Y offset in millimetres.
/// The sequence is `[0, top1, …, contentBottom]` — one entry per page boundary
/// plus the content bottom, so `count == pageCount + 1`.
package enum PageBreaksWire {
    package static func encode(_ offsetsMm: [Double]) -> Data {
        var data = Data()
        var count = UInt32(offsetsMm.count).bigEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for value in offsetsMm {
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}
