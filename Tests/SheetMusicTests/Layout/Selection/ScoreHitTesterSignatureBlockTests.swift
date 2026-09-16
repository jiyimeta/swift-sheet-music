import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
    /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// A signature is ONE target, not a row of separate glyphs.
///
/// A four-sharp key signature draws four accidentals on four different staff lines, and testing each one's ink
/// separately left the spaces between them dead — the run reads as one mark and is engraved as one column, but a
/// click aimed at the middle of it fell straight through to whatever was behind. A meter has the same problem
/// vertically: two digits with a gap between the rows.
@Suite("ScoreHitTester — signatures are one block")
struct ScoreHitTesterSignatureBlockTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// sp = 10, and the fixture puts the element at document (130, 130).
    private static let documentOrigin = CGPoint(x: 130, y: 130)
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    @available(macOS 15.0, iOS 16.0, *)
    private func tester(_ element: LayoutElement) -> ScoreHitTester {
        ScoreHitTester(document: ElementHitFixtures.document([element]))
    }

    /// Every point inside the signature's own envelope hits it — including the ones between two accidentals,
    /// which is what the union is for. Sampled across the box rather than at one lucky coordinate.
    @Test("every point inside a key signature's envelope hits it")
    func keySignatureEnvelope() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.keySignature(
            sharps: 4, flats: 0, clef: .treble, origin: ElementHitFixtures.origin,
            identity: .keySignature(measureIndex: 0, staff: Self.staff),
        )
        let tester = tester(element)
        let target = ScoreHitTarget.keySignature(measureIndex: 0, staff: Self.staff)
        let box = try #require(tester.elementHitRect(for: target))

        // A 5x5 lattice over the envelope, inset a hair so the samples are strictly inside it.
        for column in 0 ... 4 {
            for row in 0 ... 4 {
                let point = CGPoint(
                    x: box.minX + 0.5 + (box.width - 1) * CGFloat(column) / 4,
                    y: box.minY + 0.5 + (box.height - 1) * CGFloat(row) / 4,
                )
                #expect(
                    tester.hitTest(at: point) == target,
                    Comment(rawValue: "(\(point.x), \(point.y))"),
                )
            }
        }
    }

    @Test("every point inside a meter's envelope hits it")
    func timeSignatureEnvelope() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.timeSignature(
            numerator: 12, denominator: 8, origin: ElementHitFixtures.origin,
            identity: .timeSignature(measureIndex: 0, staff: Self.staff),
        )
        let tester = tester(element)
        let target = ScoreHitTarget.timeSignature(measureIndex: 0, staff: Self.staff)
        let box = try #require(tester.elementHitRect(for: target))

        // The middle of the box is the gap BETWEEN the two digit rows — the point the old per-glyph test missed.
        #expect(tester.hitTest(at: CGPoint(x: box.midX, y: box.midY)) == target)
        #expect(tester.hitTest(at: CGPoint(x: box.minX + 0.5, y: box.minY + 0.5)) == target)
        #expect(tester.hitTest(at: CGPoint(x: box.maxX - 0.5, y: box.maxY - 0.5)) == target)
    }

    /// The envelope is not unbounded: past the ink plus its half-space of reach, the click means nothing. A
    /// signature sits in a dense header row, so what it does NOT claim matters as much as what it does.
    @Test("a point well clear of the signature misses it")
    func envelopeEnds() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.keySignature(
            sharps: 4, flats: 0, clef: .treble, origin: ElementHitFixtures.origin,
            identity: .keySignature(measureIndex: 0, staff: Self.staff),
        )
        let tester = tester(element)
        let box = try #require(tester.elementHitRect(for: .keySignature(measureIndex: 0, staff: Self.staff)))
        let sp = ElementHitFixtures.metrics.sp

        #expect(tester.hitTest(at: CGPoint(x: box.minX - sp * 2, y: box.midY)) == nil)
        #expect(tester.hitTest(at: CGPoint(x: box.maxX + sp * 2, y: box.midY)) == nil)
        #expect(tester.hitTest(at: CGPoint(x: box.midX, y: box.minY - sp * 2)) == nil)
    }

    /// **The highlight box is the ink, and the tolerance is not part of it.** A selection's frame is what the
    /// mark occupies; the reach is a click affordance. The two are allowed to differ and do.
    @Test("the highlight rect excludes the click tolerance")
    func highlightExcludesTolerance() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let element = LayoutElement.keySignature(
            sharps: 4, flats: 0, clef: .treble, origin: ElementHitFixtures.origin,
            identity: .keySignature(measureIndex: 0, staff: Self.staff),
        )
        let tester = tester(element)
        let box = try #require(tester.elementHitRect(for: .keySignature(measureIndex: 0, staff: Self.staff)))
        let sp = ElementHitFixtures.metrics.sp

        // Just outside the highlight box, but inside the reach — a hit, yet not part of the frame.
        let justOutside = CGPoint(x: box.minX - sp * 0.25, y: box.midY)
        #expect(!box.contains(justOutside))
        #expect(tester.hitTest(at: justOutside) == .keySignature(measureIndex: 0, staff: Self.staff))
    }
}
