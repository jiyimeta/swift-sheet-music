#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    import SheetMusicCore
    import SheetMusicEditWire
    import Testing
    import Wirelet

    struct StaffAddressCodecTests {
        // Byte-count and byte-sequence assertions are superseded by golden
        // fixtures in the Kotlin codec tests. Only round-trip and error-path
        // tests are kept here.

        @Test
        func roundTripZero() throws {
            let original = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            let decoded = try StaffAddressCodec.decode(StaffAddressCodec.encode(original))
            #expect(decoded == original)
        }

        @Test
        func roundTripNonZero() throws {
            let original = StaffAddress(partIndex: 3, staffIndexInPart: 7)
            let decoded = try StaffAddressCodec.decode(StaffAddressCodec.encode(original))
            #expect(decoded == original)
        }

        @Test
        func decodeUnderflowThrows() {
            #expect(throws: WireFormatError.self) {
                _ = try StaffAddressCodec.decode(Data([0x01, 0x00, 0x00])) // truncated
            }
        }
    }
#endif
