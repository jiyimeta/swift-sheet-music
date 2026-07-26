#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct BravuraExemplarsTests {
        @Test func buildsExemplarForEveryClassifiableSemantic() {
            let all = BravuraExemplars.all
            #expect(all.count >= 40)
            let semantics = Set(all.map(\.semantic))
            for expected: SMuFLSemantic in [
                .clefG, .clefF, .clefC, .clefPercussion, .brace,
                .noteheadBlack, .noteheadHalf, .noteheadWhole,
                .accidentalSharp, .accidentalFlat, .accidentalNatural,
                .rest(.quarter), .rest(.eighth), .rest(.sixteenth),
                .flag8thUp, .flag16thUp,
                .timeSignatureDigit(4),
            ] {
                #expect(semantics.contains(expected))
            }
        }

        @Test func exemplarsAreMutuallyDistinct() {
            let all = BravuraExemplars.all
            // No two DIFFERENT semantics may produce an identical descriptor.
            for i in 0 ..< all.count {
                for j in (i + 1) ..< all.count where all[i].semantic != all[j].semantic {
                    #expect(all[i].descriptor != all[j].descriptor)
                }
            }
        }

        /// Self-match is trivially distance 0, so asserting it alone proves
        /// nothing. What matters for nearest-neighbor classification is the
        /// MARGIN: how far the nearest OTHER exemplar sits. A probe glyph from
        /// an unseen font lands somewhere near its true exemplar; if a
        /// different exemplar is almost as close, the classification flips.
        ///
        /// Task 10 measured `d(rest8th, rest16th) = 0.3312` against
        /// `d(rest8th, noteheadBlack) = 0.3622` on real Bravura outlines — a
        /// margin of only 0.031 on a [0, 1] scale. That is the fragility this
        /// table exists to quantify across the whole label set.
        @Test func reportsNearestOtherExemplarMargins() {
            let all = BravuraExemplars.all
            var rows: [(String, String, Double)] = []
            for e in all {
                var nearestOther: (semantic: SMuFLSemantic, d: Double)?
                for c in all where c.semantic != e.semantic {
                    let d = e.descriptor.distance(to: c.descriptor)
                    if d < (nearestOther?.d ?? .infinity) {
                        nearestOther = (c.semantic, d)
                    }
                }
                guard let n = nearestOther else { continue }
                rows.append(("\(e.semantic)", "\(n.semantic)", n.d))
                // Self must still be strictly nearest than any other.
                #expect(n.d > 0, "\(e.semantic) collides exactly with \(n.semantic)")
            }
            // Print the full table, tightest first — this is Task 14's baseline.
            for r in rows.sorted(by: { $0.2 < $1.2 }) {
                print(String(
                    format: "[margin] %-28@ nearest-other %-28@ %.4f",
                    r.0 as NSString,
                    r.1 as NSString,
                    r.2,
                ))
            }
        }
    }
#endif
