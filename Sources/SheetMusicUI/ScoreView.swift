import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SwiftUI

/// Read-only SwiftUI view that renders a `Score`.
///
/// Bundles the Bravura SMuFL font for glyph drawing.
///
/// Both modes render `SystemLayerView` CALayer trees inside a
/// `ZStack`, positioned by each system's document-coordinate
/// `origin`; neither slices the music into per-system SwiftUI
/// `Canvas` views any more.
///
/// **Vertical scroll mode** (`wrapToViewWidth: true`): systems wrap
/// to a width chosen, in order, from `options.fixedLayoutWidth`, the
/// `availableWidth` argument, or an internal `GeometryReader`. Set
/// `fixedLayoutWidth` when the engraving must NOT re-flow as the
/// container resizes — the view then sizes itself to the layout and
/// the host scrolls or zooms it.
///
/// **Horizontal scroll mode** (`wrapToViewWidth: false`): all
/// measures stay on one system laid out at its natural width;
/// `fixedLayoutWidth` and `availableWidth` are both ignored.
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
    private let visibleRect: CGRect?

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
        visibleRect = nil
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
    ///
    /// `visibleRect`, in `document` coordinates, limits what is mounted:
    /// only the systems whose frame meets it get a layer tree, and within
    /// a system that it does not span from end to end, only the measures
    /// whose frame meets it and the system-level spanners whose span
    /// does. That second half is what a horizontal document needs, being
    /// one system. Pass the viewport already grown by however much should
    /// be ready beyond it — the view adds no margin of its own. `nil`, the
    /// default, mounts everything. The view keeps the document's full
    /// size either way, so scrolling, hit testing and anything else that
    /// maps document coordinates is unaffected; what is not mounted is
    /// simply not drawn.
    public init(
        document: LayoutDocument,
        score: Score,
        options: ScoreViewOptions = .init(),
        selection: ScoreSelection = .none,
        voiceColors: [Int: Color] = [:],
        playbackCursor: ScoreCursor? = nil,
        playbackCursorColor: Color = Color.blue.opacity(0.15),
        visibleRect: CGRect? = nil,
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
        self.visibleRect = visibleRect
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
            if let w = Self.resolvedWrapWidth(
                options: options, explicitWidth: explicitWidth,
            ) {
                let doc = LayoutEngine.layout(
                    score: score, options: options,
                    availableWidth: w,
                )
                systemStack(doc: doc, selection: selState)
            } else {
                GeometryReader { proxy in
                    let w = Self.flooredWrapWidth(
                        proxy.size.width, options: options,
                    )
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
            // Identified by the system's index in the WHOLE document, so
            // a system keeps its view (and its layer tree) as others
            // mount and unmount around it.
            ForEach(Self.mountedSystemIndices(of: doc, in: visibleRect), id: \.self) { index in
                let sys = doc.systems[index]
                SystemLayerView(
                    system: sys, metrics: doc.metrics,
                    selection: selection,
                    visibleXRange: Self.visibleXRange(of: sys, in: visibleRect),
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
                        // Horizontal mode honors no breaks at
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

@available(macOS 15.0, *)
extension ScoreView {
    /// Indices of the systems whose frame meets `visibleRect`, in document
    /// order — every index when it is `nil`. A system's frame is one point
    /// taller than its `size`, matching the overlap `SystemLayerView`
    /// draws to hide the seam between stacked systems.
    nonisolated static func mountedSystemIndices(of doc: LayoutDocument, in visibleRect: CGRect?) -> [Int] {
        guard let visibleRect else { return Array(doc.systems.indices) }
        return doc.systems.indices.filter { index in
            let system = doc.systems[index]
            return system.origin.y + system.size.height + 1 >= visibleRect.minY
                && system.origin.y <= visibleRect.maxY
        }
    }

    /// Indices of the frames between systems (`LayoutDocument.frames`) that `visibleRect` meets, by the systems'
    /// test, one point of slack below each included — every index when it is `nil`.
    ///
    /// W7 Task 14 Phase A stub: mounts none yet.
    nonisolated static func mountedFrameIndices(of doc: LayoutDocument, in visibleRect: CGRect?) -> [Int] {
        []
    }

    /// The part of `system` that `visibleRect` reaches, in the system's
    /// own X, for `SystemLayerView` to mount — or `nil`, mount it all,
    /// when there is no rect or it spans the system from end to end.
    ///
    /// The second `nil` is not just a shortcut: a vertical reader passes
    /// a band as wide as the document, and mapping that to "every measure
    /// meets it" would put every system of every vertical document
    /// through the measure-by-measure path for nothing.
    nonisolated static func visibleXRange(
        of system: LayoutSystem, in visibleRect: CGRect?,
    ) -> ClosedRange<CGFloat>? {
        guard let visibleRect else { return nil }
        let lower = visibleRect.minX - system.origin.x
        let upper = visibleRect.maxX - system.origin.x
        guard lower > 0 || upper < system.size.width else { return nil }
        return lower ... max(lower, upper)
    }

    /// The wrap width when it can be decided without measuring the
    /// container, with the minimum-width floor already applied.
    ///
    /// Precedence: `options.fixedLayoutWidth` (the host pinned it),
    /// then the `availableWidth` the caller passed. `nil` means the
    /// caller has to fall back to a `GeometryReader` — and returning
    /// `nil` for the fixed case in horizontal mode is deliberate:
    /// `fixedLayoutWidth` is documented as ignored when
    /// `wrapToViewWidth` is false.
    static func resolvedWrapWidth(
        options: ScoreViewOptions,
        explicitWidth: CGFloat?,
    ) -> CGFloat? {
        guard options.wrapToViewWidth else { return nil }
        guard let raw = options.fixedLayoutWidth ?? explicitWidth else {
            return nil
        }
        return flooredWrapWidth(raw, options: options)
    }

    /// Clamp a wrap width to something the engine can lay a staff out
    /// in. Four staff heights is the historical floor; a zero or
    /// negative container width (a collapsed `GeometryReader` during
    /// the first layout pass) would otherwise reach the packer.
    static func flooredWrapWidth(
        _ raw: CGFloat,
        options: ScoreViewOptions,
    ) -> CGFloat {
        max(raw, options.staffSize * 4)
    }
}
