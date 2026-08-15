#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicEditWire
    import Testing

    #if canImport(CoreGraphics)
        import CoreGraphics
    #endif

    struct GoldenBinaryTests {
        // MARK: - Canonical values
        //
        // These constants are the single source of truth for the verifier tests.
        // The Kotlin module's decoder tests assert byte-for-byte equivalence
        // against the same .bin files committed in
        // Tests/SheetMusicTests/Resources/Golden/Audio/.

        static let canonicalStaffAddress = StaffAddress(
            partIndex: 1, staffIndexInPart: 0,
        )

        static let canonicalNoteID = NoteID(
            staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
            measureIndex: 4,
            voiceIndex: 0,
            elementIndex: 2,
            noteIndexInChord: 1,
        )

        static let canonicalScoreItemIDNote = ScoreItemID.note(NoteID(
            staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
            measureIndex: 4,
            voiceIndex: 0,
            elementIndex: 2,
            noteIndexInChord: 1,
        ))

        static let canonicalScoreItemIDRest = ScoreItemID.rest(RestID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 2,
            voiceIndex: 1,
            elementIndex: 0,
        ))

        static let canonicalScoreItemIDTuplet = ScoreItemID.tuplet(TupletID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 3,
            voiceIndex: 0,
            startElementIndex: 5,
        ))

        static let canonicalScoreItemIDClefExplicit = ScoreItemID.clef(.explicit(VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 1,
            voiceIndex: 0,
            elementIndex: 0,
        )))

        static let canonicalScoreItemIDClefStaffDefault = ScoreItemID.clef(
            .staffDefault(StaffAddress(partIndex: 0, staffIndexInPart: 0)),
        )

        static let canonicalScoreCursorItem = ScoreCursor.item(ScoreItemID.note(NoteID(
            staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
            measureIndex: 4,
            voiceIndex: 0,
            elementIndex: 2,
            noteIndexInChord: 1,
        )))

        static let canonicalScoreCursorBeat = ScoreCursor.beat(measureIndex: 2, tickInMeasure: 480)

        static let canonicalFrame = PlaybackTimeline.Frame(
            tick: 480,
            timeSeconds: 1.5,
            cursor: ScoreCursor.item(ScoreItemID.note(NoteID(
                staff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
                measureIndex: 4,
                voiceIndex: 0,
                elementIndex: 2,
                noteIndexInChord: 1,
            ))),
        )

        static let canonicalBeats: [MetronomeBeat] = [
            MetronomeBeat(tick: 0, isDownbeat: true),
            MetronomeBeat(tick: 480, isDownbeat: false),
            MetronomeBeat(tick: 960, isDownbeat: true),
        ]

        static let canonicalStaffParams: [StaffParams] = [
            StaffParams(staffIndex: 0, bankLSB: 0, program: 0, isDrums: false, partAddressHash: 0),
            StaffParams(staffIndex: 1, bankLSB: 0, program: 0, isDrums: true, partAddressHash: 1001),
        ]

        // cursorFrame-v1.bin: CGRect(x: 10.5, y: 20.0, width: 4.0, height: 80.5)
        static let canonicalCursorFrameRect = CGRect(
            x: 10.5, y: 20.0, width: 4.0, height: 80.5,
        )

        // MARK: - Golden directory helper
        //
        // Resolved via #filePath so it always points at the source-tree resource
        // directory. Works correctly with `swift test` from the package root.

        private var goldenDir: URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Audio
                .deletingLastPathComponent() // AndroidJNI
                .deletingLastPathComponent() // SheetMusicTests
                .appendingPathComponent("Resources/Golden/Audio")
        }

        // MARK: - Verifier tests

        // staffAddress-v1.bin: StaffAddressWire (8 bytes; no version envelope)

        @Test func staffAddressGoldenMatches() throws {
            let encoded = StaffAddressCodec.encode(GoldenBinaryTests.canonicalStaffAddress)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("staffAddress-v1.bin"))
            #expect(encoded == committed)
        }

        // noteId-v1.bin: version(2) + NoteID payload(24) = 26 bytes

        @Test func noteIdGoldenMatches() throws {
            let encoded = PathIDCodecs.encode(GoldenBinaryTests.canonicalNoteID)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("noteId-v1.bin"))
            #expect(encoded == committed)
        }

        // scoreItemId-v1.bin: .note case

        @Test func scoreItemIdNoteGoldenMatches() throws {
            let encoded = ScoreItemIDCodec.encode(GoldenBinaryTests.canonicalScoreItemIDNote)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("scoreItemId-v1.bin"))
            #expect(encoded == committed)
        }

        // scoreItemId-rest-v1.bin: .rest case

        @Test func scoreItemIdRestGoldenMatches() throws {
            let encoded = ScoreItemIDCodec.encode(GoldenBinaryTests.canonicalScoreItemIDRest)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("scoreItemId-rest-v1.bin"))
            #expect(encoded == committed)
        }

        // scoreItemId-tuplet-v1.bin: .tuplet case

        @Test func scoreItemIdTupletGoldenMatches() throws {
            let encoded = ScoreItemIDCodec.encode(GoldenBinaryTests.canonicalScoreItemIDTuplet)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("scoreItemId-tuplet-v1.bin"))
            #expect(encoded == committed)
        }

        // scoreItemId-clef-explicit-v1.bin: .clef(.explicit(...)) case

        @Test func scoreItemIdClefExplicitGoldenMatches() throws {
            let encoded = ScoreItemIDCodec.encode(GoldenBinaryTests.canonicalScoreItemIDClefExplicit)
            let path = "scoreItemId-clef-explicit-v1.bin"
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent(path))
            #expect(encoded == committed)
        }

        // scoreItemId-clef-staffDefault-v1.bin: .clef(.staffDefault(...)) case

        @Test func scoreItemIdClefStaffDefaultGoldenMatches() throws {
            let encoded = ScoreItemIDCodec.encode(GoldenBinaryTests.canonicalScoreItemIDClefStaffDefault)
            let path = "scoreItemId-clef-staffDefault-v1.bin"
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent(path))
            #expect(encoded == committed)
        }

        // scoreCursor-v1.bin: .item case

        @Test func scoreCursorItemGoldenMatches() throws {
            let encoded = ScoreCursorCodec.encode(GoldenBinaryTests.canonicalScoreCursorItem)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("scoreCursor-v1.bin"))
            #expect(encoded == committed)
        }

        // scoreCursor-beat-v1.bin: .beat case

        @Test func scoreCursorBeatGoldenMatches() throws {
            let encoded = ScoreCursorCodec.encode(GoldenBinaryTests.canonicalScoreCursorBeat)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("scoreCursor-beat-v1.bin"))
            #expect(encoded == committed)
        }

        // frame-v1.bin

        @Test func frameGoldenMatches() throws {
            let encoded = FrameCodec.encode(GoldenBinaryTests.canonicalFrame)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("frame-v1.bin"))
            #expect(encoded == committed)
        }

        // metronomeBeat-v1.bin

        @Test func metronomeBeatGoldenMatches() throws {
            let encoded = MetronomeBeatCodec.encodeArray(GoldenBinaryTests.canonicalBeats)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("metronomeBeat-v1.bin"))
            #expect(encoded == committed)
        }

        // staffParams-v1.bin

        @Test func staffParamsGoldenMatches() throws {
            let encoded = StaffParamsCodec.encodeArray(GoldenBinaryTests.canonicalStaffParams)
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("staffParams-v1.bin"))
            #expect(encoded == committed)
        }

        // cursorFrame-v1.bin: version(2) + 4 × i64(8) = 34 bytes

        @Test func cursorFrameGoldenMatches() throws {
            let encoded = CursorFrameCodec.encode(GoldenBinaryTests.canonicalCursorFrameRect)
            let committed = try Data(
                contentsOf: goldenDir.appendingPathComponent("cursorFrame-v1.bin"),
            )
            #expect(encoded == committed)
        }
    }
#endif
