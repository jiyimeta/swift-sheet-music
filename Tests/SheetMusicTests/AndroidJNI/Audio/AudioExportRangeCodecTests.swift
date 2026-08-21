#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicAudioCore
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import Testing
    import Wirelet

    struct AudioExportRangeCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        // Byte-count and raw-discriminator assertions are superseded by golden
        // fixtures in the Kotlin codec tests. Only round-trip and error-path
        // tests are kept here.

        @Test
        func fullRoundTrip() throws {
            let original = AudioExportRange.full
            let decoded = try AudioExportRangeCodec.decode(AudioExportRangeCodec.encode(original))
            guard case .full = decoded else {
                Issue.record("expected .full, got \(decoded)")
                return
            }
        }

        @Test
        func currentLoopRoundTrip() throws {
            let original = AudioExportRange.currentLoop
            let decoded = try AudioExportRangeCodec.decode(AudioExportRangeCodec.encode(original))
            guard case .currentLoop = decoded else {
                Issue.record("expected .currentLoop, got \(decoded)")
                return
            }
        }

        @Test
        func regionBeatBeatRoundTrip() throws {
            let original = AudioExportRange.region(
                from: .beat(measureIndex: 0, tickInMeasure: 0),
                to: .beat(measureIndex: 1, tickInMeasure: 240),
            )
            let blob = AudioExportRangeCodec.encode(original)
            let decoded = try AudioExportRangeCodec.decode(blob)
            guard case let .region(from, to) = decoded else {
                Issue.record("expected .region, got \(decoded)")
                return
            }
            #expect(from == .beat(measureIndex: 0, tickInMeasure: 0))
            #expect(to == .beat(measureIndex: 1, tickInMeasure: 240))
        }

        @Test
        func regionThroughEndRoundTrip() throws {
            let noteID = NoteID(
                staff: addr, measureIndex: 3, voiceIndex: 0,
                elementIndex: 2, noteIndexInChord: 0,
            )
            let original = AudioExportRange.regionThroughEnd(
                from: .beat(measureIndex: 0, tickInMeasure: 0),
                last: .note(noteID),
            )
            let blob = AudioExportRangeCodec.encode(original)
            let decoded = try AudioExportRangeCodec.decode(blob)
            guard case let .regionThroughEnd(from, last) = decoded else {
                Issue.record("expected .regionThroughEnd, got \(decoded)")
                return
            }
            #expect(from == .beat(measureIndex: 0, tickInMeasure: 0))
            #expect(last == .note(noteID))
        }

        @Test
        func unknownDiscriminatorThrows() {
            #expect(throws: WireFormatError.self) {
                _ = try AudioExportRangeCodec.decode(Data([0xFF]))
            }
        }
    }
#endif
