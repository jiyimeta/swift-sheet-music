import SheetMusicCore
import SwiftUI

/// Read-only SwiftUI view that renders a `Score`.
///
/// Bundles the Bravura SMuFL font for glyph drawing.
///
/// **Vertical scroll mode** (`wrapToViewWidth: true`): systems are
/// wrapped to the available width and rendered in a `VStack`
/// of per-system `Canvas` views.  Each canvas uses
/// `rendersAsynchronously: true` to keep drawing off the main thread.
///
/// **Horizontal scroll mode** (`wrapToViewWidth: false`): all measures
/// stay on one system, sliced into 600 pt chunks rendered in an
/// `HStack`.
///
/// For correct sizing inside a `ScrollView`, pass the container width
/// via the `availableWidth` parameter (read it with a `GeometryReader`
/// **outside** the scroll view). When omitted, the view falls back to
/// an internal `GeometryReader` which works outside scroll views.
@available(macOS 15.0, iOS 16.0, *)
public struct ScoreView: View {
    private let score: Score
    private let options: ScoreViewOptions
    private let explicitWidth: CGFloat?
    private let providedDocument: LayoutDocument?
    private let selection: ScoreSelection
    private let voiceColors: [Int: Color]
    private let playbackCursor: ScoreCursor?

    public init(
        score: Score,
        options: ScoreViewOptions = .init(),
        selection: ScoreSelection = .none,
        voiceColors: [Int: Color] = [:],
        playbackCursor: ScoreCursor? = nil,
        availableWidth: CGFloat? = nil
    ) {
        _ = BravuraFont.register
        self.score = score
        self.options = options
        self.explicitWidth = availableWidth
        self.providedDocument = nil
        self.selection = selection
        self.voiceColors = voiceColors
        self.playbackCursor = playbackCursor
    }

    /// Render a pre-computed `LayoutDocument` instead of running the
    /// layout engine internally on each body pass.
    ///
    /// Use this when you already hold a `LayoutDocument` (e.g. for a
    /// `ScoreHitTester`, or cached across selection changes). The
    /// caller controls when layout re-runs — typically in response
    /// to `score` / `options` / container-width changes.
    public init(
        document: LayoutDocument,
        score: Score,
        selection: ScoreSelection = .none,
        voiceColors: [Int: Color] = [:],
        playbackCursor: ScoreCursor? = nil
    ) {
        _ = BravuraFont.register
        self.score = score
        self.options = ScoreViewOptions()
        self.explicitWidth = nil
        self.providedDocument = document
        self.selection = selection
        self.voiceColors = voiceColors
        self.playbackCursor = playbackCursor
    }

    public var body: some View {
        let selState = SelectionRenderState.make(
            selection: selection,
            voiceColors: voiceColors,
            score: score)
        if let doc = providedDocument {
            systemStack(doc: doc, selection: selState)
        } else if options.wrapToViewWidth {
            if let ew = explicitWidth {
                let w = max(ew, options.staffSize * 4)
                let doc = LayoutEngine.layout(
                    score: score, options: options,
                    availableWidth: w)
                systemStack(doc: doc, selection: selState)
            } else {
                GeometryReader { proxy in
                    let w = max(proxy.size.width, options.staffSize * 4)
                    let doc = LayoutEngine.layout(
                        score: score, options: options,
                        availableWidth: w)
                    systemStack(doc: doc, selection: selState)
                }
            }
        } else {
            let naturalWidth = LayoutEngine.naturalContentWidth(
                score: score, options: options)
            let doc = LayoutEngine.layout(
                score: score, options: options,
                availableWidth: naturalWidth)
            horizontalStack(doc: doc, selection: selState)
        }
    }

    // MARK: - Vertical (multi-system) stack

    @ViewBuilder
    private func systemStack(
        doc: LayoutDocument,
        selection: SelectionRenderState
    ) -> some View {
        // `.leading` alignment: a system that happens to be narrower
        // than `doc.size.width` (last system not stretched, or a
        // single-system horizontal doc) must pin to x=0 — otherwise
        // SwiftUI's default `.center` centers it, and the visual
        // notehead positions drift rightward off the LayoutEngine's
        // coordinates while ScoreHitTester stays at x=0 — hit zones
        // then fall slightly left of the noteheads.
        // `LazyVStack` so only the visible systems instantiate and
        // paint their CALayer trees — a 100-system score would
        // otherwise render every system on every body re-eval and
        // grind the scroll to a halt. SystemLayerView reports a
        // fixed frame, so the lazy container can size each row
        // without rendering it first.
        //
        // Per-system gap: `LayoutEngine.layout` advances `currentY`
        // by `system.size.height + options.systemGap`, so the
        // difference between two adjacent systems' `origin.y`
        // (minus the upper system's height) IS the configured
        // gap. Reading it back here lets us honour the option
        // without threading it through the `init(document:)`
        // overload, which intentionally discards the original
        // `ScoreViewOptions`.
        let interSystemGap: CGFloat = {
            guard doc.systems.count >= 2 else { return 0 }
            let upper = doc.systems[0]
            let lower = doc.systems[1]
            return max(0, lower.origin.y
                - (upper.origin.y + upper.size.height))
        }()
        ZStack(alignment: .topLeading) {
            // `spacing: 0` keeps the title frame flush with the
            // first system (matching `LayoutEngine`'s `yShift`).
            // The inter-system gap is applied as `.padding(.top)`
            // on every system except the first.
            LazyVStack(alignment: .leading, spacing: 0) {
                if let titleFrame = doc.titleFrame {
                    TitleFrameView(
                        frame: titleFrame, width: doc.size.width)
                }
                ForEach(Array(doc.systems.enumerated()), id: \.offset) { idx, sys in
                    SystemLayerView(
                        system: sys, metrics: doc.metrics,
                        selection: selection)
                        .overlay(alignment: .topLeading) {
                            BreakIndicatorOverlay(
                                mode: .system(system: sys),
                                metrics: doc.metrics)
                        }
                        .padding(.top, idx == 0 ? 0 : interSystemGap)
                }
            }
            PlaybackCursorView(
                cursor: playbackCursor,
                document: doc,
                score: score)
        }
        .frame(width: doc.size.width, alignment: .leading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    // MARK: - Horizontal (single-system) stack

    @ViewBuilder
    private func horizontalStack(
        doc: LayoutDocument,
        selection: SelectionRenderState
    ) -> some View {
        if let system = doc.systems.first {
            // No more 600pt-slice optimisation: each system is one
            // CALayer tree.  CoreAnimation composits off-screen tiles
            // efficiently without manual slicing, and the shared
            // layer tree is what makes future incremental updates
            // (selection highlight, playback cursor) cheap.
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 0) {
                    if let titleFrame = doc.titleFrame {
                        TitleFrameView(
                            frame: titleFrame, width: doc.size.width)
                    }
                    SystemLayerView(
                        system: system, metrics: doc.metrics,
                        selection: selection)
                        .overlay(alignment: .topLeading) {
                            // Horizontal mode honours no breaks at
                            // layout time, but the indicator badges
                            // are still useful as authoring hints.
                            BreakIndicatorOverlay(
                                mode: .system(system: system),
                                metrics: doc.metrics)
                        }
                }
                PlaybackCursorView(
                    cursor: playbackCursor,
                    document: doc,
                    score: score)
            }
            .frame(width: doc.size.width, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        }
    }
}
