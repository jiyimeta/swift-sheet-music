import Foundation
@testable import SheetMusicCore
import SheetMusicEditWire
import Testing

@Suite("Reference codecs")
struct ReferenceCodecTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    @Test("each reference round-trips")
    func roundTrips() throws {
        let measure = MeasureRef(measureIndex: 7)
        let part = PartRef(partIndex: 2)
        let voice = VoiceRef(staff: Self.staff, measureIndex: 3, voiceIndex: 1)
        let range = VoiceElementRange(
            start: VoiceElementID(staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2),
            end: VoiceElementID(staff: Self.staff, measureIndex: 4, voiceIndex: 1, elementIndex: 0),
        )
        #expect(try ReferenceCodecs.decode(ReferenceCodecs.encode(measure)) == measure)
        #expect(try ReferenceCodecs.decode(ReferenceCodecs.encode(part)) == part)
        #expect(try ReferenceCodecs.decode(ReferenceCodecs.encode(voice)) == voice)
        #expect(try ReferenceCodecs.decode(ReferenceCodecs.encode(range)) == range)
    }

    /// A single-integer reference is a NESTED struct on the wire — length prefix, tag 1, zig-zag value — never a
    /// bare varint. This is the SP0 seam: a nested struct can grow an optional field byte-free, a scalar cannot.
    @Test("a one-integer reference is still a nested struct")
    func singleIntegerIsNested() {
        let bytes = [UInt8](ReferenceCodecs.encode(MeasureRef(measureIndex: 3)))
        #expect(bytes == [0x02, 0x08, 0x06], "varint(len=2), tag 1 varint (1<<3|0), zig-zag(3) = 6")
    }
}
