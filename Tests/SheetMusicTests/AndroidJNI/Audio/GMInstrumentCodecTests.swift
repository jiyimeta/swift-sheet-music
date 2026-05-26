#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import Testing
    import Wirelet

    struct GMInstrumentCodecTests {
        // Raw byte-layout assertions are superseded by golden fixtures in the
        // Kotlin codec tests. Only round-trip tests are kept here.

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
    }
#endif
