#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    @Suite("InstrumentChange layout")
    struct InstrumentChangeLayoutTests {
        /// Eager Apple FontMetricsProvider install — required by any test
        /// that hits `LayoutEngine.layout(...)` directly. See TestSupport.
        private let _installApple = TestSupport.installApple

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

        @Test("a visible change emits one instrumentChange-styled text")
        func emitsElement() throws {
            let url = try #require(
                Bundle.module.url(
                    forResource: "instrument-change", withExtension: "mscx",
                ),
            )
            let data = try Data(contentsOf: url)
            let score = try MSCXParser.parse(data)
            let document = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 800,
            )
            let texts = document.systems
                .flatMap(\.measures)
                .flatMap(\.elements)
                .compactMap { element -> (String, TextStyleType)? in
                    guard case let .staffText(text, _, _, style) = element
                    else { return nil }
                    return (text, style)
                }
            #expect(texts.contains { $0.0 == "to Accordion" && $0.1 == .instrumentChange })
        }

        @Test("an invisible change is not drawn by default")
        func invisibleChangeIsNotDrawnByDefault() throws {
            let url = try #require(
                Bundle.module.url(
                    forResource: "instrument-change", withExtension: "mscx",
                ),
            )
            var score = try MSCXParser.parse(Data(contentsOf: url))
            // Flip the fixture's single change to invisible.
            for measureIndex in score.systemMeasures.indices {
                for elementIndex in score.systemMeasures[measureIndex].elements.indices {
                    guard case var .instrumentChange(change) =
                        score.systemMeasures[measureIndex].elements[elementIndex].element
                    else { continue }
                    change.visible = false
                    score.systemMeasures[measureIndex].elements[elementIndex].element =
                        .instrumentChange(change)
                }
            }
            let document = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 800,
            )
            let drawn = document.systems
                .flatMap(\.measures)
                .flatMap(\.elements)
                .contains { element in
                    guard case let .staffText(text, _, _, _) = element
                    else { return false }
                    return text == "to Accordion"
                }
            #expect(drawn == false)
        }
    }
#endif
