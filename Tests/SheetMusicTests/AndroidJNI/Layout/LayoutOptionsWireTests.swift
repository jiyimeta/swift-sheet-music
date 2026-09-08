#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicLayout
    import Testing
    import Wirelet

    struct LayoutOptionsWireTests {
        @Test func roundTripsAllFields() throws {
            let wire = LayoutOptionsWire(
                layoutMode: 2,
                staffSize: 18.5,
                honorLayoutBreaks: 1,
                collapseMultiMeasureRests: 0,
                showsInvisibleElements: 1,
                hiddenStaves: [HiddenStaffWire(partIndex: 1, staffIndexInPart: 0)],
                clefOverrides: [ClefOverrideWire(partIndex: 0, staffIndexInPart: 1, rawType: "F8va")],
                transposeSemitones: -3,
                showsLyrics: 0,
                breakPolicyRaw: 2,
                multiMeasureRestMinimum: 5,
                measureNumberInterval: 4,
                systemGapPoints: 41.5,
                includeTitleFrameRaw: 1,
                breakIndicatorVisibilityRaw: 2,
                graceNoteMag: 0.55,
                smallNoteMag: 0.65,
                spacing: EngravingSpacingWire(
                    minNoteDistance: 0.3,
                    spacePerQuarter: 2.1,
                    systemStretch: 1.9,
                    marginTop: 1.1,
                    marginLeading: 2.2,
                    marginBottom: 3.3,
                    marginTrailing: 4.4,
                    firstSystemIndent: 5.5,
                    continuationSystemIndent: 3.6,
                    minStaffGap: 1.25,
                    systemVerticalPadding: 2.7,
                ),
            )
            let decoded = try LayoutOptionsCodec.decode(wire.encodeToData())
            #expect(decoded.staffSize == 18.5)
            #expect(decoded.mode == .page)
            #expect(decoded.showsInvisibleElements == 1)
            #expect(decoded.hiddenStaffAddresses == [StaffAddress(partIndex: 1, staffIndexInPart: 0)])
            #expect(decoded.clefOverrideMap == [StaffAddress(partIndex: 0, staffIndexInPart: 1): "F8va"])
            #expect(decoded.transposeDelta == -3)
            // The field is carried in the SAME blob as the transpose, so a
            // fixture that set both to their default would not tell a dropped
            // tag from a defaulted one.
            #expect(decoded.lyricsVisible == false)
            // Every appended field, each set away from its own default for the same reason.
            #expect(decoded.breakPolicyRaw == 2)
            #expect(decoded.multiMeasureRestMinimum == 5)
            #expect(decoded.measureNumberInterval == 4)
            #expect(decoded.systemGapPoints == 41.5)
            #expect(decoded.includeTitleFrameRaw == 1)
            #expect(decoded.breakIndicatorVisibilityRaw == 2)
            #expect(decoded.graceNoteMag == 0.55)
            #expect(decoded.smallNoteMag == 0.65)
            let spacing = try #require(decoded.spacing)
            #expect(spacing.minNoteDistance == 0.3)
            #expect(spacing.spacePerQuarter == 2.1)
            #expect(spacing.systemStretch == 1.9)
            #expect(spacing.marginTop == 1.1)
            #expect(spacing.marginLeading == 2.2)
            #expect(spacing.marginBottom == 3.3)
            #expect(spacing.marginTrailing == 4.4)
            #expect(spacing.firstSystemIndent == 5.5)
            #expect(spacing.continuationSystemIndent == 3.6)
            #expect(spacing.minStaffGap == 1.25)
            #expect(spacing.systemVerticalPadding == 2.7)
        }

        @Test func absentSpacingDecodesForBackwardCompatibility() throws {
            let wire = LayoutOptionsWire(
                layoutMode: 0,
                staffSize: 28,
                honorLayoutBreaks: 1,
                collapseMultiMeasureRests: 0,
                showsInvisibleElements: 0,
                hiddenStaves: [],
                clefOverrides: [],
                transposeSemitones: 0,
                showsLyrics: 1,
                spacing: nil,
            )
            let decoded = try LayoutOptionsCodec.decode(wire.encodeToData())
            #expect(decoded.spacing == nil)
            #expect(decoded.engravingSpacing == EngravingSpacing.standard)
        }

        /// The NOTATION half of the transpose clamp. It must match the two audio clamps
        /// (`PlaybackEngine.setTranspose`, `AndroidPlaybackEngine.setTranspose`) exactly: past a
        /// disagreement the score sounds in one key and reads in another.
        @Test func transposeDeltaClampsToAnOctaveEitherWay() {
            func delta(_ semitones: Int32) -> Int {
                LayoutOptionsWire(
                    layoutMode: 0, staffSize: 28,
                    honorLayoutBreaks: 1, collapseMultiMeasureRests: 0, showsInvisibleElements: 0,
                    hiddenStaves: [], clefOverrides: [], transposeSemitones: semitones, showsLyrics: 1,
                ).transposeDelta
            }
            #expect(delta(12) == 12)
            #expect(delta(-12) == -12)
            // 8 is the discriminating value: the previous bound pinned it to 7.
            #expect(delta(8) == 8)
            #expect(delta(-8) == -8)
            #expect(delta(13) == 12)
            #expect(delta(-13) == -12)
            // Far outside, to catch a clamp that subtracts rather than pins.
            #expect(delta(400) == 12)
        }

        @Test func lyricsDefaultToVisible() throws {
            let wire = LayoutOptionsWire(
                layoutMode: 0,
                staffSize: 28,
                honorLayoutBreaks: 1,
                collapseMultiMeasureRests: 0,
                showsInvisibleElements: 0,
                hiddenStaves: [],
                clefOverrides: [],
                transposeSemitones: 0,
                showsLyrics: 1,
            )
            let decoded = try LayoutOptionsCodec.decode(wire.encodeToData())
            #expect(decoded.lyricsVisible)
            // `verticalDefault` feeds the legacy no-options compute path, so a
            // 0 there would silently strip lyrics from every caller that never
            // asked about them.
            #expect(LayoutOptionsWire.verticalDefault.lyricsVisible)
        }

        @Test func emptyCollectionsRoundTrip() throws {
            let wire = LayoutOptionsWire(
                layoutMode: 0,
                staffSize: 12.0,
                honorLayoutBreaks: 0,
                collapseMultiMeasureRests: 1,
                showsInvisibleElements: 0,
                hiddenStaves: [],
                clefOverrides: [],
                transposeSemitones: 0,
                showsLyrics: 1,
            )
            let decoded = try LayoutOptionsCodec.decode(wire.encodeToData())
            #expect(decoded.mode == .vertical)
            #expect(decoded.staffSize == 12.0)
            #expect(decoded.hiddenStaffAddresses.isEmpty)
            #expect(decoded.clefOverrideMap.isEmpty)
        }

        @Test func horizontalModeRoundTrip() throws {
            let wire = LayoutOptionsWire(
                layoutMode: 1,
                staffSize: 16.0,
                honorLayoutBreaks: 0,
                collapseMultiMeasureRests: 0,
                showsInvisibleElements: 0,
                hiddenStaves: [],
                clefOverrides: [],
                transposeSemitones: 0,
                showsLyrics: 1,
            )
            let decoded = try LayoutOptionsCodec.decode(wire.encodeToData())
            #expect(decoded.mode == .horizontal)
        }
    }
#endif
