#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    struct LayoutChordNoteInvisibleTests {
        @Test func defaultsVisible() {
            let n = LayoutChordNote(
                noteID: NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: 0,
                    voiceIndex: 0,
                    elementIndex: 0,
                    noteIndexInChord: 0,
                ),
                step: 0,
                accidental: nil,
                origin: .zero,
                tieForward: nil,
                tieBack: nil,
                hasGlissando: false,
            )
            #expect(n.isInvisible == false)
        }

        @Test func explicitInvisible() {
            let n = LayoutChordNote(
                noteID: NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: 0,
                    voiceIndex: 0,
                    elementIndex: 0,
                    noteIndexInChord: 0,
                ),
                step: 0,
                accidental: nil,
                origin: .zero,
                tieForward: nil,
                tieBack: nil,
                hasGlissando: false,
                isInvisible: true,
            )
            #expect(n.isInvisible == true)
        }
    }
#endif
