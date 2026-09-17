import Foundation
import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

struct ClefAnchorCodecTests {
    private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 1)

    // Byte-count, discriminator-offset, and byte-sequence assertions are
    // superseded by golden fixtures in the Kotlin codec tests. Only
    // round-trip and error-path tests are kept here.

    @Test
    func explicitRoundTrip() throws {
        let id = VoiceElementID(staff: addr, measureIndex: 3, voiceIndex: 1, elementIndex: 7)
        let original = ClefAnchor.explicit(id)
        let decoded = try ClefAnchorCodec.decode(ClefAnchorCodec.encode(original))
        #expect(decoded == original)
    }

    @Test
    func staffDefaultRoundTrip() throws {
        let original = ClefAnchor.staffDefault(addr)
        let decoded = try ClefAnchorCodec.decode(ClefAnchorCodec.encode(original))
        #expect(decoded == original)
    }

    @Test
    func restatementRoundTrip() throws {
        let original = ClefAnchor.restatement(staff: addr, measureIndex: 12)
        let decoded = try ClefAnchorCodec.decode(ClefAnchorCodec.encode(original))
        #expect(decoded == original)
    }

    /// The tag a restatement encodes with, pinned: the case indices are what a Kotlin host decodes by, and
    /// appending this one must not have moved the two that were already there.
    @Test
    func caseIndicesAreAppendOnly() throws {
        let anchors: [ClefAnchor] = [
            .explicit(VoiceElementID(staff: addr, measureIndex: 3, voiceIndex: 0, elementIndex: 1)),
            .staffDefault(addr),
            .restatement(staff: addr, measureIndex: 3),
        ]
        for (index, anchor) in anchors.enumerated() {
            var reader = WireFormatReader(data: ClefAnchorCodec.encode(anchor))
            let length = try Int(reader.readVarint())
            var payload = try WireFormatReader(data: reader.readBytes(count: length))
            let discriminator = try payload.readVarint()
            #expect(discriminator == UInt64(index))
        }
    }

    @Test
    func unknownDiscriminatorThrows() {
        #expect(throws: WireFormatError.self) {
            _ = try ClefAnchorCodec.decode(Data([0xFF]))
        }
    }
}
