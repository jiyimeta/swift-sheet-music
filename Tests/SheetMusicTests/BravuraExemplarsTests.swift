#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct BravuraExemplarsTests {
        /// Pairs whose Bravura outlines are IDENTICAL after normalization, so
        /// no shape-only descriptor can separate them. Measured 2026-07-26.
        ///
        /// `rest(.whole)` (U+E4E3) and `rest(.half)` (U+E4E4) are the same
        /// rectangle in Bravura; they differ only in vertical position
        /// relative to the staff — whole hangs below the 4th line, half sits
        /// on the 3rd. `normalizedBitmap` centres the bounding box and
        /// therefore discards exactly that difference. Resolving them
        /// requires staff-relative geometry, which Tier 4 does not see.
        ///
        /// A pair NOT in this set that collides is a real, unexpected
        /// regression and must still fail the build.
        private static let knownShapeCollisions: Set<Set<SMuFLSemantic>> = [
            [.rest(.whole), .rest(.half)],
        ]

        private static func isKnownCollision(
            _ a: SMuFLSemantic, _ b: SMuFLSemantic,
        ) -> Bool {
            knownShapeCollisions.contains([a, b])
        }

        /// `BravuraExemplars` reaches the bundled face through `BravuraFont`,
        /// which requires macOS 15 while this package deploys to macOS 14 —
        /// so on 14 there are no exemplars to assert about and every check
        /// here is vacuous. SKIP rather than fail: a supported OS must not
        /// report a red build for a font-registration API it cannot have.
        /// (CI runs macOS 15, so the assertions below do run there.)
        /// `ShapeDescriptorTests.bravuraGlyphPath` sets the same precedent.
        private static var exemplarsAvailable: Bool {
            !BravuraExemplars.all.isEmpty
        }

        @Test func buildsExemplarForEveryClassifiableSemantic() {
            guard Self.exemplarsAvailable else { return }
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
            guard Self.exemplarsAvailable else { return }
            let all = BravuraExemplars.all
            // No two DIFFERENT semantics may produce an identical descriptor,
            // except the documented shape-only collisions in
            // `knownShapeCollisions` — those are a measured, real finding
            // (translation-invariant normalization discards staff-relative
            // position), not a bug. Anything NOT in that allowlist must
            // still fail here.
            for i in 0 ..< all.count {
                for j in (i + 1) ..< all.count where all[i].semantic != all[j].semantic {
                    guard !Self.isKnownCollision(all[i].semantic, all[j].semantic) else {
                        continue
                    }
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
            guard Self.exemplarsAvailable else { return }
            let all = BravuraExemplars.all
            var rows: [(e: SMuFLSemantic, nearest: SMuFLSemantic, d: Double)] = []
            for e in all {
                var nearestOther: (semantic: SMuFLSemantic, d: Double)?
                for c in all where c.semantic != e.semantic {
                    let d = e.descriptor.distance(to: c.descriptor)
                    if d < (nearestOther?.d ?? .infinity) {
                        nearestOther = (c.semantic, d)
                    }
                }
                guard let n = nearestOther else { continue }
                rows.append((e.semantic, n.semantic, n.d))
            }
            // Print the full table, tightest first — this is Task 14's
            // baseline. Unconditional: printed regardless of the assertions
            // below, so the measurement is always available even if a new
            // collision trips the checks.
            for r in rows.sorted(by: { $0.d < $1.d }) {
                print(String(
                    format: "[margin] %-28@ nearest-other %-28@ %.4f",
                    "\(r.e)" as NSString,
                    "\(r.nearest)" as NSString,
                    r.d,
                ))
            }
            // Self must still be strictly nearest than any other, except for
            // the documented shape-only collisions in `knownShapeCollisions`
            // (margin 0 there is a real, unfixable finding, not a bug). A
            // NEW zero-margin pair not in that allowlist must still fail.
            for r in rows where !Self.isKnownCollision(r.e, r.nearest) {
                #expect(r.d > 0, "\(r.e) collides exactly with \(r.nearest)")
            }
        }
    }
#endif
