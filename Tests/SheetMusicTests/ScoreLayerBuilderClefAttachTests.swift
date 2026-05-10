#if os(macOS)
    import CoreGraphics
    import QuartzCore
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    @Suite("ScoreLayerBuilder — clef attach")
    struct ScoreLayerBuilderClefAttachTests {
        @available(macOS 15.0, iOS 16.0, *)
        @MainActor
        @Test("staff-default clef layer is attached to its ScoreItemID")
        func staffDefaultClefAttached() throws {
            _ = BravuraFont.register
            let url = try #require(
                Bundle.module.url(
                    forResource: "multiPartMixedStaves",
                    withExtension: "mscx"
                )
            )
            let score = try MSCXParser.parse(contentsOf: url)
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(
                    staffSize: 18, systemGap: 16,
                    wrapToViewWidth: false
                ),
                availableWidth: 2000
            )
            let system = try #require(doc.systems.first)
            let result = ScoreLayerBuilder.buildSystemWithItems(
                system, metrics: doc.metrics
            )

            let attachedClefAnchors = result.items.keys
                .compactMap { id -> ClefAnchor? in
                    if case let .clef(anchor) = id { return anchor }
                    return nil
                }
            let staffZero = StaffAddress(
                partIndex: 0, staffIndexInPart: 0
            )
            #expect(
                attachedClefAnchors.contains(.staffDefault(staffZero)),
                """
                expected the staff-default clef on staff (0,0) to be \
                attached for selection re-tinting; got \
                \(attachedClefAnchors)
                """
            )

            // The attached layer must be a real glyph layer (filled
            // path) so that `applySelection` can re-tint its
            // `fillColor` — sentinels with neither fill nor stroke
            // would silently no-op.
            let layers = try #require(
                result.items[.clef(.staffDefault(staffZero))]
            )
            #expect(!layers.isEmpty)
            let glyphLike = layers.first { layer in
                layer.fillColor != nil || layer.strokeColor != nil
            }
            #expect(
                glyphLike != nil,
                "attached clef layer has neither fill nor stroke color"
            )
        }
    }
#endif
