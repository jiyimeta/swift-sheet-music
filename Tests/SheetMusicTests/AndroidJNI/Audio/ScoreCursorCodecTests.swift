#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import Testing
    import Wirelet

    struct ScoreCursorCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        // Byte-count, discriminator-offset, and byte-sequence assertions are
        // superseded by golden fixtures in the Kotlin codec tests. Only
        // round-trip and error-path tests are kept here.

        @Test
        func itemNoteRoundTrip() throws {
            let noteID = NoteID(
                staff: addr, measureIndex: 2, voiceIndex: 0,
                elementIndex: 1, noteIndexInChord: 0,
            )
            let original = ScoreCursor.item(.note(noteID))
            let decoded = try ScoreCursorCodec.decode(ScoreCursorCodec.encode(original))
            #expect(decoded == original)
        }

        @Test
        func itemRestRoundTrip() throws {
            let restID = RestID(staff: addr, measureIndex: 0, voiceIndex: 1, elementIndex: 3)
            let original = ScoreCursor.item(.rest(restID))
            let decoded = try ScoreCursorCodec.decode(ScoreCursorCodec.encode(original))
            #expect(decoded == original)
        }

        @Test
        func beatRoundTrip() throws {
            let original = ScoreCursor.beat(measureIndex: 7, tickInMeasure: 1920)
            let decoded = try ScoreCursorCodec.decode(ScoreCursorCodec.encode(original))
            #expect(decoded == original)
        }

        @Test
        func unknownDiscriminatorThrows() {
            #expect(throws: WireFormatError.self) {
                _ = try ScoreCursorCodec.decode(Data([0xFF]))
            }
        }
    }
#endif
