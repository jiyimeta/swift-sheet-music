#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import Testing
    import Wirelet

    struct GMInstrumentCodecTests {
        @Test func encodesAll128PatchesInOrder() throws {
            let data = GMInstrumentCodec.encodeAll()
            #expect(!data.isEmpty)

            let decoded = try [GMInstrument](decoding: data)
            #expect(decoded.count == 128)

            for (row, expected) in zip(decoded, GMInstrument.all) {
                #expect(row.program == expected.program)
                #expect(row.name == expected.name)
                #expect(row.family == expected.family)
            }
        }

        @Test func familyOrdinalMatchesAllCasesOrder() throws {
            let data = GMInstrumentCodec.encodeAll()
            let decoded = try [GMInstrument](decoding: data)
            for (row, expected) in zip(decoded, GMInstrument.all) {
                #expect(row.family == expected.family)
            }
        }

        @Test func rawByteLayoutForFirstRow() {
            // Sanity: explicit byte layout for the first row matches the
            // documented wire format. Layout:
            //   i32 instrumentCount, then per row:
            //   u8 program, i32 nameLen, utf-8 bytes, u8 familyOrdinal.
            let data = GMInstrumentCodec.encodeAll()
            let bytes = Array(data)

            // i32 instrumentCount (le) = 128
            let count = Int32(bytes[0])
                | (Int32(bytes[1]) << 8)
                | (Int32(bytes[2]) << 16)
                | (Int32(bytes[3]) << 24)
            #expect(count == 128)
            // Row 0: program == 0
            #expect(bytes[4] == 0)
            // i32 nameLen, name = "Acoustic Grand Piano" → 20 UTF-8 bytes
            let nameLen = Int32(bytes[5])
                | (Int32(bytes[6]) << 8)
                | (Int32(bytes[7]) << 16)
                | (Int32(bytes[8]) << 24)
            #expect(nameLen == 20)
            // After name bytes, family ordinal 0 (Piano)
            let familyOrdinalIndex = 9 + 20
            #expect(bytes[familyOrdinalIndex] == 0)
        }
    }
#endif
