#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicAudioCore
    @testable import SheetMusicBridgeCore
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
            // Entry 1 carries a non-default `groupRawValue` so the golden bytes discriminate: with
            // both entries at "pitched" the field's tag would still be present but its payload would
            // be the same string twice, and a swap with `defaultClefType` (also a trailing string)
            // would survive the comparison.
            StaffParams(
                staffIndex: 1, bankLSB: 0, program: 0, isDrums: true, partAddressHash: 1001,
                groupRawValue: "percussion",
            ),
        ]

        // cursorFrame-v1.bin: CGRect(x: 10.5, y: 20.0, width: 4.0, height: 80.5)
        static let canonicalCursorFrameRect = CGRect(
            x: 10.5, y: 20.0, width: 4.0, height: 80.5,
        )

        // editCaretFrame-v1.bin / selectionTint-v1.bin — the two payloads the editing-geometry JNI entry
        // points exchange with a Kotlin host, and the only ones whose Kotlin side is a *generated* codec
        // (`editGeometry` in SheetMusicAudioAndroid's build.gradle.kts) rather than a hand-written model.
        // A generated encoder that disagrees with this one would mistint the score or float the caret in
        // the wrong place, silently — nothing on either side validates the other.
        static let canonicalCaretFrame = (xMm: 12.5, yMm: 30.25, widthMm: 1.5, heightMm: 24.0)
        static let canonicalTintArgb: UInt32 = 0xFF33_66CC

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

        // editCaretFrame-v1.bin: four fixed64 fields, no version envelope

        @Test func editCaretFrameGoldenMatches() throws {
            let frame = GoldenBinaryTests.canonicalCaretFrame
            let encoded = EditCaretFrameCodec.encode(
                xMm: frame.xMm, yMm: frame.yMm, widthMm: frame.widthMm, heightMm: frame.heightMm,
            )
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("editCaretFrame-v1.bin"))
            #expect(encoded == committed)
        }

        // selectionTint-v1.bin: argb + a one-element ScoreItemID array. One element on purpose — the Swift
        // side takes a Set, so any larger fixture would encode in an unspecified order and the golden would
        // flap.

        @Test func selectionTintGoldenMatches() throws {
            let encoded = SelectionTintCodec.encode(
                argb: GoldenBinaryTests.canonicalTintArgb,
                ids: [GoldenBinaryTests.canonicalScoreItemIDNote],
            )
            let committed = try Data(contentsOf: goldenDir.appendingPathComponent("selectionTint-v1.bin"))
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
