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
                transposeSemitones: 0,
            )
            let decoded = try LayoutOptionsCodec.decode(wire.encodeToData())
            #expect(decoded.staffSize == 18.5)
            #expect(decoded.mode == .page)
            #expect(decoded.showsInvisibleElements == 1)
            #expect(decoded.hiddenStaffAddresses == [StaffAddress(partIndex: 1, staffIndexInPart: 0)])
            #expect(decoded.clefOverrideMap == [StaffAddress(partIndex: 0, staffIndexInPart: 1): "F8va"])
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
            )
            let decoded = try LayoutOptionsCodec.decode(wire.encodeToData())
            #expect(decoded.mode == .horizontal)
        }
    }
#endif
