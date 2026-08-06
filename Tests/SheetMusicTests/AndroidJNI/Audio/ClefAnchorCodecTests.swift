#if !os(Android)
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
        func unknownDiscriminatorThrows() {
            #expect(throws: WireFormatError.self) {
                _ = try ClefAnchorCodec.decode(Data([0xFF]))
            }
        }
    }
#endif
