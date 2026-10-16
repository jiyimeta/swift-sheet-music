// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Pure function: `Score` → `LayoutDocument`.
///
/// v1 is a single-pass engine with simple heuristics. No caching, no
/// mutation, no back-pointers. Safe to re-run on every option change.
///
/// The enum is split across extensions for readability:
/// - `LayoutEngine+Spacing.swift`     — measure width calculations.
/// - `LayoutEngine+Placement.swift`   — per-measure element placement
///   (`placeMeasureElements`), glissando, beaming pass.
/// - `LayoutEngine+Beaming.swift`     — `beamGroups` + helpers.
/// - `LayoutEngine+Spanners.swift`    — anchor collect + attach pass.
/// - `LayoutEngine+Ties.swift`        — tie pair resolve + attach.
/// - `LayoutEngine+Glissandi.swift`   — glissando pair resolve + attach
///   (same post-pass shape as ties; handles cross-measure/cross-system).
/// - `LayoutEngine+Packing.swift`     — `packSystems`, stretch, default
///   clef resolution.
/// - `LayoutEngine+SystemBuild.swift` — per-system `buildSystem` pass.
/// - `LayoutEngine+YBounds.swift`     — element-Y skyline helpers.
/// - `LayoutEngine+Translate.swift`   — element-tree vertical translate.
public enum LayoutEngine {
    /// Lay out `score` into a `LayoutDocument`. Equivalent to the
    /// cache-aware overload with `cache: nil` — every per-measure
    /// computation runs from scratch.
    public static func layout(
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat,
    ) -> LayoutDocument {
        layout(
            score: score,
            options: options,
            availableWidth: availableWidth,
            cache: nil,
        )
    }

