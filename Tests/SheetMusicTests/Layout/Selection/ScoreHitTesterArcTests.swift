import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
    /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope alias here would collide
    /// with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

@Suite("Arc hits use rendered centerlines")
struct ScoreHitTesterArcTests {
    private static let identity = ScoreElementID.tie(
        start: ElementHitFixtures.noteID,
        end: NoteID(
            staff: ElementHitFixtures.anchor.staff,
            measureIndex: 1,
            voiceIndex: 0,
            elementIndex: 0,
            noteIndexInChord: 0,
        ),
    )

    @Test("Cubic apex, tolerance, empty interior and lens bounds", arguments: [true, false])
    func cubicCenterline(above: Bool) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = Self.arc(above: above)
        let tester = ScoreHitTester(document: ElementHitFixtures.document([element]))
        let target = ScoreHitTarget(elementID: Self.identity)
        let sign: CGFloat = above ? -1 : 1
        // sp=10, length=10 sp, shoulder=0.3+0.3*sqrt(9)=1.2 sp.
        // Controls (0,-6),(20,-18),(80,-18),(100,-6); midpoint (50,-15).
        for distance in [CGFloat(0), 6, 6.9] {
            #expect(tester.hitTest(at: CGPoint(x: 100, y: 50 + sign * (15 + distance))) == target)
        }
        for distance in [CGFloat(7.1), 8] {
            #expect(tester.hitTest(at: CGPoint(x: 100, y: 50 + sign * (15 + distance))) == nil)
        }
        // Inside the curve's bounding box, but 8.9 points from its apex and far from its tips.
        #expect(tester.hitTest(at: CGPoint(x: 100, y: 50 + sign * 6.1)) == nil)
        #expect(tester.hitTest(at: CGPoint(x: 100, y: 50 + sign * 2)) == nil)
        let box = try #require(tester.elementHitRect(for: target))
        #expect(box.contains(CGPoint(x: 100, y: 50 + sign * 6.1)))
        // Lens controls shift by 1.5; the peak shifts by (3/8+3/8)*1.5=1.125.
        #expect(box.minX == 50)
        #expect(box.width == 100)
        #expect(abs(box.minY - (above ? 33.875 : 56)) < 0.000001)
        #expect(abs(box.maxY - (above ? 44 : 66.125)) < 0.000001)
    }

    @Test("Standalone quadratic slur uses its voice identity and stroke bounds")
    func standaloneSlur() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.spannerSegment(
            kind: .slur, fromOrigin: .zero, toOrigin: CGPoint(x: 100, y: 0),
            continuesLeft: false, continuesRight: true, text: "", anchor: ElementHitFixtures.anchor,
        )
        let target = ScoreHitTarget.slur(.voice(ElementHitFixtures.anchor))
        let tester = ScoreHitTester(document: ElementHitFixtures.document([], spanners: [element]))
        // Quadratic controls (0,0),(50,-20),(100,0): midpoint (50,-10).
        // System base is (30,40), so document apex is (80,30).
        for y in [CGFloat(30), 24, 23.1] {
            #expect(tester.hitTest(at: CGPoint(x: 80, y: y)) == target)
        }
        for y in [CGFloat(22.9), 22, 39] {
            #expect(tester.hitTest(at: CGPoint(x: 80, y: y)) == nil)
        }
        let box = try #require(tester.elementHitRect(for: target))
        // Stroke=0.15*10=1.5; half-width 0.75 expands the centerline extrema.
        #expect(box == CGRect(x: 29.25, y: 29.25, width: 101.5, height: 11.5))
    }

    @Test("System and measure bases are applied exactly once")
    func coordinateBases() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let target = ScoreHitTarget(elementID: Self.identity)
        let measure = ScoreHitTester(document: ElementHitFixtures.document([Self.arc()]))
        let system = ScoreHitTester(document: ElementHitFixtures.document([], spanners: [Self.arc()]))
        #expect(measure.hitTest(at: CGPoint(x: 100, y: 35)) == target)
        #expect(system.hitTest(at: CGPoint(x: 80, y: 25)) == target)
        #expect(system.hitTest(at: CGPoint(x: 100, y: 35)) == nil)
    }

    @Test("Split BEGIN and END segments hit the same tie; their highlight gap does not hit")
    func splitTie() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let systems: [LayoutSystem] = [Self.system(y: 0), Self.system(y: 200)]
        let pairs: [LayoutEngine.TiePair] = [.init(
            staff: 0, fromOrigin: CGPoint(x: 0, y: 50), toOrigin: CGPoint(x: 40, y: 250),
            above: true, identity: Self.identity,
        )]
        let attached = LayoutEngine.attachArcs(to: systems, pairs: pairs, metrics: ElementHitFixtures.metrics)
        let tester = ScoreHitTester(document: LayoutDocument(
            size: .init(width: 102, height: 300), systems: attached, metrics: ElementHitFixtures.metrics,
        ))
        let target = ScoreHitTarget(elementID: Self.identity)
        #expect(attached.flatMap(\.spanners).map(\.elementID) == [Self.identity, Self.identity])
        // BEGIN: width-2=100, midpoint (50,35). END: firstContent=0,
        // start=min(max(-5,40-40),40-10)=0, length=4 sp.
        // END shoulder=3+3*sqrt(3), apex Y=250-6-3/4*shoulder.
        #expect(tester.hitTest(at: CGPoint(x: 50, y: 35)) == target)
        #expect(tester.hitTest(at: CGPoint(x: 20, y: 241.75 - 2.25 * CGFloat(3).squareRoot())) == target)
        let gap = CGPoint(x: 20, y: 150)
        #expect(try #require(tester.elementHitRect(for: target)).contains(gap))
        #expect(tester.hitTest(at: gap) == nil)
    }

    @Test("Missing identities do not hit, and overlapping arcs keep emission order")
    func identityAndOrder() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let unaddressed = LayoutElement.tieArc(fromOrigin: .zero, toOrigin: CGPoint(x: 100, y: 0), above: true)
        let point = CGPoint(x: 100, y: 35)
        #expect(ScoreHitTester(document: ElementHitFixtures.document([unaddressed])).hitTest(at: point) == nil)
        let slur = LayoutElement.tieArc(
            fromOrigin: .zero, toOrigin: CGPoint(x: 100, y: 0), above: true,
            identity: .slur(.chord(anchor: ElementHitFixtures.anchor, ordinal: 2)),
        )
        #expect(ScoreHitTester(document: ElementHitFixtures.document([Self.arc(), slur])).hitTest(at: point)
            == ScoreHitTarget(elementID: Self.identity))
        #expect(ScoreHitTester(document: ElementHitFixtures.document([slur, Self.arc()])).hitTest(at: point)
            == .slur(.chord(anchor: ElementHitFixtures.anchor, ordinal: 2)))
    }

    @Test("Degenerate and steep curves retain finite, bounded distances")
    func degenerateAndSteep() {
        let point = CGPoint(x: 3, y: 4)
        let degenerate = ArcBezier(points: [point, point, point, point])
        #expect(degenerate.distance(to: point, accuracy: 0.01).value == 0)
        #expect(degenerate.distance(to: CGPoint(x: 11, y: 4), accuracy: 0.01).value == 8)
        let steep = ArcBezier(points: [
            .zero, CGPoint(x: 0, y: 100), CGPoint(x: 10, y: 200), CGPoint(x: 10, y: 300),
        ])
        // Cubic midpoint weights 1/8,3/8,3/8,1/8 give (5,150).
        let result = steep.distance(to: CGPoint(x: 5, y: 150), accuracy: 0.01)
        #expect(result.value.isFinite)
        #expect(result.value < 0.01)
        #expect(result.errorBound <= 0.01)
        // A straight vertical curve also checks the linear derivative case in extrema().
        #expect(steep.bounds == CGRect(x: 0, y: 0, width: 10, height: 300))
    }

    @Test("A 2000-sp arc stays below the declared distance error budget")
    func longCurveErrorBound() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Length 2000 sp clamps shoulder to 2 sp: controls at y=-6,-26,-26,-6.
        // Apex y = -6/4 - 26*3/4 = -21, and the query is exactly 6 points above it.
        let curve = ArcBezier(points: [
            CGPoint(x: 0, y: -6), CGPoint(x: 4000, y: -26),
            CGPoint(x: 16000, y: -26), CGPoint(x: 20000, y: -6),
        ])
        let result = curve.distance(to: CGPoint(x: 10000, y: -27), accuracy: 0.01)
        #expect(result.errorBound <= 0.01) // 0.001 sp, fifty times below 0.05 sp.
        #expect(abs(result.value - 6) <= result.errorBound + 0.00000001)
        #expect(result.segmentCount > 1)
        let element = LayoutElement.tieArc(
            fromOrigin: .zero, toOrigin: CGPoint(x: 20000, y: 0), above: true, identity: Self.identity,
        )
        let tester = ScoreHitTester(document: ElementHitFixtures.document([element]))
        #expect(tester.hitTest(at: CGPoint(x: 10050, y: 29)) == ScoreHitTarget(elementID: Self.identity))
        #expect(tester.hitTest(at: CGPoint(x: 10050, y: 23)) == ScoreHitTarget(elementID: Self.identity))
        #expect(tester.hitTest(at: CGPoint(x: 10050, y: 21)) == nil)
        // At an intentionally exhausted cap, report the larger bound instead of claiming accuracy.
        let capped = curve.distance(to: CGPoint(x: 10000, y: -27), accuracy: 0.01, depth: 0)
        #expect(capped.errorBound > 0.01)
        #expect(abs(capped.value - 6) <= capped.errorBound)
    }

    private static func arc(above: Bool = true) -> LayoutElement {
        .tieArc(fromOrigin: .zero, toOrigin: CGPoint(x: 100, y: 0), above: above, identity: identity)
    }

    private static func system(y: CGFloat) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(x: 0, y: y), size: .init(width: 102, height: 100), measures: [],
            staffOrigins: [], partLabels: [], spanners: [], sp: 10,
        )
    }
}
