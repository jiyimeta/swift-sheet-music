#if !os(Android)
    import Foundation
    import SheetMusicCore
    import SheetMusicEditWire
    import Testing
    import Wirelet

    struct PathIDCodecTests {
        private let addr = StaffAddress(partIndex: 1, staffIndexInPart: 0)

        // Byte-count and byte-sequence assertions are superseded by golden
        // fixtures in the Kotlin codec tests. Only round-trip tests are kept here.

        // MARK: - VoiceElementID

        @Test
        func voiceElementIDRoundTrip() throws {
            let original = VoiceElementID(
                staff: addr, measureIndex: 5, voiceIndex: 2, elementIndex: 10,
            )
            let bytes = VoiceElementIDWire(from: original).encodeToData()
            let decoded = try VoiceElementIDWire(decoding: bytes).decoded()
            #expect(decoded == original)
        }

        // MARK: - NoteID

        @Test
        func noteIDRoundTrip() throws {
            let original = NoteID(
                staff: addr, measureIndex: 7, voiceIndex: 1,
                elementIndex: 4, noteIndexInChord: 2,
            )
            let decoded = try PathIDCodecs.decode(PathIDCodecs.encode(original))
            #expect(decoded == original)
        }

        // MARK: - RestID

        @Test
        func restIDRoundTrip() throws {
            let original = RestID(staff: addr, measureIndex: 4, voiceIndex: 3, elementIndex: 0)
            let bytes = RestIDWire(from: original).encodeToData()
            let decoded = try RestIDWire(decoding: bytes).decoded()
            #expect(decoded == original)
        }

        // MARK: - TupletID

        @Test
        func tupletIDRoundTrip() throws {
            let original = TupletID(
                staff: addr, measureIndex: 2, voiceIndex: 1, startElementIndex: 5,
            )
            let bytes = TupletIDWire(from: original).encodeToData()
            let decoded = try TupletIDWire(decoding: bytes).decoded()
            #expect(decoded == original)
        }
    }
#endif
