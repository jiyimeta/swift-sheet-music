#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    /// The Android draw-program re-encode decides a grace head's tint by its grace identity, the same key the
    /// CALayer path registers it under — so a grace selection and its parent note's selection tint different glyphs.
    struct DrawProgramGraceSelectionTests {
        private let _installApple = TestSupport.installApple

        private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        private static let tintArgb: UInt32 = 0xFF12_3456

        /// B4 with a G4 acciaccatura, then a dotted half rest.
        private static func document() -> LayoutDocument {
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .chord(Chord(
                    duration: .quarter, notes: [Note(pitch: 71, tpc: 19)],
                    graceNotesBefore: [GraceChord(
                        graceType: .acciaccatura, duration: .eighth, notes: [Note(pitch: 67, tpc: 15)],
                    )],
                    graceNotesAfter: [],
                )),
                .rest(duration: .fraction(Fraction(numerator: 3, denominator: 4))),
            ])
            let score = Score(division: 480, parts: [Part(
                id: "1", instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [voice])])],
            )])
            return LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
        }

        /// The glyph opened by the single tint bracket `ids` produces, as (x, y, size).
        private static func tintedGlyph(selecting ids: Set<ScoreItemID>) throws -> (Double, Double, Double) {
            let commands = LayoutBridge.buildCommands(layout: document(), tint: (argb: tintArgb, ids: ids))
            let brackets = commands.indices.filter {
                if case let .setColor(argb) = commands[$0] { return argb == tintArgb }
                return false
            }
            try #require(brackets.count == 1)
            let index = try #require(brackets.first)
            guard index + 1 < commands.count, case let .glyph(_, x, y, size, _) = commands[index + 1] else {
                Issue.record("expected a glyph immediately after the tint bracket")
                return (.nan, .nan, .nan)
            }
            return (x, y, size)
        }

        @Test("A grace selection tints the grace head, not its parent")
        func graceSelectionTintsGrace() throws {
            let grace = ScoreItemID.graceNote(GraceNoteID(
                parent: VoiceElementID(staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1),
                side: .before, graceIndex: 0, noteIndexInGraceChord: 0,
            ))
            let parent = ScoreItemID.note(NoteID(
                staff: Self.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            ))
            let graceGlyph = try Self.tintedGlyph(selecting: [grace])
            let parentGlyph = try Self.tintedGlyph(selecting: [parent])
            // Left of the parent, and drawn at the grace size.
            #expect(graceGlyph.0 < parentGlyph.0)
            #expect(graceGlyph.2 < parentGlyph.2)
        }
    }
#endif
