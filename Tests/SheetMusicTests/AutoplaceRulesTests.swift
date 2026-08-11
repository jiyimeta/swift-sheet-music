#if !os(Android)
    import CoreGraphics
    @testable import SheetMusicLayout
    import Testing

    @Suite("AutoplaceRules")
    struct AutoplaceRulesTests {
        private let sp: CGFloat = 7

        private func item(_ kind: ShapeItemKind, _ id: Int) -> ShapeItem {
            ShapeItem(kind: kind, id: id)
        }

        @Test func minDistanceTableMatchesMuseScoreDefaults() {
            #expect(AutoplaceRules.minDistance(for: .dynamics, sp: sp) == sp * 0.5)
            #expect(AutoplaceRules.minDistance(for: .lyrics, sp: sp) == sp * 0.25)
            #expect(AutoplaceRules.minDistance(for: .tempo, sp: sp) == sp * 0.5)
            #expect(AutoplaceRules.minDistance(for: .measureNumber, sp: sp) == sp * 0.5)
            #expect(AutoplaceRules.minDistance(for: .systemText, sp: sp) == sp * 0.5)
            #expect(AutoplaceRules.minDistance(for: .staffText, sp: sp) == sp * 0.5)
            #expect(AutoplaceRules.minDistance(for: .rehearsalMark, sp: sp) == sp * 0.5)
            #expect(AutoplaceRules.minDistance(for: .harmony, sp: sp) == sp * 0.5)
        }

        @Test func horizontalClearanceIsQuarterSpatiumExceptArticulations() {
            #expect(AutoplaceRules.horizontalClearance(
                for: .tempo, sp: sp,
            ) == sp * 0.25)
            #expect(AutoplaceRules.horizontalClearance(
                for: .articulation, sp: sp,
            ) == 0)
            #expect(AutoplaceRules.horizontalClearance(
                for: .fermata, sp: sp,
            ) == 0)
        }

        @Test func itemIgnoresItself() {
            #expect(AutoplaceRules.shouldIgnoreEachOther(
                item(.staffText, 3), item(.staffText, 3),
            ))
        }

        @Test func dynamicsAndHairpinsIgnoreEachOther() {
            #expect(AutoplaceRules.shouldIgnoreEachOther(
                item(.dynamics, 1), item(.hairpin, 2),
            ))
            #expect(AutoplaceRules.shouldIgnoreEachOther(
                item(.hairpin, 2), item(.dynamics, 1),
            ))
        }

        /// Two chords ignore each other (same non-text kind).
        @Test func sameNonTextKindIgnoresEachOther() {
            #expect(AutoplaceRules.shouldIgnoreEachOther(
                item(.chord, 1), item(.chord, 2),
            ))
        }

        /// Two staff texts DO collide (same text kind, different items).
        @Test func sameTextKindCollides() {
            #expect(!AutoplaceRules.shouldIgnoreEachOther(
                item(.staffText, 1), item(.staffText, 2),
            ))
            #expect(!AutoplaceRules.shouldIgnoreEachOther(
                item(.lyrics, 1), item(.lyrics, 2),
            ))
        }

        /// Dynamics are the text-kind exception — they align as a chain.
        @Test func sameDynamicsKindIgnoresEachOther() {
            #expect(AutoplaceRules.shouldIgnoreEachOther(
                item(.dynamics, 1), item(.dynamics, 2),
            ))
        }

        @Test func differentKindsCollide() {
            #expect(!AutoplaceRules.shouldIgnoreEachOther(
                item(.rehearsalMark, 1), item(.measureNumber, 2),
            ))
            #expect(!AutoplaceRules.shouldIgnoreEachOther(
                item(.lyrics, 1), item(.dynamics, 2),
            ))
            #expect(!AutoplaceRules.shouldIgnoreEachOther(
                item(.tempo, 1), item(.chord, 2),
            ))
        }

        @Test func autoplacedSetExcludesBaseSkylineKinds() {
            #expect(AutoplaceRules.isAutoplaced(.lyrics))
            #expect(AutoplaceRules.isAutoplaced(.rehearsalMark))
            #expect(AutoplaceRules.isAutoplaced(.pedal))
            #expect(!AutoplaceRules.isAutoplaced(.chord))
            #expect(!AutoplaceRules.isAutoplaced(.staff))
            #expect(!AutoplaceRules.isAutoplaced(.beam))
        }

        @Test func defaultSideTable() {
            #expect(AutoplaceRules.defaultSide(for: .dynamics) == .below)
            #expect(AutoplaceRules.defaultSide(for: .lyrics) == .below)
            #expect(AutoplaceRules.defaultSide(for: .tempo) == .above)
            #expect(AutoplaceRules.defaultSide(for: .volta) == .above)
            #expect(AutoplaceRules.defaultSide(for: .rehearsalMark) == .above)
        }

        /// The four spanner kinds take their side from the element's
        /// own Y, not from a per-kind table. `autoplaceSpannerSegment`
        /// reads `spanner()->placeAbove()` (`autoplace.cpp:223`), and an
        /// authored `<placement>` is already baked into the segment's Y
        /// by the time the pass runs — so a fixed side here would push
        /// a hairpin flipped above the staff back down through it.
        @Test func spannerSidesFollowTheElement() {
            for kind: ShapeItemKind in [
                .hairpin, .pedal, .ottava, .textLine,
            ] {
                #expect(AutoplaceRules.defaultSide(for: kind) == nil)
                #expect(AutoplaceRules.isAutoplaced(kind))
            }
        }

        /// Coverage invariant: every autoplaced kind must resolve to a
        /// side — either a fixed one from the table, or by position.
        /// Without this, a new kind added to one switch and not the
        /// other would compile and silently mis-place.
        @Test func everyAutoplacedKindResolvesToASide() {
            let byPosition: Set<ShapeItemKind> = [
                .hairpin, .pedal, .ottava, .textLine,
            ]
            for kind in ShapeItemKind.allCases
                where AutoplaceRules.isAutoplaced(kind)
            {
                #expect(
                    AutoplaceRules.defaultSide(for: kind) != nil
                        || byPosition.contains(kind),
                    "\(kind) is autoplaced but has no side rule",
                )
            }
        }
    }
#endif
