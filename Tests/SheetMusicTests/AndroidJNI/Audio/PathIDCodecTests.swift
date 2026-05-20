#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing

    struct PathIDCodecTests {
        private let addr = StaffAddress(partIndex: 1, staffIndexInPart: 0)

        // MARK: - VoiceElementID (20 bytes)
        // StaffAddress(8) + i32 measureIndex + i32 voiceIndex + i32 elementIndex

        @Test
        func voiceElementIDPayloadIs20Bytes() {
            let id = VoiceElementID(
                staff: addr,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeVoiceElementIDPayload(id, into: &w)
            #expect(w.data.count == 20)
        }

        @Test
        func voiceElementIDKnownBytes() {
            // partIndex=0, staffIndexInPart=0, measureIndex=2, voiceIndex=1, elementIndex=3
            // [0,0,0,0, 0,0,0,0, 2,0,0,0, 1,0,0,0, 3,0,0,0]
            let id = VoiceElementID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 2,
                voiceIndex: 1,
                elementIndex: 3,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeVoiceElementIDPayload(id, into: &w)
            let expected = Data([
                0x00, 0x00, 0x00, 0x00, // partIndex=0
                0x00, 0x00, 0x00, 0x00, // staffIndexInPart=0
                0x02, 0x00, 0x00, 0x00, // measureIndex=2
                0x01, 0x00, 0x00, 0x00, // voiceIndex=1
                0x03, 0x00, 0x00, 0x00, // elementIndex=3
            ])
            #expect(w.data == expected)
        }

        @Test
        func voiceElementIDRoundTrip() throws {
            let original = VoiceElementID(
                staff: addr,
                measureIndex: 5,
                voiceIndex: 2,
                elementIndex: 10,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeVoiceElementIDPayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try PathIDCodecs.decodeVoiceElementIDPayload(&r)
            #expect(decoded == original)
        }

        // MARK: - NoteID (24 bytes: 20 + i32 noteIndexInChord)
        // Top-level blob: u16 version=1 + NoteIDPayload (24 bytes) = 26 bytes

        @Test
        func noteIDPayloadIs24Bytes() {
            let id = NoteID(
                staff: addr,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
                noteIndexInChord: 0,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeNoteIDPayload(id, into: &w)
            #expect(w.data.count == 24)
        }

        @Test
        func noteIDKnownBytes() {
            // partIndex=0, staffIndexInPart=1, measureIndex=3, voiceIndex=0, elementIndex=2, noteIndexInChord=1
            let id = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 1),
                measureIndex: 3,
                voiceIndex: 0,
                elementIndex: 2,
                noteIndexInChord: 1,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeNoteIDPayload(id, into: &w)
            let expected = Data([
                0x00, 0x00, 0x00, 0x00, // partIndex=0
                0x01, 0x00, 0x00, 0x00, // staffIndexInPart=1
                0x03, 0x00, 0x00, 0x00, // measureIndex=3
                0x00, 0x00, 0x00, 0x00, // voiceIndex=0
                0x02, 0x00, 0x00, 0x00, // elementIndex=2
                0x01, 0x00, 0x00, 0x00, // noteIndexInChord=1
            ])
            #expect(w.data == expected)
        }

        @Test
        func noteIDRoundTrip() throws {
            let original = NoteID(
                staff: addr,
                measureIndex: 7,
                voiceIndex: 1,
                elementIndex: 4,
                noteIndexInChord: 2,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeNoteIDPayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try PathIDCodecs.decodeNoteIDPayload(&r)
            #expect(decoded == original)
        }

        @Test
        func noteIDTopLevelIs26Bytes() {
            let id = NoteID(
                staff: addr,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
                noteIndexInChord: 0,
            )
            let blob = PathIDCodecs.encode(id)
            #expect(blob.count == 26) // 2 (version) + 24 (payload)
        }

        @Test
        func noteIDTopLevelRoundTrip() throws {
            let original = NoteID(
                staff: addr,
                measureIndex: 3,
                voiceIndex: 0,
                elementIndex: 1,
                noteIndexInChord: 0,
            )
            let blob = PathIDCodecs.encode(original)
            let decoded = try PathIDCodecs.decode(blob)
            #expect(decoded == original)
        }

        @Test
        func noteIDTopLevelVersionMismatch() {
            let id = NoteID(
                staff: addr,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
                noteIndexInChord: 0,
            )
            var blob = PathIDCodecs.encode(id)
            blob[0] = 0xFF // corrupt version LSB
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try PathIDCodecs.decode(blob)
            }
        }

        // MARK: - RestID (20 bytes)

        @Test
        func restIDPayloadIs20Bytes() {
            let id = RestID(
                staff: addr,
                measureIndex: 0,
                voiceIndex: 0,
                elementIndex: 0,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeRestIDPayload(id, into: &w)
            #expect(w.data.count == 20)
        }

        @Test
        func restIDRoundTrip() throws {
            let original = RestID(
                staff: addr,
                measureIndex: 4,
                voiceIndex: 3,
                elementIndex: 0,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeRestIDPayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try PathIDCodecs.decodeRestIDPayload(&r)
            #expect(decoded == original)
        }

        // MARK: - TupletID (20 bytes)

        @Test
        func tupletIDPayloadIs20Bytes() {
            let id = TupletID(
                staff: addr,
                measureIndex: 0,
                voiceIndex: 0,
                startElementIndex: 0,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeTupletIDPayload(id, into: &w)
            #expect(w.data.count == 20)
        }

        @Test
        func tupletIDRoundTrip() throws {
            let original = TupletID(
                staff: addr,
                measureIndex: 2,
                voiceIndex: 1,
                startElementIndex: 5,
            )
            var w = AudioBinaryWriter()
            PathIDCodecs.encodeTupletIDPayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try PathIDCodecs.decodeTupletIDPayload(&r)
            #expect(decoded == original)
        }
    }
#endif
