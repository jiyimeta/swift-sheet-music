#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing

    struct StaffAddressCodecTests {
        // StaffAddress wire format: 8 bytes
        //   i32 partIndex         (4 bytes LE)
        //   i32 staffIndexInPart  (4 bytes LE)

        @Test
        func encodePayloadProducesEightBytes() {
            let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            var w = AudioBinaryWriter()
            StaffAddressCodec.encodePayload(addr, into: &w)
            #expect(w.data.count == 8)
        }

        @Test
        func encodePayloadKnownBytes() {
            // partIndex=1, staffIndexInPart=2
            // bytes: [1,0,0,0, 2,0,0,0]
            let addr = StaffAddress(partIndex: 1, staffIndexInPart: 2)
            var w = AudioBinaryWriter()
            StaffAddressCodec.encodePayload(addr, into: &w)
            #expect(w.data == Data([0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00]))
        }

        @Test
        func encodePayloadNegativeIndicesAllowed() {
            // Negative values encode as two's complement LE
            let addr = StaffAddress(partIndex: -1, staffIndexInPart: 0)
            var w = AudioBinaryWriter()
            StaffAddressCodec.encodePayload(addr, into: &w)
            #expect(w.data.prefix(4) == Data([0xFF, 0xFF, 0xFF, 0xFF]))
        }

        @Test
        func roundTripZero() throws {
            let original = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            var w = AudioBinaryWriter()
            StaffAddressCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try StaffAddressCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func roundTripNonZero() throws {
            let original = StaffAddress(partIndex: 3, staffIndexInPart: 7)
            var w = AudioBinaryWriter()
            StaffAddressCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try StaffAddressCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func decodePayloadThrowsUnderflow() {
            var r = AudioBinaryReader(Data([0x01, 0x00, 0x00])) // only 3 bytes
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try StaffAddressCodec.decodePayload(&r)
            }
        }
    }
#endif
