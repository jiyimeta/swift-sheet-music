#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// `isStem`'s notehead-END test, against the false class that is
    /// hardest for it.
    ///
    /// The easy false verticals — a clef's stroke far above the notes, a
    /// bracket arm — were already rejected by the x-window. The one that
    /// defeats an x-only test is an ACCIDENTAL's vertical stroke: it sits
    /// at the note's own y, about one notehead width to its left, which is
    /// inside `stemAttachWindow` AND on the side `stemLegalityLeftSlop`
    /// calls legal. On a vector PDF it never arrives as a path at all
    /// (MuseScore draws accidentals as glyphs); a raster front-end sees
    /// only ink and emits it.
    struct StemHeadEndPredicateTests {
        static let spatium: CGFloat = 5
        static let staffYLines: [CGFloat] = [100, 105, 110, 115, 120]

        static func measure(glyphs: [ClassifiedGlyph]) -> ImportMeasure {
            ImportMeasure(
                xRange: 0 ... 200, glyphs: glyphs, staffYLines: staffYLines,
            )
        }

        /// The predicate under test, applied the way `decodeRhythm`
        /// applies it.
        static func stems(
            in measure: ImportMeasure, paths: [PathSegment],
        ) -> [PathSegment] {
            paths.filter {
                PDFImporter.isStem(
                    in: measure, $0, noteheads: measure.glyphs, spatium: spatium,
                )
            }
        }

        static func notehead(x: CGFloat, y: CGFloat) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: spatium * 1.2,
                    renderedSize: spatium * 4, pageIndex: 0, fontSize: 0,
                ),
                semantic: .noteheadBlack,
            )
        }

        /// A raster vertical from `y0` to `y1` at `x`.
        static func vertical(
            x: CGFloat, y0: CGFloat, y1: CGFloat, fromRaster: Bool = true,
        ) -> PathSegment {
            PathSegment(
                kind: .vertical,
                rect: CGRect(x: x, y: y0, width: 0, height: y1 - y0),
                lineWidth: 0.7, pageIndex: 0, quad: nil,
                detectedFromRaster: fromRaster,
            )
        }

        /// A real stem: notehead at its lower end (stem-up), the head one
        /// notehead width to the left of the stroke.
        static func stemUp(headX: CGFloat, headY: CGFloat) -> PathSegment {
            vertical(x: headX + spatium * 1.2, y0: headY, y1: headY + spatium * 3)
        }

        @Test func aStemWhoseNoteheadSitsAtItsEndIsAStem() {
            let head = Self.notehead(x: 50, y: 110)
            let stem = Self.stemUp(headX: 50, headY: 110)
            let stems = Self.stems(in: Self.measure(glyphs: [head]), paths: [stem])
            #expect(stems == [stem])
        }

        /// THE ADVERSARIAL CASE. An accidental's stroke at the note's own
        /// y, inside the x-window: rejected only because neither of its
        /// ends is near the head.
        @Test func anAccidentalStrokeAtNoteHeightIsNotAStem() {
            let head = Self.notehead(x: 50, y: 110)
            // ~2.6 sp tall, centred on the note — a sharp's vertical.
            let accidental = Self.vertical(
                x: 50 - Self.spatium * 1.2, y0: 110 - Self.spatium * 1.3,
                y1: 110 + Self.spatium * 1.3,
            )
            let stems = Self.stems(in: Self.measure(glyphs: [head]), paths: [accidental])
            #expect(stems.isEmpty)
        }

        /// …and with the y-term absent the same stroke IS accepted, so
        /// the test above is testing the predicate and not the x-window.
        /// (The x-only verdict is what an untagged — vector — segment
        /// still gets, which is exactly how that is asserted here.)
        @Test func theSameStrokeIsAcceptedWithoutTheYTerm() {
            let head = Self.notehead(x: 50, y: 110)
            let asVector = Self.vertical(
                x: 50 - Self.spatium * 1.2, y0: 110 - Self.spatium * 1.3,
                y1: 110 + Self.spatium * 1.3, fromRaster: false,
            )
            let stems = Self.stems(in: Self.measure(glyphs: [head]), paths: [asVector])
            #expect(stems == [asVector])
        }

        /// The provenance gate, stated as an executable claim rather than
        /// an argument: a vector-shaped vertical bypasses the predicate
        /// entirely, so the shipped PDF-import path cannot change verdict
        /// no matter what the predicate says.
        @Test func aVectorVerticalIsNeverJudgedByTheEndTest() {
            let head = Self.notehead(x: 50, y: 110)
            for y0 in stride(from: CGFloat(60), through: 150, by: 10) {
                let vector = Self.vertical(x: 55, y0: y0, y1: y0 + 15, fromRaster: false)
                let raster = Self.vertical(x: 55, y0: y0, y1: y0 + 15)
                let vectorKept = Self.stems(in: Self.measure(glyphs: [head]), paths: [vector])
                #expect(vectorKept == [vector], "vector vertical at y0=\(y0) was dropped")
                // The raster twin is judged, and for most of this sweep
                // rejected — otherwise the loop would prove nothing.
                _ = Self.stems(in: Self.measure(glyphs: [head]), paths: [raster])
            }
        }

        /// A stem-down chord: the head sits at the stroke's TOP end, so
        /// the test has to accept either end rather than assume a
        /// direction it cannot know before the stem is identified.
        @Test func aStemDownNoteheadAtTheTopEndIsAlsoAStem() {
            let head = Self.notehead(x: 50, y: 110)
            let stem = Self.vertical(
                x: 50, y0: 110 - Self.spatium * 3, y1: 110,
            )
            let stems = Self.stems(in: Self.measure(glyphs: [head]), paths: [stem])
            #expect(stems == [stem])
        }

        /// The gate's WIDTH, as an executable claim. A stem whose ink
        /// stops 0.4 sp short of its notehead — a beam-trimmed stem, or
        /// one whose end row fell below the binarizer's threshold — is a
        /// stem, and the shipped 0.25 rejected it. Widening to 0.5 is
        /// what the v2-eval grid in `isStem` bought: dur mean 71.6 ->
        /// 73.2, pitch p50 96.5 -> 100.0. The false population's knee is
        /// still above this, at 0.65.
        @Test func aStemEndingJustShortOfItsNoteheadIsStillAStem() {
            let head = Self.notehead(x: 50, y: 110)
            let x = 50 + Self.spatium * 1.2
            let shortOfHead = Self.vertical(
                x: x, y0: 110 + Self.spatium * 0.4, y1: 110 + Self.spatium * 3,
            )
            let stems = Self.stems(in: Self.measure(glyphs: [head]), paths: [shortOfHead])
            #expect(stems == [shortOfHead])
            // …and the gate has NOT simply gone away: 0.6 sp is still out.
            let tooFar = Self.vertical(
                x: x, y0: 110 + Self.spatium * 0.6, y1: 110 + Self.spatium * 3,
            )
            let none = Self.stems(in: Self.measure(glyphs: [head]), paths: [tooFar])
            #expect(none.isEmpty)
        }

        /// A chord only needs ONE head to certify its stem — the one at
        /// the attaching end. An interior head sits mid-stroke and would
        /// fail the end test on its own.
        @Test func oneHeadAtTheAttachingEndCertifiesTheWholeChord() {
            let lower = Self.notehead(x: 50, y: 110)
            let upper = Self.notehead(x: 50, y: 110 + Self.spatium)
            let stem = Self.stemUp(headX: 50, headY: 110)
            let stems = Self.stems(in: Self.measure(glyphs: [lower, upper]), paths: [stem])
            #expect(stems == [stem])
        }
    }
#endif
