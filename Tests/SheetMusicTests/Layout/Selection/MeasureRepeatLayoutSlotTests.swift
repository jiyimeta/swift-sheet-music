#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
    /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// The `%` sign carries its slot, which selection names as the bar's rest (`LayoutElement.restSlot`): a click on it
/// selects that rest, and a later bar of a group draws no rest of its own under the sign.
@Suite("Measure repeat layout as a slot")
struct MeasureRepeatLayoutSlotTests {
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    /// `parityFixture()` with a group on the cello from bar 1; `strayRest` adds a whole rest behind the sign, the shape
    /// found in a user's file.
    private static func laidOut(numMeasures: Int, strayRest: Bool = false) throws -> LayoutDocument {
        _ = TestSupport.installFontMetrics
        var score = EditingFixtures.parityFixture()
        _ = try SetMeasureRepeat(at: MeasureRef(measureIndex: 1), staff: cello, numMeasures: numMeasures)
            .apply(to: &score)
        if strayRest {
            score.parts.updateValue(at: 1) { part in
                part.staves.updateValue(at: 0) { staff in
                    let elements = staff.measures[1].voices[0].elements.values + [.rest(duration: .whole)]
                    staff.measures[1].voices[0] = Voice(elements: elements)
                }
            }
        }
        return LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 4000)
    }

    private static func celloRests(in document: LayoutDocument, measure: Int) -> [RestID] {
        document.systems.flatMap(\.measures)
            .filter { $0.measureIndex == measure }
            .flatMap(\.elements)
            .compactMap { element -> RestID? in
                guard case let .rest(_, _, _, restID, _) = element, restID.staff == cello else { return nil }
                return restID
            }
    }

    @Test("a click on the sign selects its slot as a rest")
    func clickSelectsTheSign() throws {
        guard #available(macOS 15.0, *) else { return }
        let document = try Self.laidOut(numMeasures: 1)
        var found: (point: CGPoint, restID: RestID)?
        for system in document.systems {
            for measure in system.measures {
                for element in measure.elements {
                    guard case let .measureRepeat(_, origin, restID?) = element else { continue }
                    found = (
                        CGPoint(
                            x: system.origin.x + measure.origin.x + origin.x,
                            y: system.origin.y + measure.origin.y + origin.y,
                        ),
                        restID,
                    )
                }
            }
        }
        let sign = try #require(found)
        #expect(sign.restID.staff == Self.cello)
        #expect(sign.restID.measureIndex == 1)
        #expect(ScoreHitTester(document: document).hitTest(at: sign.point) == .rest(sign.restID))
    }

    @Test("a later bar of a group draws no rest under the sign")
    func continuationBarDrawsNoRest() throws {
        let document = try Self.laidOut(numMeasures: 2)
        #expect(Self.celloRests(in: document, measure: 2).isEmpty)
    }

    @Test("a bar holding the sign beside a stray rest draws the sign alone")
    func signBesideStrayRestDrawsAlone() throws {
        let document = try Self.laidOut(numMeasures: 1, strayRest: true)
        #expect(Self.celloRests(in: document, measure: 1).isEmpty)
        let signs = document.systems.flatMap(\.measures)
            .filter { $0.measureIndex == 1 }
            .flatMap(\.elements)
            .filter { if case .measureRepeat = $0 { true } else { false } }
        #expect(signs.count == 1)
    }
}
