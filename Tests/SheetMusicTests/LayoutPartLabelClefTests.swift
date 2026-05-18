#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    struct LayoutPartLabelClefTests {
        @available(macOS 15.0, iOS 16.0, *)
        @Test func measureContextsKeepPerStaffLabels() throws {
            // The sticky-header context keeps one label per staff so each
            // staff line in the continuous-view pane gets its own name.
            let url = try #require(
                Bundle.module.url(
                    forResource: "multiPartMixedStaves",
                    withExtension: "mscx",
                ),
            )
            let score = try MSCXParser.parse(contentsOf: url)

            let contexts = LayoutEngine.measureContexts(for: score)
            let m0 = try #require(contexts.first)

            // Display order: [Vln1, Vln2, Piano-RH, Piano-LH, Vc].
            #expect(m0.partLabels[0] == "Violin 1")
            #expect(m0.partLabels[1] == "Violin 2")
            #expect(m0.partLabels[2] == "Piano")
            #expect(m0.partLabels[3] == "Piano")
            #expect(m0.partLabels[4] == "Violoncello")

            // Default clef chain expected: G, G, G, F, F.
            #expect(m0.clefRawTypes == ["G", "G", "G", "F", "F"])
        }

        @available(macOS 15.0, iOS 16.0, *)
        @Test func systemPartLabelsCollapseToOnePerPart() throws {
            // The system's left-edge labels collapse to one entry per
            // Part. Piano (multi-staff) gets a single label centered
            // between its two staves.
            let url = try #require(
                Bundle.module.url(
                    forResource: "multiPartMixedStaves",
                    withExtension: "mscx",
                ),
            )
            let score = try MSCXParser.parse(contentsOf: url)
            let doc = LayoutEngine.layout(
                score: score,
                options: .init(),
                availableWidth: 800,
            )
            let system = try #require(doc.systems.first)

            // 4 parts: Vln1, Vln2, Piano (1 entry, 2 staves), Vc.
            #expect(system.partLabels.count == 4)
            #expect(system.partLabels[0].text == "Violin 1")
            #expect(system.partLabels[1].text == "Violin 2")
            #expect(system.partLabels[2].text == "Piano")
            #expect(system.partLabels[3].text == "Violoncello")

            // Piano label sits at the midpoint between staff 2's top and
            // staff 3's bottom (within ±0.5 sp).
            let metrics = doc.metrics
            let pianoTopY = system.staffOrigins[2].y
            let pianoBottomY = system.staffOrigins[3].y + metrics.staffHeight
            let expectedY = (pianoTopY + pianoBottomY) / 2
            let actualY: CGFloat = system.partLabels[2].origin.y
            let diff: CGFloat = (actualY - expectedY).magnitude
            #expect(diff <= metrics.sp * 0.5)
        }
    }
#endif
