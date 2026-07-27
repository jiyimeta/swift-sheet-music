#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// Unit coverage for `MeasureLayerDiffPlanner`, the pure decision
    /// logic behind `SystemLayerView`'s incremental measure update
    /// (Task 8). The golden-PNG rendering proof only exercises the
    /// full-rebuild path — there is no rasterized fixture for a diffed
    /// update — so this planner's own behavior is the only automated
    /// coverage for which measures rebuild, reposition, or get dropped.
    @Suite("MeasureLayerDiffPlanner")
    struct MeasureLayerDiffPlannerTests {
        /// A measure with distinguishable content (one `barLine` whose
        /// `subtype` encodes an identity token) so tests can flip a
        /// single measure's render content without touching the others.
        private func measure(
            index: Int, originX: CGFloat, contentToken: String = "a",
        ) -> LayoutMeasure {
            LayoutMeasure(
                measureIndex: index,
                origin: CGPoint(x: originX, y: 0),
                width: 100,
                elements: [.barLine(subtype: contentToken, origin: .zero)],
            )
        }

        private func system(
            measures: [LayoutMeasure],
            showsInvisibleElements: Bool = false,
        ) -> LayoutSystem {
            LayoutSystem(
                origin: .zero,
                size: CGSize(width: 300, height: 100),
                measures: measures,
                staffOrigins: [],
                partLabels: [],
                spanners: [],
                sp: 7,
                showsInvisibleElements: showsInvisibleElements,
            )
        }

        @Test("a content change in one measure rebuilds only that measure")
        func contentChangeRebuildsOnlyThatMeasure() {
            let previous = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100),
                measure(index: 2, originX: 200),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100, contentToken: "b"),
                measure(index: 2, originX: 200),
            ])

            let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: next)

            #expect(plan.updates[0] == .reposition(newOriginX: nil))
            #expect(plan.updates[1] == .rebuild)
            #expect(plan.updates[2] == .reposition(newOriginX: nil))
            #expect(plan.removed.isEmpty)
        }

        @Test("a pure origin.x shift repositions without rebuilding")
        func pureShiftReposition() {
            // Measure 1's content is identical; only its X moved (e.g.
            // because measure 0 grew wider upstream).
            let previous = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 120),
            ])

            let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: next)

            #expect(plan.updates[0] == .reposition(newOriginX: nil))
            #expect(plan.updates[1] == .reposition(newOriginX: 120))
            #expect(plan.removed.isEmpty)
        }

        @Test("a removed measure's container is dropped")
        func removedMeasureIsDropped() {
            let previous = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100),
                measure(index: 2, originX: 200),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 2, originX: 100),
            ])

            let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: next)

            #expect(plan.removed == [1])
            #expect(plan.updates.count == 2)
            #expect(plan.updates[0] == .reposition(newOriginX: nil))
            // Measure 2 slid left to close the gap left by the removal.
            #expect(plan.updates[2] == .reposition(newOriginX: 100))
        }

        @Test("a brand-new measure index rebuilds (no previous render to diff against)")
        func newMeasureRebuilds() {
            let previous = system(measures: [
                measure(index: 0, originX: 0),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100),
            ])

            let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: next)

            #expect(plan.updates[0] == .reposition(newOriginX: nil))
            #expect(plan.updates[1] == .rebuild)
            #expect(plan.removed.isEmpty)
        }

        @Test("systemFrameIsUnchanged ignores per-measure element content")
        func systemFrameIgnoresMeasureElements() {
            // Same furniture, different measure content — a measure-level
            // diff is still sufficient; this predicate must say true.
            let previous = system(measures: [measure(index: 0, originX: 0)])
            let next = system(measures: [
                measure(index: 0, originX: 0, contentToken: "different"),
            ])

            #expect(MeasureLayerDiffPlanner.systemFrameIsUnchanged(previous, next))
        }

        @Test("systemFrameIsUnchanged is false when a measure's invisibleElements change")
        func systemFrameCatchesInvisibleElementsChange() {
            // Invisible elements are drawn into ONE shared system-wide
            // layer, not a per-measure container, so a change here must
            // force the full rebuild path rather than the measure diff.
            let previous = system(measures: [
                LayoutMeasure(
                    measureIndex: 0, origin: .zero, width: 100, elements: [],
                    invisibleElements: [],
                ),
            ])
            let next = system(measures: [
                LayoutMeasure(
                    measureIndex: 0, origin: .zero, width: 100, elements: [],
                    invisibleElements: [.barLine(subtype: nil, origin: .zero)],
                ),
            ])

            #expect(!MeasureLayerDiffPlanner.systemFrameIsUnchanged(previous, next))
        }

        @Test("systemFrameIsUnchanged is false when a system-level field changes")
        func systemFrameCatchesSystemLevelChange() {
            let previous = system(measures: [measure(index: 0, originX: 0)])
            let next = system(
                measures: [measure(index: 0, originX: 0)],
                showsInvisibleElements: true,
            )

            #expect(!MeasureLayerDiffPlanner.systemFrameIsUnchanged(previous, next))
        }

        @Test("systemFrameIsUnchanged is false when the trailing barline geometry changes")
        func systemFrameCatchesTrailingBarLineChange() {
            // `wrapToViewWidth` mode: `size` stays equal across an edit
            // that only changes the last measure's barline subtype, but
            // that subtype feeds `BarLineGeometry.staffLineEndX`, which
            // `drawStaves` uses to clip the (system-wide, not
            // per-measure) staff lines (Task 8 review finding 3).
            let previous = system(measures: [
                measure(index: 0, originX: 0),
                LayoutMeasure(
                    measureIndex: 1, origin: CGPoint(x: 100, y: 0),
                    width: 100,
                    elements: [.barLine(subtype: nil, origin: CGPoint(x: 100, y: 0))],
                ),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                LayoutMeasure(
                    measureIndex: 1, origin: CGPoint(x: 100, y: 0),
                    width: 100,
                    elements: [.barLine(subtype: "end", origin: CGPoint(x: 100, y: 0))],
                ),
            ])

            #expect(!MeasureLayerDiffPlanner.systemFrameIsUnchanged(previous, next))
        }

        // MARK: - Exhaustive per-conjunct coverage

        /// Every conjunct of `systemFrameIsUnchanged`'s safety gate,
        /// each paired with a mutation (see `mutate(_:_:)`) that changes
        /// ONLY that one field relative to a shared `fullSystem()`
        /// fixture. Parameterized so that accidentally deleting a
        /// conjunct from the predicate (e.g. dropping
        /// `&& a.spanners == b.spanners`) fails exactly the
        /// corresponding case instead of leaving the suite silently
        /// green — before this, only 2 of the then-11 (now 12, with
        /// `staffLineEndX`) conjuncts had any pinning test at all
        /// (Task 8 review finding 4). Verified load-bearing by
        /// temporarily deleting each conjunct in turn during review and
        /// confirming only its own case failed; see the fix-round
        /// report for the full log.
        enum FrameConjunct: String, CaseIterable, CustomStringConvertible {
            case size, origin, staffOrigins, staffAddresses, partLabels,
                 brackets, spanners, invisibleSpanners, sp,
                 showsInvisibleElements, invisibleElements, trailingBarLine

            var description: String {
                rawValue
            }
        }

        @Test(
            "changing any single conjunct forces a full rebuild",
            arguments: FrameConjunct.allCases,
        )
        func systemFrameCatchesEveryConjunct(_ field: FrameConjunct) {
            let base = fullSystem()
            let mutated = mutate(base, field)
            #expect(
                !MeasureLayerDiffPlanner.systemFrameIsUnchanged(base, mutated),
                "changing \(field) alone should force a full rebuild",
            )
        }

        @Test("fullSystem() compared to an identical copy is unchanged")
        func fullSystemIdentityIsUnchanged() {
            let base = fullSystem()
            let copy = rebuild(base)
            #expect(MeasureLayerDiffPlanner.systemFrameIsUnchanged(base, copy))
        }

        /// A system with every `systemFrameIsUnchanged` conjunct
        /// populated with a non-default value, so a mutation to any one
        /// field is guaranteed to actually change that field (as
        /// opposed to e.g. toggling a `Bool` that was already `true`
        /// back to `true`).
        private func fullSystem() -> LayoutSystem {
            LayoutSystem(
                origin: CGPoint(x: 1, y: 2),
                size: CGSize(width: 300, height: 100),
                measures: [
                    measure(index: 0, originX: 0),
                    LayoutMeasure(
                        measureIndex: 1, origin: CGPoint(x: 100, y: 0),
                        width: 100,
                        elements: [.barLine(subtype: nil, origin: CGPoint(x: 100, y: 0))],
                        invisibleElements: [.barLine(subtype: "hidden", origin: .zero)],
                    ),
                ],
                staffOrigins: [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 40)],
                staffAddresses: [
                    StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    StaffAddress(partIndex: 1, staffIndexInPart: 0),
                ],
                partLabels: [LayoutPartLabel(text: "Violin", origin: .zero)],
                brackets: [LayoutBracket(type: .brace, topY: 0, bottomY: 40, column: 0)],
                spanners: [.measureNumber(text: "spanner-token", origin: .zero)],
                sp: 7,
                invisibleSpanners: [
                    .measureNumber(text: "invisible-spanner-token", origin: .zero),
                ],
                showsInvisibleElements: false,
            )
        }

        /// Reconstructs a `LayoutSystem` from `base`, overriding exactly
        /// the fields passed in. Used both as a no-op identity copy
        /// (`fullSystemIdentityIsUnchanged`) and by `mutate(_:_:)` below
        /// to change exactly one field per `FrameConjunct` case.
        private func rebuild(
            _ base: LayoutSystem,
            origin: CGPoint? = nil,
            size: CGSize? = nil,
            measures: [LayoutMeasure]? = nil,
            staffOrigins: [CGPoint]? = nil,
            staffAddresses: [StaffAddress]? = nil,
            partLabels: [LayoutPartLabel]? = nil,
            brackets: [LayoutBracket]? = nil,
            spanners: [LayoutElement]? = nil,
            sp: CGFloat? = nil,
            invisibleSpanners: [LayoutElement]? = nil,
            showsInvisibleElements: Bool? = nil,
        ) -> LayoutSystem {
            LayoutSystem(
                origin: origin ?? base.origin,
                size: size ?? base.size,
                measures: measures ?? base.measures,
                staffOrigins: staffOrigins ?? base.staffOrigins,
                staffAddresses: staffAddresses ?? base.staffAddresses,
                partLabels: partLabels ?? base.partLabels,
                brackets: brackets ?? base.brackets,
                spanners: spanners ?? base.spanners,
                sp: sp ?? base.sp,
                invisibleSpanners: invisibleSpanners ?? base.invisibleSpanners,
                showsInvisibleElements: showsInvisibleElements
                    ?? base.showsInvisibleElements,
            )
        }

        private func mutate(_ base: LayoutSystem, _ field: FrameConjunct) -> LayoutSystem {
            switch field {
            case .size:
                rebuild(base, size: CGSize(
                    width: base.size.width + 10, height: base.size.height,
                ))
            case .origin:
                rebuild(base, origin: CGPoint(
                    x: base.origin.x + 1, y: base.origin.y,
                ))
            case .staffOrigins:
                rebuild(base, staffOrigins: base.staffOrigins + [CGPoint(x: 0, y: 80)])
            case .staffAddresses:
                rebuild(
                    base,
                    staffAddresses: base.staffAddresses
                        + [StaffAddress(partIndex: 2, staffIndexInPart: 0)],
                )
            case .partLabels:
                rebuild(
                    base,
                    partLabels: base.partLabels
                        + [LayoutPartLabel(text: "Viola", origin: .zero)],
                )
            case .brackets:
                rebuild(
                    base,
                    brackets: base.brackets
                        + [LayoutBracket(type: .square, topY: 0, bottomY: 40, column: 1)],
                )
            case .spanners:
                rebuild(
                    base,
                    spanners: base.spanners
                        + [.measureNumber(text: "extra-spanner", origin: .zero)],
                )
            case .invisibleSpanners:
                rebuild(
                    base,
                    invisibleSpanners: base.invisibleSpanners
                        + [.measureNumber(text: "extra-invisible-spanner", origin: .zero)],
                )
            case .sp:
                rebuild(base, sp: base.sp + 1)
            case .showsInvisibleElements:
                rebuild(base, showsInvisibleElements: !base.showsInvisibleElements)
            case .invisibleElements, .trailingBarLine:
                mutateLastMeasure(base, field)
            }
        }

        /// Handles the two `FrameConjunct` cases that mutate the last
        /// measure's `LayoutMeasure` value rather than a system-level
        /// field. Split out of `mutate(_:_:)` to keep its body under
        /// the project's function-length lint cap.
        private func mutateLastMeasure(
            _ base: LayoutSystem, _ field: FrameConjunct,
        ) -> LayoutSystem {
            rebuild(base, measures: withMutatedMeasure(base, at: 1) { m in
                switch field {
                case .invisibleElements:
                    LayoutMeasure(
                        measureIndex: m.measureIndex, origin: m.origin, width: m.width,
                        elements: m.elements,
                        invisibleElements: m.invisibleElements
                            + [.barLine(subtype: "extra-invisible", origin: .zero)],
                    )
                case .trailingBarLine:
                    // Same `size` — the `wrapToViewWidth`-reachable
                    // case from finding 3: only the last measure's
                    // barline subtype changes, which moves
                    // `BarLineGeometry.staffLineEndX`.
                    LayoutMeasure(
                        measureIndex: m.measureIndex, origin: m.origin, width: m.width,
                        elements: [.barLine(subtype: "final", origin: CGPoint(x: m.width, y: 0))],
                        invisibleElements: m.invisibleElements,
                    )
                default:
                    m
                }
            })
        }

        private func withMutatedMeasure(
            _ base: LayoutSystem, at index: Int,
            _ transform: (LayoutMeasure) -> LayoutMeasure,
        ) -> [LayoutMeasure] {
            var measures = base.measures
            measures[index] = transform(measures[index])
            return measures
        }
    }
#endif
