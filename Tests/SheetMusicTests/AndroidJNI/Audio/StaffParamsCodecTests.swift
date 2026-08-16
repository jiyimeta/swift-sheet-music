#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing

    struct StaffParamsCodecTests {
        // Byte-count and byte-sequence assertions are superseded by golden
        // fixtures in the Kotlin codec tests. Only round-trip tests are kept here.

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
        func staffGroupRoundTripsAndDefaultsToPitched() throws {
            let entries = [
                StaffParams(
                    staffIndex: 0, bankLSB: 0, program: 0,
                    isDrums: false, partAddressHash: 0,
                ),
                // A pitched-percussion staff: `isDrums` is false because the PART does not declare
                // `useDrumset`, while the staff type still reads "percussion". The pair is the whole
                // reason the field exists, and a fixture where the two agreed could not show it.
                StaffParams(
                    staffIndex: 1, bankLSB: 0, program: 47,
                    isDrums: false, partAddressHash: 1000,
                    groupRawValue: "percussion",
                ),
            ]
            let decoded = try StaffParamsCodec.decodeArray(StaffParamsCodec.encodeArray(entries))
            #expect(decoded.count == 2)
            #expect(decoded[0].groupRawValue == "pitched")
            #expect(decoded[1].groupRawValue == "percussion")
            #expect(decoded[1].isDrums == false)
        }
    }
#endif
