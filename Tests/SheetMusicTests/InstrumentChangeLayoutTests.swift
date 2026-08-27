import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's own CoreGraphics shims also export `CGPoint`
    /// (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor explicitly to
    /// SheetMusicLayout's own definition instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps this file-scoped — a module-scope `typealias CGPoint` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

@Suite("InstrumentChange layout")
struct InstrumentChangeLayoutTests {
    /// Eager FontMetricsProvider install — required by any test that hits
    /// `LayoutEngine.layout(...)` directly. See TestSupport.
    private let _installFontMetrics = TestSupport.installFontMetrics

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

    @Test("a visible change is one spatium above where a staff text on the same staff would land")
    func emitsElement() throws {
        let url = try #require(
            TestResources.url(
                forResource: "instrument-change", withExtension: "mscx",
            ),
        )
        let data = try Data(contentsOf: url)
        var score = try MSCXParser.parse(data)
        let anchorStaff = score.systemMeasures[2].elements
            .first { positioned in
                if case .instrumentChange = positioned.element { return true }
                return false
            }?.originalStaff
        // Add a "pizz."-style staff text on the SAME staff but at a
        // DIFFERENT tick (measure 0's downbeat, vs. the fixture's
        // instrument change on measure 2) so its bounding box never
        // overlaps the instrument change's in X — same-kind text
        // items that DO overlap get pushed apart by the skyline
        // autoplace pass (`AutoplaceRules.shouldIgnoreEachOther`:
        // same-kind text collides), which would corrupt a same-tick
        // comparison. Staying on the same staff keeps both elements
        // under the identical per-staff Y translate applied when
        // they're lifted into system space, so their DIFFERENCE below
        // is exact regardless of that (unrelated) transform.
        score.systemMeasures[0].elements.append(
            PositionedSystemElement(
                position: .start,
                element: .staffText(StaffText(text: "pizz.")),
                originalStaff: anchorStaff,
            ),
        )
        let document = LayoutEngine.layout(
            score: score, options: ScoreViewOptions(), availableWidth: 800,
        )
        let texts = document.systems
            .flatMap(\.measures)
            .flatMap(\.elements)
            .compactMap { element -> (text: String, origin: CGPoint, style: TextStyleType)? in
                guard case let .staffText(text, origin, _, style) = element
                else { return nil }
                return (text, origin, style)
            }
        #expect(texts.contains { $0.text == "to Accordion" && $0.style == .instrumentChange })
        let change = try #require(
            texts.first { $0.text == "to Accordion" && $0.style == .instrumentChange },
        )
        let pizz = try #require(texts.first { $0.text == "pizz." && $0.style == .staffText })
        // MuseScore's `instrumentChangePosAbove` is (0, -2.0) spatium
        // from the staff top (styledef.cpp:1622) — one spatium HIGHER
        // than the `-3 sp` used for plain staff text — so the
        // instruction clears a "pizz."-style directive anchored at
        // the same tick. This pins that exact one-spatium gap against
        // the SAME `StaffMetrics` this layout call produced, rather
        // than a hardcoded literal, so it survives a future change to
        // the base staff size. A regression that silently reverts the
        // `- 4` back to staff text's `- 3` collapses this gap to
        // zero and fails this line.
        #expect(pizz.origin.y - change.origin.y == document.metrics.sp)
    }

    @Test("an invisible change is not drawn by default")
    func invisibleChangeIsNotDrawnByDefault() throws {
        let url = try #require(
            TestResources.url(
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
