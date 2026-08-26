#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import Testing

    struct FrameCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        // Byte-offset assertions are superseded by golden fixtures in the Kotlin
        // codec tests. Only round-trip tests are kept here.

        @Test
        func beatFrameRoundTrip() throws {
            let original = PlaybackTimeline.Frame(
                tick: 480,
                timeSeconds: 0.5,
                cursor: .beat(measureIndex: 0, tickInMeasure: 480),
            )
            let decoded = try FrameCodec.decode(FrameCodec.encode(original))
            #expect(decoded.tick == original.tick)
            #expect(decoded.timeSeconds == original.timeSeconds)
            #expect(decoded.cursor == original.cursor)
        }

        @Test
        func itemFrameRoundTrip() throws {
            let noteID = NoteID(
                staff: addr, measureIndex: 2, voiceIndex: 0,
                elementIndex: 1, noteIndexInChord: 0,
            )
            let original = PlaybackTimeline.Frame(
                tick: 960,
                timeSeconds: 1.0,
                cursor: .item(.note(noteID)),
            )
            let decoded = try FrameCodec.decode(FrameCodec.encode(original))
            #expect(decoded.tick == original.tick)
            #expect(decoded.timeSeconds == original.timeSeconds)
            #expect(decoded.cursor == original.cursor)
        }

        @Test
        func timeSecondsExactRoundTrip() throws {
            // Raw Double round-trip is bit-identical for representable values.
            let original = PlaybackTimeline.Frame(
                tick: 100, timeSeconds: 1.23456789,
                cursor: .beat(measureIndex: 0, tickInMeasure: 0),
            )
            let decoded = try FrameCodec.decode(FrameCodec.encode(original))
            #expect(decoded.timeSeconds == original.timeSeconds)
        }
    }
#endif
