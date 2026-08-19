import SheetMusicCore
import SheetMusicFoundation

/// SMF variable-length quantity: 7-bit groups, big-endian, MSB set on continuation bytes.
enum VariableLengthQuantity {
    static func encode(_ value: Int) -> Data {
        precondition(value >= 0 && value <= 0x0FFF_FFFF, "VLQ supports 0..0x0FFFFFFF")
        if value == 0 { return Data([0x00]) }
        var bytes: [UInt8] = []
        var v = value
        bytes.append(UInt8(v & 0x7F))
        v >>= 7
        while v > 0 {
            bytes.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        return Data(bytes.reversed())
    }
}