    /// Cache-aware overload. Reuse the same `LayoutCache` instance
    /// across edits and unchanged measures will skip per-measure
    /// recomputation.
    ///
    /// The cache is rebuilt in place each call: prior entries are
    /// kept only when their inputs match the current call.
    public static func layout( // swiftlint:disable:this function_body_length
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat,
        cache: LayoutCache?,
    ) -> LayoutDocument {
        #if DEBUG && canImport(CoreText)
            assert(
                !(FontMetrics.provider is StubFontMetricsProvider),
                "FontMetrics.provider is still StubFontMetricsProvider on a "
                    + "CoreText-capable platform. Call "
                    + "`_ = SheetMusicLayoutApple.install` at app launch, or "
                    + "import SheetMusicUI / SheetMusicPDF (they auto-install).",
            )
        #endif
        // Hide redundant auto-computed accidentals up front so every
        // downstream pass (placement, glyph emission, caching) sees the
        // same engraved set MuseScore would draw. USER accidentals and
        // any note whose spelling can't be derived are left untouched.
        let score = score.suppressingRedundantAccidentals()
        let metrics = StaffMetrics(
            staffSize: options.staffSize,
            spacing: options.spacing,
        )
        let margins = options.spacing.margins
        let melismas = computeMelismaContinuations(
            score: score, division: score.division,
        )
        let multiMeasureRestPlan = MultiMeasureRestPlanner.plan(
            for: score, policy: options.multiMeasureRest,
        )
        // Computed ONCE per layout call, not per system / per measure:
        // `packSystems` and `buildSystem` used to each re-derive their
        // own copy (the former across every measure, the latter across
        // every system), which is exactly the O(n²) pattern this table
        // exists to avoid. Built from `score` — the accidental-
        // suppressed copy above — so staff shape matches what
        // `packSystems` / `buildSystem` see.
        let staves = score.allStaves.map(\.staff)
        let measureDurations = effectiveMeasureDurationsAcrossStaves(
            staves: staves,
        )
        let staffMeasureDurations: [[Fraction]] = staves.map {
            $0.measures.effectiveMeasureDurations()
        }
        // Collected before `packSystems`, not after: `buildSystem`
        // lays the line spanners out itself so they reach the skyline
        // pass. The post-pass below reuses the same list.
        let anchors = collectSpanners(score: score)
        let context = RenderContext(
            score: score,
            options: options,
            metrics: metrics,
            availableWidth: availableWidth,
            melismaContinuations: melismas,
            cache: cache,
            spannerAnchors: anchors,
            multiMeasureRestPlan: multiMeasureRestPlan,
            measureDurations: measureDurations,
            staffMeasureDurations: staffMeasureDurations,
        )
        let packedSystems = packSystems(context: context)
        // Title block at the top of the document. Built first so we
        // know how much vertical space to leave above the first
        // system.
        let unshiftedTitleFrame: LayoutTitleFrame? = {
            guard options.includeTitleFrame, let src = score.titleFrame
            else { return nil }
            return buildTitleFrame(
                source: src,
                style: score.style,
                metrics: metrics,
                docWidth: max(
                    availableWidth,
                    packedSystems.reduce(CGFloat(0)) { acc, s in
                        max(acc, s.origin.x + s.size.width)
                    },
                ),
            )
        }()
        // Use the actual rendered system extent — not `availableWidth`,
        // which may be larger than the content needs. Measure before the
        // leading-margin shift so that margin is added exactly once below.
        let totalWidth = packedSystems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.x + system.size.width)
        }
        let topMargin = metrics.sp * margins.top
        let leadingMargin = metrics.sp * margins.leading
        let yShift = (unshiftedTitleFrame?.height ?? 0) + topMargin
        let systems = packedSystems.map { system in
            let shiftedY = yShift != 0
                ? shift(system, byY: yShift) : system
            return leadingMargin != 0
                ? shift(shiftedY, byX: leadingMargin) : shiftedY
        }
        // The title block moves with BOTH margins, not just the top one.
        // Its texts are placed against the music width (`baseX` resolves
        // `.center` to `docWidth / 2` and `.right` to `docWidth`, where
        // that `docWidth` excludes margins), so a leading margin that
        // moved only the systems would leave a centered title off-centre
        // over the music and a left-aligned one hanging in the margin.
        let titleFrame = unshiftedTitleFrame.map { frame in
            shift(frame, byX: leadingMargin, byY: topMargin)
        }
        let totalHeight = systems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.y + system.size.height)
        } + metrics.sp * margins.bottom
        let systemsWithSpanners = attachSpanners(
            to: systems,
            anchors: anchors,
            score: score,
            metrics: metrics,
        )
        // Margins live outside the music width and deliberately do not
        // participate in system wrapping.
        let docWidth = leadingMargin + totalWidth
            + metrics.sp * margins.trailing
        let firstPass = LayoutDocument(
            size: CGSize(width: docWidth, height: totalHeight),
            systems: systemsWithSpanners,
            metrics: metrics,
            titleFrame: titleFrame,
            chordSymbolCase: score.style.chordSymbolCase,
        )
        let ties = resolveTies(for: firstPass, score: score)
        let systemsWithTies = attachTies(
            to: systemsWithSpanners, pairs: ties, metrics: metrics,
        )
        // Chord-anchored slurs ride the tie pass's own emission: a slur
        // pair is structurally a `TiePair` (two absolute origins plus a
        // side) and MuseScore draws both with the same cubic, so they go
        // through `attachArcs` — including its cross-system BEGIN / END
        // split — instead of a second copy of it. Note origins come from
        // `firstPass` for the same reason ties' do: attaching arcs adds
        // spanners, never moves a notehead.
        let slurPairs = resolveSlurs(for: firstPass, score: score)
        let systemsWithSlurs = attachArcs(
            to: systemsWithTies, pairs: slurPairs, metrics: metrics,
        )
        // Glissandi are resolved last (spanners → ties → glissandi) in
        // a post-pass that mirrors ties — it can pair a glissando with
        // its target chord even across a measure/system boundary,
        // unlike the old placement-time pairing that only looked
        // within the current measure. Note origins are read from
        // `firstPass` (final at this point in the pipeline; ties
        // attach new spanners, not new note origins).
        let glissPairs = resolveGlissandi(for: firstPass, score: score)
        let systemsWithGliss = attachGlissandi(
            to: systemsWithSlurs, pairs: glissPairs, metrics: metrics,
        )
        // Guitar bends resolve alongside glissandi and for the same
        // reason: a bend's target is the next chord, which may live in
        // the next measure. Note origins come from `firstPass` too —
        // neither the tie nor the glissando pass moves a notehead.
        let bendPairs = resolveGuitarBends(for: firstPass, score: score)
        let systemsWithBends = attachGuitarBends(
            to: systemsWithGliss, pairs: bendPairs, metrics: metrics,
        )
        // Legacy MuseScore 3 `<Bend>` curves ride the same post-pass.
        // They need no pairing — the whole curve hangs off one notehead —
        // but they read the same `firstPass` note origins, and their
        // rise target is measured off the staff top, which only the
        // laid-out system knows.
        let legacyBends = resolveLegacyBends(for: firstPass, score: score)
        let systemsWithLegacyBends = attachLegacyBends(
            to: systemsWithBends, resolved: legacyBends, metrics: metrics,
        )
        return LayoutDocument(
            size: firstPass.size,
            systems: systemsWithLegacyBends,
            metrics: metrics,
            titleFrame: titleFrame,
            chordSymbolCase: score.style.chordSymbolCase,
        )
    }

    static func shift(
        _ system: LayoutSystem, byY dy: CGFloat,
    ) -> LayoutSystem {
        system.movedBy(dy: dy)
    }

    static func shift(
        _ system: LayoutSystem, byX dx: CGFloat,
    ) -> LayoutSystem {
        LayoutSystem(
            rebuilding: system,
            origin: CGPoint(x: system.origin.x + dx, y: system.origin.y),
            spanners: system.spanners,
        )
    }

    /// `LayoutTitleFrame` has no origin of its own — its texts carry
    /// absolute positions — so a document-level shift has to move every
    /// text. `height` is a size, not a position, and stays put.
    static func shift(
        _ titleFrame: LayoutTitleFrame, byX dx: CGFloat, byY dy: CGFloat,
    ) -> LayoutTitleFrame {
        guard dx != 0 || dy != 0 else { return titleFrame }
        return LayoutTitleFrame(
            height: titleFrame.height,
            texts: titleFrame.texts.map { text in
                LayoutFrameText(
                    text: text.text,
                    style: text.style,
                    position: CGPoint(
                        x: text.position.x + dx,
                        y: text.position.y + dy,
                    ),
                    fontSize: text.fontSize,
                    anchor: text.anchor,
                    richText: text.richText,
                )
            },
        )
    }

    // MARK: - Context

    struct RenderContext {
        let score: Score
        let options: ScoreViewOptions
        let metrics: StaffMetrics
        let availableWidth: CGFloat
        /// Per-(staff, measure) melisma continuation lines.
        /// `melismaContinuations[staffIdx][measureIdx]` lists the
        /// melismas that extend INTO this measure from an earlier
        /// measure. The measure that owns the anchor `<Lyrics>` is
        /// handled by the per-chord `emitMelismaLine` path and is
        /// not included here.
        let melismaContinuations: [[[MelismaContinuation]]]
        /// Optional incremental-layout cache. When non-nil, the
        /// layout pass reads prior per-measure results from it and
        /// rebuilds it in place with this call's results. See
        /// `LayoutCache`.
        let cache: LayoutCache?
        /// Every spanner anchor in the score, collected once at layout
        /// entry. `buildSystem` reads this to synthesize the line
        /// spanners (hairpin / pedal / ottava / text line) into its
        /// pass-1 buffer, where `SkylineAutoplacePass` can place them;
        /// `attachSpanners` reads the same list afterwards for the
        /// kinds that stay in the post-pass.
        let spannerAnchors: [SpannerAnchor]
        /// Run plan for the multi-measure-rest collapse pass. Empty when
        /// `options.multiMeasureRest == .disabled` (every rest measure
        /// renders individually). Tasks 6 and 7 read this to override
        /// per-measure widths and emit a single H-bar measure per run.
        let multiMeasureRestPlan: MultiMeasureRestPlan
        /// Cross-staff effective duration of every measure index
        /// (`LayoutEngine.effectiveMeasureDurationsAcrossStaves`),
        /// computed once at layout entry. `packSystems` and
        /// `buildSystem` both read this instead of re-deriving it —
        /// `buildSystem` in particular runs once PER SYSTEM, so
        /// recomputing there would still be Θ(systems · staves ·
        /// measures) despite looking like a per-call hoist.
        let measureDurations: [Fraction]
        /// Per-staff effective measure durations
        /// (`staffMeasureDurations[staffIdx][measureIdx]`), computed
        /// once at layout entry for the same reason as
        /// `measureDurations`. Used where a single staff's own
        /// prevailing time signature is wanted (e.g. `placeMeasureElements`
        /// inputs), as opposed to the cross-staff merge.
        let staffMeasureDurations: [[Fraction]]
    }
}
