#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
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
