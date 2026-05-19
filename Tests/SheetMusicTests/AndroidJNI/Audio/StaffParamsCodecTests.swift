#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing

    struct StaffParamsCodecTests {
        // StaffParamsArray blob:
        //   u16 version (= 1)
        //   i32 count
        //   count × { i32 staffIndex; u8 bankLSB; u8 program; u8 isDrums; u8 _reserved; i64 partAddressHash }
        //   16 bytes per entry

        @Test
        func emptyArrayRoundTrip() throws {
            let blob = StaffParamsCodec.encodeArray([])
            let decoded = try StaffParamsCodec.decodeArray(blob)
            #expect(decoded.isEmpty)
        }

        @Test
        func singleEntryRoundTrip() throws {
            let params = StaffParams(
                staffIndex: 0,
                bankLSB: 0,
                program: 40,
                isDrums: false,
                partAddressHash: 0,
            )
            let blob = StaffParamsCodec.encodeArray([params])
            let decoded = try StaffParamsCodec.decodeArray(blob)
            #expect(decoded.count == 1)
            #expect(decoded[0] == params)
        }

        @Test
        func drumChannelRoundTrip() throws {
            let params = StaffParams(
                staffIndex: 2,
                bankLSB: 0,
                program: 0,
                isDrums: true,
                partAddressHash: 42,
            )
            let blob = StaffParamsCodec.encodeArray([params])
            let decoded = try StaffParamsCodec.decodeArray(blob)
            #expect(decoded.count == 1)
            #expect(decoded[0].isDrums == true)
            #expect(decoded[0].staffIndex == 2)
            #expect(decoded[0].partAddressHash == 42)
        }

        @Test
        func multipleEntriesRoundTrip() throws {
            let entries = [
                StaffParams(
                    staffIndex: 0, bankLSB: 0, program: 0,
                    isDrums: false, partAddressHash: 1000,
                ),
                StaffParams(
                    staffIndex: 1, bankLSB: 0, program: 40,
                    isDrums: false, partAddressHash: 1001,
                ),
                StaffParams(
                    staffIndex: 2, bankLSB: 0, program: 0,
                    isDrums: true, partAddressHash: 2000,
                ),
            ]
            let blob = StaffParamsCodec.encodeArray(entries)
            let decoded = try StaffParamsCodec.decodeArray(blob)
            #expect(decoded == entries)
        }

        @Test
        func entrySize16Bytes() {
            // 2 (version) + 4 (count) + 16 (entry) = 22 bytes
            let params = StaffParams(
                staffIndex: 0, bankLSB: 0, program: 0,
                isDrums: false, partAddressHash: 0,
            )
            let blob = StaffParamsCodec.encodeArray([params])
            #expect(blob.count == 22)
        }

        @Test
        func knownBytesEntry() {
            // staffIndex=1, bankLSB=2, program=40, isDrums=false, partAddressHash=0x0102030405060708
            let params = StaffParams(
                staffIndex: 1,
                bankLSB: 2,
                program: 40,
                isDrums: false,
                partAddressHash: 0x0102_0304_0506_0708,
            )
            let blob = StaffParamsCodec.encodeArray([params])
            // version[0..1]=1, count[2..5]=1
            // staffIndex=1: [1,0,0,0], bankLSB=2, program=40, isDrums=0, _reserved=0
            // partAddressHash little-endian
            let expected = Data([
                0x01, 0x00, // version=1
                0x01, 0x00, 0x00, 0x00, // count=1
                0x01, 0x00, 0x00, 0x00, // staffIndex=1
                0x02, // bankLSB=2
                0x28, // program=40 (0x28)
                0x00, // isDrums=false
                0x00, // _reserved
                0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // hash LE
            ])
            #expect(blob == expected)
        }

        @Test
        func versionMismatch() {
            var blob = StaffParamsCodec.encodeArray([])
            blob[0] = 0xFF // corrupt version
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try StaffParamsCodec.decodeArray(blob)
            }
        }
    }
#endif
