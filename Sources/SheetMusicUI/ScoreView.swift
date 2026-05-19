import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
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
@available(macOS 15.0, *)
public struct ScoreView: View {
    private let score: Score
    private let options: ScoreViewOptions
    private let explicitWidth: CGFloat?
    private let providedDocument: LayoutDocument?
    private let selection: ScoreSelection
    private let voiceColors: [Int: Color]
    private let playbackCursor: ScoreCursor?
    private let playbackCursorColor: Color

    public init(
        score: Score,
        options: ScoreViewOptions = .init(),
        selection: ScoreSelection = .none,
        voiceColors: [Int: Color] = [:],
        playbackCursor: ScoreCursor? = nil,
        playbackCursorColor: Color = Color.blue.opacity(0.15),
        availableWidth: CGFloat? = nil,
    ) {
        _ = SheetMusicLayoutApple.install
        self.score = score
        self.options = options
        explicitWidth = availableWidth
        providedDocument = nil
        self.selection = selection
        self.voiceColors = voiceColors
        self.playbackCursor = playbackCursor
        self.playbackCursorColor = playbackCursorColor
    }

    /// Render a pre-computed `LayoutDocument` instead of running the
    /// layout engine internally on each body pass.
    ///
    /// Use this when you already hold a `LayoutDocument` (e.g. for a
    /// `ScoreHitTester`, or cached across selection changes). The
    /// caller controls when layout re-runs — typically in response
    /// to `score` / `options` / container-width changes.
    ///
    /// `options` controls render-time concerns the document doesn't
    /// already bake in — currently `breakIndicatorVisibility` and
    /// `breakPolicy` (used by the indicator overlay). Pass the same
    /// options you used to build `document` so toggles like
    /// "hide break badges" survive the doc handoff.
    public init(
        document: LayoutDocument,
        score: Score,
        options: ScoreViewOptions = .init(),
        selection: ScoreSelection = .none,
        voiceColors: [Int: Color] = [:],
        playbackCursor: ScoreCursor? = nil,
        playbackCursorColor: Color = Color.blue.opacity(0.15),
    ) {
        _ = SheetMusicLayoutApple.install
        self.score = score
        self.options = options
        explicitWidth = nil
        providedDocument = document
        self.selection = selection
        self.voiceColors = voiceColors
        self.playbackCursor = playbackCursor
        self.playbackCursorColor = playbackCursorColor
    }

    public var body: some View {
        let selState = SelectionRenderState.make(
            selection: selection,
            voiceColors: voiceColors,
            score: score,
        )
        if let doc = providedDocument {
            systemStack(doc: doc, selection: selState)
        } else if options.wrapToViewWidth {
            if let ew = explicitWidth {
                let w = max(ew, options.staffSize * 4)
                let doc = LayoutEngine.layout(
                    score: score, options: options,
                    availableWidth: w,
                )
                systemStack(doc: doc, selection: selState)
            } else {
                GeometryReader { proxy in
                    let w = max(proxy.size.width, options.staffSize * 4)
                    let doc = LayoutEngine.layout(
                        score: score, options: options,
                        availableWidth: w,
                    )
                    systemStack(doc: doc, selection: selState)
                }
            }
        } else {
            let naturalWidth = LayoutEngine.naturalContentWidth(
                score: score, options: options,
            )
            let doc = LayoutEngine.layout(
                score: score, options: options,
                availableWidth: naturalWidth,
            )
            horizontalStack(doc: doc, selection: selState)
        }
    }

    // MARK: - Vertical (multi-system) stack

    private func systemStack(
        doc: LayoutDocument,
        selection: SelectionRenderState,
    ) -> some View {
        // Each system is positioned at its doc-coord `origin.y`
        // via `.offset` rather than stacked by a `VStack`. The
        // layout engine bakes `systemGap` into `origin.y` (see
        // `LayoutEngine.swift:194`), so a `VStack(spacing: 0)`
        // would render system N at `N × systemGap` above its
        // doc Y — breaking click-hit-test, the playback cursor's
        // offset, and any external auto-scroll that maps doc Y
        // to view Y.
        //
        // `.topLeading` alignment pins all children to the ZStack's
        // top-leading corner so a system narrower than `doc.size`
        // (last partial system, single-system docs) starts at x=0
        // — otherwise SwiftUI's default centering would drift
        // notehead positions off the LayoutEngine's coords.
        //
        // The title frame (when present) sits at y=0; system
        // `origin.y` already accounts for its height.
        ZStack(alignment: .topLeading) {
            if let titleFrame = doc.titleFrame {
                TitleFrameView(
                    frame: titleFrame, width: doc.size.width,
                )
            }
            ForEach(Array(doc.systems.enumerated()), id: \.offset) { _, sys in
                SystemLayerView(
                    system: sys, metrics: doc.metrics,
                    selection: selection,
                )
                .overlay(alignment: .topLeading) {
                    if options.breakIndicatorVisibility != .none {
                        BreakIndicatorOverlay(
                            mode: .system(system: sys),
                            metrics: doc.metrics,
                            policy: options.breakPolicy,
                            visibility: options.breakIndicatorVisibility,
                        )
                    }
                }
                .offset(y: sys.origin.y)
            }
            PlaybackCursorView(
                cursor: playbackCursor,
                document: doc,
                score: score,
                color: playbackCursorColor,
            )
        }
        .frame(
            width: doc.size.width,
            height: doc.size.height,
            alignment: .topLeading,
        )
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    // MARK: - Horizontal (single-system) stack

    @ViewBuilder
    private func horizontalStack(
        doc: LayoutDocument,
        selection: SelectionRenderState,
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
                            frame: titleFrame, width: doc.size.width,
                        )
                    }
                    SystemLayerView(
                        system: system, metrics: doc.metrics,
                        selection: selection,
                    )
                    .overlay(alignment: .topLeading) {
                        // Horizontal mode honours no breaks at
                        // layout time, but the indicator badges
                        // are still useful as authoring hints.
                        if options.breakIndicatorVisibility != .none {
                            BreakIndicatorOverlay(
                                mode: .system(system: system),
                                metrics: doc.metrics,
                                policy: options.breakPolicy,
                                visibility: options.breakIndicatorVisibility,
                            )
                        }
                    }
                }
                PlaybackCursorView(
                    cursor: playbackCursor,
                    document: doc,
                    score: score,
                    color: playbackCursorColor,
                )
            }
            .frame(width: doc.size.width, alignment: .leading)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        }
    }
}
