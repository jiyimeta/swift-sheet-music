// swiftlint:disable file_length
import CoreGraphics
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
/// - `LayoutEngine+Packing.swift`     — `packSystems`, stretch, default
///   clef resolution.
/// - `LayoutEngine+SystemBuild.swift` — per-system `buildSystem` pass.
/// - `LayoutEngine+YBounds.swift`     — element-Y skyline helpers.
/// - `LayoutEngine+Translate.swift`   — element-tree vertical translate.
@available(macOS 15.0, *)
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
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let effectiveMelismaTicks = computeEffectiveMelismaTicks(
            score: score, division: score.division,
        )
        let melismas = computeMelismaContinuations(
            score: score, division: score.division,
            effectiveTicks: effectiveMelismaTicks,
        )
        let multiMeasureRestPlan = MultiMeasureRestPlanner.plan(
            for: score, policy: options.multiMeasureRest,
        )
        let context = RenderContext(
            score: score,
            options: options,
            metrics: metrics,
            availableWidth: availableWidth,
            melismaContinuations: melismas,
            effectiveMelismaTicks: effectiveMelismaTicks,
            cache: cache,
            belowStaffSpannerCoverage: belowStaffSpannerCoverage(score: score),
            multiMeasureRestPlan: multiMeasureRestPlan,
        )
        let packedSystems = packSystems(context: context)
        // Title block at the top of the document. Built first so we
        // know how much vertical space to leave above the first
        // system.
        let titleFrame: LayoutTitleFrame? = {
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
        let yShift = titleFrame?.height ?? 0
        let systems = yShift > 0
            ? packedSystems.map { shift($0, byY: yShift) }
            : packedSystems
        // Use the actual rendered system extent — not `availableWidth`,
        // which may be larger than the content needs.
        let totalWidth = systems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.x + system.size.width)
        }
        let totalHeight = systems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.y + system.size.height)
        }
        let anchors = collectSpanners(score: score)
        let systemsWithSpanners = attachSpanners(
            to: systems,
            anchors: anchors,
            score: score,
            metrics: metrics,
        )
        // Add a small right margin so the last barline doesn't
        // touch the canvas edge.
        let docWidth = totalWidth + metrics.sp * 2
        let firstPass = LayoutDocument(
            size: CGSize(width: docWidth, height: totalHeight),
            systems: systemsWithSpanners,
            metrics: metrics,
            titleFrame: titleFrame,
        )
        let ties = resolveTies(for: firstPass, score: score)
        let systemsWithTies = attachTies(
            to: systemsWithSpanners, pairs: ties, metrics: metrics,
        )
        return LayoutDocument(
            size: firstPass.size,
            systems: systemsWithTies,
            metrics: metrics,
            titleFrame: titleFrame,
        )
    }

    static func shift(
        _ system: LayoutSystem, byY dy: CGFloat,
    ) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(
                x: system.origin.x, y: system.origin.y + dy,
            ),
            size: system.size,
            measures: system.measures,
            staffOrigins: system.staffOrigins,
            partLabels: system.partLabels,
            brackets: system.brackets,
            spanners: system.spanners,
            sp: system.sp,
        )
    }

    private static func buildTitleFrame(
        source: ScoreFrame,
        style: ScoreStyle,
        metrics: StaffMetrics,
        docWidth: CGFloat,
    ) -> LayoutTitleFrame {
        // MuseScore stores offsets for the title-block styles in
        // millimetres (`OffsetType::ABS` — see `styledef.cpp`).
        // Conversion to typographic points: 72 pt ÷ 25.4 mm.  We use
        // the same conversion for both the per-text override
        // (`<offset>` in `.mscx`) and the styledef defaults (e.g.
        // `subTitleOffset = PointF(0, 10)` ⇒ 10 mm below VBox top).
        let mmToPt: CGFloat = 72.0 / 25.4

        // MuseScore's `<height>` is in spatium units. We use it as a
        // *minimum* — never shrink — but if the declared VBox is too
        // small to fit its own top-anchored texts (typical when the
        // user hand-edits `<height>` shorter than the subtitle stack
        // needs), grow the frame to keep them from being clipped by
        // the renderer's canvas. Bottom-anchored texts (composer /
        // lyricist) follow the resolved bottom edge.
        // SwiftUI `Text` resolved by `GraphicsContext.resolve` uses
        // the system font's natural line height (~1.2 × point size);
        // 1.3 leaves a small breathing margin above the next system.
        let textHeightFactor: CGFloat = 1.3
        var requiredFromTopAnchors: CGFloat = 0
        for (idx, t) in source.texts.enumerated() {
            let layout = titleBlockLayout(
                for: t.style, idx: idx, style: style,
                override: t.align, mmToPt: mmToPt,
            )
            // Bottom-anchored texts grow downward from the frame
            // bottom — they don't constrain how *tall* the frame
            // needs to be.
            guard layout.align.vertical == .top else { continue }
            let fontSize = CGFloat(t.fontSize ?? Double(layout.fontSize))
            let dy = (t.offsetMm?.y ?? 0) * mmToPt
            let bottom = layout.topOffset + dy
                + fontSize * textHeightFactor
            if bottom > requiredFromTopAnchors {
                requiredFromTopAnchors = bottom
            }
        }
        let frameHeight = max(
            metrics.sp * 4,
            source.heightSp * metrics.sp,
            requiredFromTopAnchors,
        )

        var laidOut: [LayoutFrameText] = []
        for (idx, t) in source.texts.enumerated() {
            let layout = titleBlockLayout(
                for: t.style, idx: idx, style: style,
                override: t.align, mmToPt: mmToPt,
            )
            let baseX = baseX(for: layout.align, docWidth: docWidth)
            let baseY: CGFloat = layout.align.vertical == .top
                ? layout.topOffset
                : frameHeight
            let dx = (t.offsetMm?.x ?? 0) * mmToPt
            let dy = (t.offsetMm?.y ?? 0) * mmToPt
            // Per-element `<size>` overrides the styledef default.
            // Used by scores that hand-tune font sizes — e.g.
            // test-platinum.mscx ships `<size>7</size>` on its
            // three Lyricist columns to tighten each verse block.
            let fontSize = CGFloat(t.fontSize ?? Double(layout.fontSize))
            laidOut.append(LayoutFrameText(
                text: t.text,
                style: t.style,
                position: CGPoint(x: baseX + dx, y: baseY + dy),
                fontSize: fontSize,
                anchor: anchor(for: layout.align),
            ))
        }
        return LayoutTitleFrame(
            height: frameHeight, texts: laidOut,
        )
    }

    /// Resolved layout properties for a title-block text style.
    /// `align` picks horizontal/vertical anchor, `topOffset` is the
    /// styledef vertical offset applied when `align.vertical == .top`
    /// (e.g. subtitle's 10 mm), `fontSize` is the styledef default.
    private struct TitleBlockLayout {
        let align: TextAlign
        let topOffset: CGFloat
        let fontSize: CGFloat
    }

    /// Defaults sourced from MuseScore's `engraving/style/styledef.cpp`:
    ///   Title    — Align(HCENTER, TOP),    offset (0,  0) mm, font 22pt
    ///   Subtitle — Align(HCENTER, TOP),    offset (0, 10) mm, font 14pt
    ///   Composer — Align(RIGHT,   BOTTOM), offset (0,  0) mm, font 10pt
    ///   Lyricist — Align(LEFT,    BOTTOM), offset (0,  0) mm, font 10pt
    /// Per-style align overrides on `ScoreStyle` (e.g.
    /// `<lyricistAlign>center,bottom</lyricistAlign>`) replace the
    /// styledef horizontal/vertical pair while leaving the offset
    /// and font size unchanged.
    private static func titleBlockLayout(
        for textStyle: FrameText.Style,
        idx: Int,
        style scoreStyle: ScoreStyle,
        override: TextAlign?,
        mmToPt: CGFloat,
    ) -> TitleBlockLayout {
        // Per-element `<align>` overrides both the styledef default
        // and any `<{role}Align>` style-wide override — MuseScore's
        // `read460/tread.cpp` writes `<align>` only when the element
        // diverges from the resolved style, so when present it is the
        // final word.
        let base = switch textStyle {
        case .title:
            TitleBlockLayout(
                align: scoreStyle.titleAlign
                    ?? TextAlign(horizontal: .center, vertical: .top),
                topOffset: 0,
                fontSize: 22,
            )
        case .subtitle:
            TitleBlockLayout(
                align: scoreStyle.subtitleAlign
                    ?? TextAlign(horizontal: .center, vertical: .top),
                topOffset: 10 * mmToPt,
                fontSize: 14,
            )
        case .composer:
            TitleBlockLayout(
                align: scoreStyle.composerAlign
                    ?? TextAlign(horizontal: .right, vertical: .bottom),
                topOffset: 0,
                fontSize: 10,
            )
        case .lyricist:
            TitleBlockLayout(
                align: scoreStyle.lyricistAlign
                    ?? TextAlign(horizontal: .left, vertical: .bottom),
                topOffset: 0,
                fontSize: 10,
            )
        case .other:
            TitleBlockLayout(
                align: TextAlign(horizontal: .center, vertical: .top),
                topOffset: 10 * mmToPt + CGFloat(idx) * 4 * mmToPt,
                fontSize: 10,
            )
        }
        guard let override else { return base }
        return TitleBlockLayout(
            align: override,
            // Switching a default-bottom role (composer / lyricist)
            // to a top anchor brings the text up to the frame top
            // edge — keep the styledef `topOffset` so titles in a
            // mixed top stack don't all collapse to y=0.
            topOffset: base.topOffset,
            fontSize: base.fontSize,
        )
    }

    private static func baseX(
        for align: TextAlign, docWidth: CGFloat,
    ) -> CGFloat {
        switch align.horizontal {
        case .left: 0
        case .center: docWidth / 2
        case .right: docWidth
        }
    }

    /// `LayoutFrameText.Anchor` only models the six rectangular
    /// corners. Vertical `.center` / `.baseline` (rare for title
    /// roles) collapse to the top-side anchor of the same horizontal
    /// axis — adequate for the cases that actually appear in MSCX
    /// title blocks.
    private static func anchor(
        for align: TextAlign,
    ) -> LayoutFrameText.Anchor {
        switch (align.horizontal, align.vertical) {
        case (.left, .bottom): return .bottomLeading
        case (.center, .bottom): return .bottom
        case (.right, .bottom): return .bottomTrailing
        case (.left, _): return .topLeading
        case (.center, _): return .top
        case (.right, _): return .topTrailing
        }
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
        /// Per-lyric effective melisma duration (in ticks) that
        /// accounts for tied-chain continuations past the anchor
        /// note. Used by `placeMeasureElements` so that the
        /// "melisma?" check is consistent with the continuation
        /// plan from `computeMelismaContinuations`.
        let effectiveMelismaTicks: [MelismaLyricKey: Int]
        /// Optional incremental-layout cache. When non-nil, the
        /// layout pass reads prior per-measure results from it and
        /// rebuilds it in place with this call's results. See
        /// `LayoutCache`.
        let cache: LayoutCache?
        /// Per-staff set of measure indices that fall under a visible
        /// below-staff spanner (today: hairpin / pedal). Lyric placement
        /// reads this to push its baseline below the spanner band so
        /// the spanner glyph and lyric row don't overlap. Computed
        /// once at layout entry — cheap walk across spanners.
        let belowStaffSpannerCoverage: [Int: Set<Int>]
        /// Run plan for the multi-measure-rest collapse pass. Empty when
        /// `options.multiMeasureRest == .disabled` (every rest measure
        /// renders individually). Tasks 6 and 7 read this to override
        /// per-measure widths and emit a single H-bar measure per run.
        let multiMeasureRestPlan: MultiMeasureRestPlan
    }
}
