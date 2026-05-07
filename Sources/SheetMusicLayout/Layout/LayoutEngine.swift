// swiftlint:disable function_body_length file_length
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
@available(macOS 15.0, iOS 16.0, *)
public enum LayoutEngine {
    /// Lay out `score` into a `LayoutDocument`. Equivalent to the
    /// cache-aware overload with `cache: nil` — every per-measure
    /// computation runs from scratch.
    public static func layout(
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat
    ) -> LayoutDocument {
        layout(
            score: score,
            options: options,
            availableWidth: availableWidth,
            cache: nil
        )
    }

    /// Cache-aware overload. Reuse the same `LayoutCache` instance
    /// across edits and unchanged measures will skip per-measure
    /// recomputation.
    ///
    /// The cache is rebuilt in place each call: prior entries are
    /// kept only when their inputs match the current call.
    public static func layout(
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat,
        cache: LayoutCache?
    ) -> LayoutDocument {
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let effectiveMelismaTicks = computeEffectiveMelismaTicks(
            score: score, division: score.division
        )
        let melismas = computeMelismaContinuations(
            score: score, division: score.division,
            effectiveTicks: effectiveMelismaTicks
        )
        let context = RenderContext(
            score: score,
            options: options,
            metrics: metrics,
            availableWidth: availableWidth,
            melismaContinuations: melismas,
            effectiveMelismaTicks: effectiveMelismaTicks,
            cache: cache
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
                metrics: metrics,
                docWidth: max(
                    availableWidth,
                    packedSystems.reduce(CGFloat(0)) { acc, s in
                        max(acc, s.origin.x + s.size.width)
                    }
                )
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
            metrics: metrics
        )
        // Add a small right margin so the last barline doesn't
        // touch the canvas edge.
        let docWidth = totalWidth + metrics.sp * 2
        let firstPass = LayoutDocument(
            size: CGSize(width: docWidth, height: totalHeight),
            systems: systemsWithSpanners,
            metrics: metrics,
            titleFrame: titleFrame
        )
        let ties = resolveTies(for: firstPass, score: score)
        let systemsWithTies = attachTies(
            to: systemsWithSpanners, pairs: ties, metrics: metrics
        )
        return LayoutDocument(
            size: firstPass.size,
            systems: systemsWithTies,
            metrics: metrics,
            titleFrame: titleFrame
        )
    }

    static func shift(
        _ system: LayoutSystem, byY dy: CGFloat
    ) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(
                x: system.origin.x, y: system.origin.y + dy
            ),
            size: system.size,
            measures: system.measures,
            staffOrigins: system.staffOrigins,
            partLabels: system.partLabels,
            brackets: system.brackets,
            spanners: system.spanners,
            sp: system.sp
        )
    }

    private static func buildTitleFrame(
        source: ScoreFrame,
        metrics: StaffMetrics,
        docWidth: CGFloat
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
            let dy = (t.offsetMm?.y ?? 0) * mmToPt
            let topY: CGFloat
            let fontSize: CGFloat
            switch t.style {
            case .title:
                topY = 0; fontSize = 22
            case .subtitle:
                topY = 10 * mmToPt; fontSize = 14
            case .other:
                topY = 10 * mmToPt + CGFloat(idx) * 4 * mmToPt
                fontSize = 10
            case .composer, .lyricist:
                continue // anchored to frame bottom — no top-side overflow
            }
            let bottom = topY + dy + fontSize * textHeightFactor
            if bottom > requiredFromTopAnchors {
                requiredFromTopAnchors = bottom
            }
        }
        let frameHeight = max(
            metrics.sp * 4,
            source.heightSp * metrics.sp,
            requiredFromTopAnchors
        )
        let center = docWidth / 2

        var laidOut: [LayoutFrameText] = []
        for (idx, t) in source.texts.enumerated() {
            // Defaults sourced from MuseScore's
            // `engraving/style/styledef.cpp`:
            //   Title    — Align(HCENTER, TOP),    offset (0,  0) mm, font 22pt
            //   Subtitle — Align(HCENTER, TOP),    offset (0, 10) mm, font 14pt
            //   Composer — Align(RIGHT,   BOTTOM), offset (0,  0) mm, font 10pt
            //   Lyricist — Align(LEFT,    BOTTOM), offset (0,  0) mm, font 10pt
            // All four are `FontStyle::Normal` (no bold / italic).
            // `<Text>` inline `<b>` / `<font>` markup is stripped
            // at parse time.
            let fontSize: CGFloat
            let baseY: CGFloat
            let baseX: CGFloat
            let anchor: LayoutFrameText.Anchor
            switch t.style {
            case .title:
                fontSize = 22
                baseY = 0
                baseX = center
                anchor = .top
            case .subtitle:
                fontSize = 14
                baseY = 10 * mmToPt
                baseX = center
                anchor = .top
            case .composer:
                fontSize = 10
                baseY = frameHeight
                baseX = docWidth
                anchor = .bottomTrailing
            case .lyricist:
                fontSize = 10
                baseY = frameHeight
                baseX = 0
                anchor = .bottomLeading
            case .other:
                fontSize = 10
                baseY = 10 * mmToPt
                    + CGFloat(idx) * 4 * mmToPt
                baseX = center
                anchor = .top
            }
            let dx = (t.offsetMm?.x ?? 0) * mmToPt
            let dy = (t.offsetMm?.y ?? 0) * mmToPt
            laidOut.append(LayoutFrameText(
                text: t.text,
                style: t.style,
                position: CGPoint(x: baseX + dx, y: baseY + dy),
                fontSize: fontSize,
                anchor: anchor
            ))
        }
        return LayoutTitleFrame(
            height: frameHeight, texts: laidOut
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
    }
}
