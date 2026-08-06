#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    @Suite("InstrumentChange layout")
    struct InstrumentChangeLayoutTests {
        @Test("instrumentChange is Edwin 10pt bold, unframed")
        func styleDefaults() {
            let defaults = TextStyleType.instrumentChange.museScoreDefault
            #expect(defaults.face == "Edwin")
            #expect(defaults.size == 10)
            #expect(defaults.style == [.bold])
            #expect(defaults.frameType == .none)
            #expect(defaults.spatiumDependent == true)
        }

        @Test("staffText carries a style, and the skyline routes each one")
        func shapeKindPerStyle() {
            let origin = CGPoint(x: 10, y: 20)
            let staff = LayoutElement.staffText(
                text: "pizz.", origin: origin, color: nil, style: .staffText,
            )
            let system = LayoutElement.staffText(
                text: "Swing", origin: origin, color: nil, style: .systemText,
            )
            let change = LayoutElement.staffText(
                text: "to Accordion", origin: origin, color: nil,
                style: .instrumentChange,
            )
            #expect(LayoutElementShape.kind(of: staff) == .staffText)
            #expect(LayoutElementShape.kind(of: system) == .systemText)
            // Instrument change reuses the staffText skyline slot: it is
            // staff-attached text with the same autoplace behaviour.
            #expect(LayoutElementShape.kind(of: change) == .staffText)
        }

        @Test("vertical translate preserves the style")
        func translatePreservesStyle() {
            let element = LayoutElement.staffText(
                text: "to Accordion",
                origin: CGPoint(x: 0, y: 0),
                color: nil,
                style: .instrumentChange,
            )
            let moved = LayoutEngine.translate(element: element, dy: 12)
            guard case let .staffText(_, origin, _, style) = moved else {
                Issue.record("expected .staffText")
                return
            }
            #expect(style == .instrumentChange)
            #expect(origin.y == 12)
        }
    }
#endif
