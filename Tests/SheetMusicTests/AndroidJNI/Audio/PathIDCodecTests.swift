#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import SheetMusicWireFormat
    import Testing

    struct PathIDCodecTests {
        private let addr = StaffAddress(partIndex: 1, staffIndexInPart: 0)

        // MARK: - VoiceElementID (20 bytes via VoiceElementIDWire)

        @Test
        func voiceElementIDIs20Bytes() {
            let id = VoiceElementID(staff: addr, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
            #expect(VoiceElementIDWire(from: id).encodeToData().count == 20)
        }

        @Test
        func voiceElementIDKnownBytes() {
            let id = VoiceElementID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 2,
                voiceIndex: 1,
                elementIndex: 3,
            )
            let expected = Data([
                0x00, 0x00, 0x00, 0x00, // partIndex=0
                0x00, 0x00, 0x00, 0x00, // staffIndexInPart=0
                0x02, 0x00, 0x00, 0x00, // measureIndex=2
                0x01, 0x00, 0x00, 0x00, // voiceIndex=1
                0x03, 0x00, 0x00, 0x00, // elementIndex=3
            ])
            #expect(VoiceElementIDWire(from: id).encodeToData() == expected)
        }

        @Test
        func voiceElementIDRoundTrip() throws {
            let original = VoiceElementID(
                staff: addr, measureIndex: 5, voiceIndex: 2, elementIndex: 10,
            )
            let bytes = VoiceElementIDWire(from: original).encodeToData()
            let decoded = try VoiceElementIDWire(decoding: bytes).decoded()
            #expect(decoded == original)
        }

        // MARK: - NoteID (24 bytes via NoteIDWire; top-level is same 24 bytes)

        @Test
        func noteIDIs24Bytes() {
            let id = NoteID(
                staff: addr, measureIndex: 0, voiceIndex: 0,
                elementIndex: 0, noteIndexInChord: 0,
            )
            #expect(PathIDCodecs.encode(id).count == 24)
        }

        @Test
        func noteIDKnownBytes() {
            let id = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
                measureIndex: 3,
                voiceIndex: 0,
                elementIndex: 2,
                noteIndexInChord: 1,
            )
            let expected = Data([
                0x00, 0x00, 0x00, 0x00, // partIndex=0
                0x01, 0x00, 0x00, 0x00, // staffIndexInPart=1
                0x03, 0x00, 0x00, 0x00, // measureIndex=3
                0x00, 0x00, 0x00, 0x00, // voiceIndex=0
                0x02, 0x00, 0x00, 0x00, // elementIndex=2
                0x01, 0x00, 0x00, 0x00, // noteIndexInChord=1
            ])
            #expect(PathIDCodecs.encode(id) == expected)
        }

        @Test
        func noteIDRoundTrip() throws {
            let original = NoteID(
                staff: addr, measureIndex: 7, voiceIndex: 1,
                elementIndex: 4, noteIndexInChord: 2,
            )
            let decoded = try PathIDCodecs.decode(PathIDCodecs.encode(original))
            #expect(decoded == original)
        }

        // MARK: - RestID (20 bytes via RestIDWire)

        @Test
        func restIDIs20Bytes() {
            let id = RestID(staff: addr, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
            #expect(RestIDWire(from: id).encodeToData().count == 20)
        }

        @Test
        func restIDRoundTrip() throws {
            let original = RestID(staff: addr, measureIndex: 4, voiceIndex: 3, elementIndex: 0)
            let bytes = RestIDWire(from: original).encodeToData()
            let decoded = try RestIDWire(decoding: bytes).decoded()
            #expect(decoded == original)
        }

        // MARK: - TupletID (20 bytes via TupletIDWire)

        @Test
        func tupletIDIs20Bytes() {
            let id = TupletID(staff: addr, measureIndex: 0, voiceIndex: 0, startElementIndex: 0)
            #expect(TupletIDWire(from: id).encodeToData().count == 20)
        }

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
