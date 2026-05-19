import Foundation
import SheetMusicCore

/// Instrument/channel parameters for one staff, passed across the JNI
/// boundary so Kotlin can configure the Android audio engine.
///
/// `partAddressHash` is a deterministic Int64 fingerprint of the owning
/// `StaffAddress`. The Kotlin side treats it as opaque; it is used only
/// for change-detection. The formula is:
/// ```
///   Int64(partIndex) * 1_000 + Int64(staffIndexInPart)
/// ```
/// This is sufficient for the v0 scope (≤ 1000 staves per part, which
/// covers all practical scores).
public struct StaffParams: Equatable {
    public let staffIndex: Int
    public let bankLSB: UInt8
    public let program: UInt8
    public let isDrums: Bool
    /// Opaque Int64 fingerprint of the owning `StaffAddress`.
    /// Computed as `Int64(partIndex) * 1_000 + Int64(staffIndexInPart)`.
    public let partAddressHash: Int64

    public init(
        staffIndex: Int,
        bankLSB: UInt8,
        program: UInt8,
        isDrums: Bool,
        partAddressHash: Int64,
    ) {
        self.staffIndex = staffIndex
        self.bankLSB = bankLSB
        self.program = program
        self.isDrums = isDrums
        self.partAddressHash = partAddressHash
    }

    /// Convenience factory that derives `partAddressHash` from a
    /// `StaffAddress` automatically.
    public init(
        staffIndex: Int,
        bankLSB: UInt8,
        program: UInt8,
        isDrums: Bool,
        staffAddress: StaffAddress,
    ) {
        self.init(
            staffIndex: staffIndex,
            bankLSB: bankLSB,
            program: program,
            isDrums: isDrums,
            partAddressHash: Int64(staffAddress.partIndex) * 1000
                + Int64(staffAddress.staffIndexInPart),
        )
    }
}

/// Codec for `[StaffParams]` — a top-level versioned array blob.
///
/// Wire layout:
/// ```
/// StaffParamsArray
///   u16 version (= 1)
///   i32 count
///   count × { i32 staffIndex; u8 bankLSB; u8 program; u8 isDrums; u8 _reserved; i64 partAddressHash }
///            16 bytes per entry
/// ```
public enum StaffParamsCodec {
    static let version: UInt16 = 1

    public static func encodeArray(_ params: [StaffParams]) -> Data {
        var w = AudioBinaryWriter()
        w.append(version)
        w.append(Int32(params.count))
        for p in params {
            w.append(Int32(p.staffIndex))
            w.append(p.bankLSB)
            w.append(p.program)
            w.append(p.isDrums ? UInt8(1) : UInt8(0))
            w.append(UInt8(0)) // _reserved
            w.append(p.partAddressHash)
        }
        return w.data
    }

    public static func decodeArray(_ data: Data) throws -> [StaffParams] {
        var r = AudioBinaryReader(data)
        try r.assertVersion(version)
        let count = try Int(r.readInt32())
        var result: [StaffParams] = []
        result.reserveCapacity(count)
        for _ in 0 ..< count {
            let staffIndex = try Int(r.readInt32())
            let bankLSB = try r.readUInt8()
            let program = try r.readUInt8()
            let isDrumsFlag = try r.readUInt8()
            _ = try r.readUInt8() // _reserved
            let partAddressHash = try r.readInt64()
            result.append(StaffParams(
                staffIndex: staffIndex,
                bankLSB: bankLSB,
                program: program,
                isDrums: isDrumsFlag != 0,
                partAddressHash: partAddressHash,
            ))
        }
        return result
    }
}
