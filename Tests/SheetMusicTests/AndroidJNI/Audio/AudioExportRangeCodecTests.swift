#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicAudioCore
    import SheetMusicCore
    import Testing

    struct AudioExportRangeCodecTests {
        private let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        // MARK: - Tag 0 / 1 (no payload)

        @Test
        func decodeFull() throws {
            let bytes: [UInt8] = [
                0x01, 0x00, // version=1 (LE)
                0x00, // tag=full
            ]
            let range = try AudioExportRangeCodec.decode(Data(bytes))
            guard case .full = range else {
                Issue.record("expected .full, got \(range)")
                return
            }
        }

        @Test
        func decodeCurrentLoop() throws {
            let bytes: [UInt8] = [
                0x01, 0x00, // version=1
                0x01, // tag=currentLoop
            ]
            let range = try AudioExportRangeCodec.decode(Data(bytes))
            guard case .currentLoop = range else {
                Issue.record("expected .currentLoop, got \(range)")
                return
            }
        }

        // MARK: - Tag 2 (region) using BinaryWriter round-trip

        @Test
        func decodeRegionBeatBeat() throws {
            var w = AudioBinaryWriter()
            w.append(AudioExportRangeCodecTestHelpers.version)
            w.append(UInt8(2)) // tag = region
            ScoreCursorCodec.encodePayload(
                .beat(measureIndex: 0, tickInMeasure: 0), into: &w,
            )
            ScoreCursorCodec.encodePayload(
                .beat(measureIndex: 1, tickInMeasure: 240), into: &w,
            )

            let range = try AudioExportRangeCodec.decode(w.data)
            guard case let .region(from, to) = range else {
                Issue.record("expected .region, got \(range)")
                return
            }
            #expect(from == .beat(measureIndex: 0, tickInMeasure: 0))
            #expect(to == .beat(measureIndex: 1, tickInMeasure: 240))
        }

        // MARK: - Tag 3 (regionThroughEnd)

        @Test
        func decodeRegionThroughEnd() throws {
            let noteID = NoteID(
                staff: addr, measureIndex: 3, voiceIndex: 0,
                elementIndex: 2, noteIndexInChord: 0,
            )
            var w = AudioBinaryWriter()
            w.append(AudioExportRangeCodecTestHelpers.version)
            w.append(UInt8(3)) // tag = regionThroughEnd
            ScoreCursorCodec.encodePayload(
                .beat(measureIndex: 0, tickInMeasure: 0), into: &w,
            )
            ScoreItemIDCodec.encodePayload(.note(noteID), into: &w)

            let range = try AudioExportRangeCodec.decode(w.data)
            guard case let .regionThroughEnd(from, last) = range else {
                Issue.record("expected .regionThroughEnd, got \(range)")
                return
            }
            #expect(from == .beat(measureIndex: 0, tickInMeasure: 0))
            #expect(last == .note(noteID))
        }

        /// RegionThroughEnd byte budget asserted by the Kotlin encoder test:
        ///   header(3) + Beat cursor(9) + ScoreItemID.Note(1 + 24) = 37 bytes.
        @Test
        func regionThroughEndIs37Bytes() {
            let noteID = NoteID(
                staff: addr, measureIndex: 0, voiceIndex: 0,
                elementIndex: 0, noteIndexInChord: 0,
            )
            var w = AudioBinaryWriter()
            w.append(AudioExportRangeCodecTestHelpers.version)
            w.append(UInt8(3))
            ScoreCursorCodec.encodePayload(
                .beat(measureIndex: 0, tickInMeasure: 0), into: &w,
            )
            ScoreItemIDCodec.encodePayload(.note(noteID), into: &w)
            #expect(w.data.count == 37)
        }

        // MARK: - Failure modes

        @Test
        func unknownTagThrows() {
            let bytes: [UInt8] = [0x01, 0x00, 0xFF]
            #expect(throws: AudioExportRangeCodec.DecodeError.self) {
                _ = try AudioExportRangeCodec.decode(Data(bytes))
            }
        }

        @Test
        func versionMismatchThrows() {
            let bytes: [UInt8] = [0xFF, 0x00, 0x00]
            #expect(throws: AudioBinaryReader.BinaryReaderError.self) {
                _ = try AudioExportRangeCodec.decode(Data(bytes))
            }
        }
    }

    /// Tiny holder so the internal `version` static is accessible from the
    /// test target without exposing it publicly.
    enum AudioExportRangeCodecTestHelpers {
        static let version: UInt16 = AudioExportRangeCodec.version
    }
#endif
