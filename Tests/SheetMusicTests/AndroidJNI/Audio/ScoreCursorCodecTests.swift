#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing

    struct ScoreCursorCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        // ScoreCursorPayload:
        //   u8 kind   0=item, 1=beat
        //   case 0: ScoreItemIDPayload
        //   case 1: i32 measureIndex + i32 tickInMeasure (8 bytes)

        // MARK: - Item cursor

        @Test
        func itemCursorKindByteIsZero() {
            let noteID = NoteID(
                staff: addr, measureIndex: 0, voiceIndex: 0,
                elementIndex: 0, noteIndexInChord: 0,
            )
            var w = AudioBinaryWriter()
            ScoreCursorCodec.encodePayload(.item(.note(noteID)), into: &w)
            #expect(w.data[0] == 0x00)
        }

        @Test
        func beatCursorKindByteIsOne() {
            var w = AudioBinaryWriter()
            ScoreCursorCodec.encodePayload(
                .beat(measureIndex: 0, tickInMeasure: 0), into: &w,
            )
            #expect(w.data[0] == 0x01)
        }

        @Test
        func beatCursorPayloadIs9Bytes() {
            // 1 kind + 4 measureIndex + 4 tickInMeasure
            var w = AudioBinaryWriter()
            ScoreCursorCodec.encodePayload(
                .beat(measureIndex: 5, tickInMeasure: 480), into: &w,
            )
            #expect(w.data.count == 9)
        }

        @Test
        func beatCursorKnownBytes() {
            // measureIndex=3, tickInMeasure=960
            // [0x01, 3,0,0,0, 192*5=960→0xC0,0x03,0,0]
            var w = AudioBinaryWriter()
            ScoreCursorCodec.encodePayload(
                .beat(measureIndex: 3, tickInMeasure: 960), into: &w,
            )
            let expected = Data([
                0x01, // kind=beat
                0x03, 0x00, 0x00, 0x00, // measureIndex=3
                0xC0, 0x03, 0x00, 0x00, // tickInMeasure=960
            ])
            #expect(w.data == expected)
        }

        // MARK: - Round-trip payload

        @Test
        func itemNoteRoundTrip() throws {
            let noteID = NoteID(
                staff: addr, measureIndex: 2, voiceIndex: 0,
                elementIndex: 1, noteIndexInChord: 0,
            )
            let original = ScoreCursor.item(.note(noteID))
            var w = AudioBinaryWriter()
            ScoreCursorCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ScoreCursorCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func itemRestRoundTrip() throws {
            let restID = RestID(
                staff: addr, measureIndex: 0, voiceIndex: 1, elementIndex: 3,
            )
            let original = ScoreCursor.item(.rest(restID))
            var w = AudioBinaryWriter()
            ScoreCursorCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ScoreCursorCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        @Test
        func beatRoundTrip() throws {
            let original = ScoreCursor.beat(measureIndex: 7, tickInMeasure: 1920)
            var w = AudioBinaryWriter()
            ScoreCursorCodec.encodePayload(original, into: &w)
            var r = AudioBinaryReader(w.data)
            let decoded = try ScoreCursorCodec.decodePayload(&r)
            #expect(decoded == original)
        }

        // MARK: - Top-level blob

        @Test
        func topLevelItemRoundTrip() throws {
            let noteID = NoteID(
                staff: addr, measureIndex: 1, voiceIndex: 0,
                elementIndex: 2, noteIndexInChord: 0,
            )
            let original = ScoreCursor.item(.note(noteID))
            let blob = ScoreCursorCodec.encode(original)
            let decoded = try ScoreCursorCodec.decode(blob)
            #expect(decoded == original)
        }

        @Test
        func topLevelBeatRoundTrip() throws {
            let original = ScoreCursor.beat(measureIndex: 4, tickInMeasure: 240)
            let blob = ScoreCursorCodec.encode(original)
            let decoded = try ScoreCursorCodec.decode(blob)
            #expect(decoded == original)
        }

        @Test
        func topLevelVersionMismatch() {
            let original = ScoreCursor.beat(measureIndex: 0, tickInMeasure: 0)
            var blob = ScoreCursorCodec.encode(original)
            blob[0] = 0xFF // corrupt version
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try ScoreCursorCodec.decode(blob)
            }
        }

        @Test
        func unknownKindThrows() {
            var r = AudioBinaryReader(Data([0xFF]))
            #expect(throws: Error.self) {
                _ = try ScoreCursorCodec.decodePayload(&r)
            }
        }
    }
#endif
