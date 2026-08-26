#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// A PDF drum staff is engraved under a percussion clef and the
    /// importer already remaps its noteheads to GM drumset key numbers.
    /// `markPercussionStaves` promotes that per-measure detection to the
    /// part/staff/instrument level so the part reads as a real drum kit.
    struct PDFImporterDrumStaffTests {
        private static func staff(clef: String) -> SheetMusicCore.Staff {
            SheetMusicCore.Staff(measures: [
                Measure(voices: [Voice(elements: [.clef(Clef(concertClefType: clef))])]),
            ])
        }

        private static func part(id: String, clef: String) -> Part {
            Part(id: id, instrument: Instrument(id: "voice"), staves: [staff(clef: clef)])
        }

        @Test func percussionStaffPromotedToDrumset() {
            var parts = [Self.part(id: "P1", clef: "PERCUSSION")]
            PDFImporter.markPercussionStaves(&parts)
            let drum = parts[0]
            #expect(drum.staves[0].group == "percussion")
            #expect(drum.staves[0].defaultClefType == "PERC")
            #expect(drum.instrument.useDrumset)
            #expect(drum.instrument.id == "drumset")
            #expect(!drum.instrument.drumLineMap.isEmpty)
        }

        @Test func pitchedStaffLeftUntouched() {
            var parts = [Self.part(id: "P1", clef: "G")]
            PDFImporter.markPercussionStaves(&parts)
            let pitched = parts[0]
            #expect(pitched.staves[0].group == "pitched")
            #expect(!pitched.instrument.useDrumset)
            #expect(pitched.instrument.id == "voice")
            #expect(pitched.instrument.drumLineMap.isEmpty)
        }

        @Test func drumLineMapMirrorsDecoderPitches() {
            // Every GM drum pitch percussionMidi can emit must have a line,
            // so a decoded drum note re-renders on the line it came from.
            let decoderPitches = [36, 37, 38, 42, 43, 44, 45, 46, 47, 49, 50, 51, 55]
            for pitch in decoderPitches {
                #expect(PDFImporter.defaultDrumLineMap[pitch] != nil)
            }
        }
    }
#endif
