#if !os(macOS)
import SheetMusic
import SheetMusicAudio
import SheetMusicPDF
import SheetMusicUI
import SwiftUI
import UIKit

private enum LayoutMode: Int {
    case vertical, horizontal, paged, pdf
}

struct ContentView: View {
    @State private var score: Score?
    @State private var errorMessage: String?
    @State private var layoutMode: LayoutMode = .vertical
    @State private var staffSize: CGFloat = 14
    @State private var pageIndex = 0
    @State private var totalPages = 1
    @State private var selection: ScoreSelection = .none
    /// Pre-computed layout for the vertical viewport. Rebuilt on
    /// width / staffSize / score changes; shared by ScoreView and
    /// ScoreHitTester so layout runs once per change instead of
    /// twice per tap.
    @State private var verticalDoc: LayoutDocument?
    /// Pre-computed natural-width layout for the horizontal viewport.
    /// Used to drive the same auto-scroll path as vertical mode.
    @State private var horizontalDoc: LayoutDocument?
    @State private var scoreVersion = UUID()
    /// Live frames of each system (vertical mode) / measure
    /// (horizontal mode) in the corresponding scroll view's named
    /// coordinate space. Updated continuously via anchor previews,
    /// so the auto-scroll heuristic can ask "is the cursor's row
    /// on screen *right now*?" without doing scroll-offset math.
    @State private var verticalSystemFrames: [Int: CGRect] = [:]
    @State private var horizontalMeasureFrames: [Int: CGRect] = [:]
    /// Audio engine for single-note preview + full-score playback.
    /// Stays silent until the user drops a SoundFont into `Sounds/`
    /// (see `BundledSoundfontResolver`). Held as a `@StateObject` so
    /// SwiftUI re-renders the play/pause button label and the
    /// playback cursor whenever the engine's `@Published` `state` /
    /// `currentCursor` changes.
    @StateObject private var playbackEngine = PlaybackEngine(
        soundfontResolver: BundledSoundfontResolver())
    /// Set when the user taps the share button. Drives the
    /// `.sheet` modifier that presents `UIActivityViewController`
    /// for the freshly-exported PDF.
    @State private var pdfShareItem: PDFShareItem?
    /// Live magnification factor for PDF preview mode (driven by
    /// pinch-to-zoom). Persists across score / mode changes so the
    /// user doesn't lose their zoom level when switching tabs.
    @State private var pdfScale: CGFloat = 1.0
    /// Live overlay scale applied via `scaleEffect` during an active
    /// pinch — cheap visual upscale that avoids re-rasterising every
    /// page Canvas at gesture frame rate. Always 1.0 outside a
    /// pinch; on gesture end we fold it into `pdfScale` (which
    /// drives the Canvas's true `renderScale`) so the result is
    /// vector-sharp once the user releases.
    @State private var pdfGestureScale: CGFloat = 1.0
    /// Cached PDF-mode layout. Recomputed via `.task(id:)` only on
    /// score change, NOT on every pinch frame — `LayoutEngine.layout`
    /// is expensive on large scores and re-running it per frame
    /// makes the pinch crawl.
    @State private var pdfDoc: LayoutDocument?
    @State private var pdfPages: [PDFExporter.PageBatch] = []

    /// Per-voice highlight colors (MuseScore convention). iOS has no
    /// keyboard shift, so this example only supports single-note
    /// selection — range selection is a macOS-only demo for now.
    private let voiceColors: [Int: Color] = [
        0: .blue,
        1: .green,
        2: .orange,
        3: .purple
    ]

    var body: some View {
        NavigationStack {
            Group {
                if let score {
                    scoreContent(score: score)
                } else if let error = errorMessage {
                    VStack {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("Loading…")
                }
            }
            .navigationTitle("Sheet Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        togglePlayback()
                    } label: {
                        Image(systemName: playbackEngine.state == .playing
                            ? "pause.fill" : "play.fill")
                    }
                    .disabled(score == nil)

                    Button {
                        playbackEngine.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .disabled(playbackEngine.state == .stopped)

                    Button {
                        playbackEngine.isMetronomeEnabled.toggle()
                    } label: {
                        Image(systemName: playbackEngine.isMetronomeEnabled
                            ? "metronome.fill" : "metronome")
                    }

                    Button {
                        exportPDF()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(score == nil)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        staffSize = max(8, staffSize - 2)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .disabled(staffSize <= 8)

                    Button {
                        staffSize = min(32, staffSize + 2)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .disabled(staffSize >= 32)

                    Picker("Layout", selection: $layoutMode) {
                        Image(systemName: "arrow.up.and.down")
                            .tag(LayoutMode.vertical)
                        Image(systemName: "arrow.left.and.right")
                            .tag(LayoutMode.horizontal)
                        Image(systemName: "book.pages")
                            .tag(LayoutMode.paged)
                        Image(systemName: "doc.text")
                            .tag(LayoutMode.pdf)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }
        }
        .onAppear(perform: loadBundled)
        .sheet(item: $pdfShareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func exportPDF() {
        guard let score else { return }
        do {
            let data = try PDFExporter.export(
                score: score,
                options: PDFExporter.Options(title: "test"))
            // Write to a temp file so UIActivityViewController can
            // share it (Mail / Files / AirDrop / Save to Files).
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("test-\(UUID().uuidString.prefix(8)).pdf")
            try data.write(to: url)
            pdfShareItem = PDFShareItem(url: url)
        } catch {
            errorMessage = "PDF export failed: \(error.localizedDescription)"
        }
    }

    private func togglePlayback() {
        guard let score else { return }
        switch playbackEngine.state {
        case .playing:
            playbackEngine.pause()
        case .paused, .stopped:
            // Cursor wins over selection: a cursor left behind by
            // the last pause is the user's "current playback
            // position", and a stale selection from before that
            // pause shouldn't override it. The cursor is dropped
            // explicitly by `handleTap` when the user makes a NEW
            // selection — at that point we fall through to the
            // selection branch.
            let from: ScoreCursor? = playbackEngine.currentCursor
                ?? selectionPlayFrom.map { .item($0) }
            playbackEngine.play(from: from, in: score)
        }
    }

    private var selectionPlayFrom: ScoreItemID? {
        switch selection {
        case .none: return nil
        case .single(let id): return id
        case .range(let anchor, let target):
            // Whichever corner is earlier in playback time wins —
            // shift-click order doesn't determine playback start.
            return playbackEngine.earliest(of: [anchor, target])
                ?? anchor
        }
    }

    @ViewBuilder
    private func scoreContent(score: Score) -> some View {
        let gap = staffSize * (layoutMode == .horizontal ? 1.5 : 0.85)
        let opts = ScoreViewOptions(
            staffSize: staffSize,
            systemGap: gap,
            wrapToViewWidth: layoutMode != .horizontal,
            includeTitleFrame: layoutMode != .horizontal)
        switch layoutMode {
        case .vertical:
            GeometryReader { geo in
                let width = geo.size.width - 16
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        if let doc = verticalDoc {
                            ZStack(alignment: .topLeading) {
                                ScoreView(
                                    document: doc, score: score,
                                    selection: selection,
                                    voiceColors: voiceColors,
                                    playbackCursor: playbackEngine.currentCursor)
                                    .onTapGesture { loc in
                                        handleTap(at: loc, document: doc)
                                    }
                                VerticalSystemAnchors(document: doc)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 16)
                        }
                    }
                    .coordinateSpace(name: "vScroll")
                    .onPreferenceChange(VerticalSystemFramesKey.self) { f in
                        verticalSystemFrames = f
                    }
                    .onChange(of: playbackEngine.currentCursor) { newCursor in
                        autoScroll(
                            cursor: newCursor, doc: verticalDoc,
                            score: score,
                            axis: .vertical,
                            viewport: geo.size, proxy: proxy)
                    }
                }
                .task(id: VerticalLayoutKey(
                    width: width,
                    staffSize: staffSize,
                    scoreVersion: scoreVersion)
                ) {
                    verticalDoc = LayoutEngine.layout(
                        score: score, options: opts,
                        availableWidth: max(100, width))
                }
            }
        case .horizontal:
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        if let doc = horizontalDoc {
                            ZStack(alignment: .topLeading) {
                                ScoreView(
                                    document: doc, score: score,
                                    selection: selection,
                                    voiceColors: voiceColors,
                                    playbackCursor: playbackEngine.currentCursor)
                                HorizontalMeasureAnchors(document: doc)
                            }
                            .frame(minHeight: geo.size.height)
                            .padding(16)
                        }
                    }
                    .coordinateSpace(name: "hScroll")
                    .onPreferenceChange(HorizontalMeasureFramesKey.self) { f in
                        horizontalMeasureFrames = f
                    }
                    .onChange(of: playbackEngine.currentCursor) { newCursor in
                        autoScroll(
                            cursor: newCursor, doc: horizontalDoc,
                            score: score,
                            axis: .horizontal,
                            viewport: geo.size, proxy: proxy)
                    }
                }
                .task(id: HorizontalLayoutKey(
                    staffSize: staffSize,
                    scoreVersion: scoreVersion)
                ) {
                    let natural = LayoutEngine.naturalContentWidth(
                        score: score, options: opts)
                    horizontalDoc = LayoutEngine.layout(
                        score: score, options: opts,
                        availableWidth: natural)
                }
            }
        case .paged:
            ZStack {
                PagedScoreView(
                    score: score, options: opts,
                    pageIndex: $pageIndex,
                    totalPages: $totalPages)
                HStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if pageIndex > 0 { pageIndex -= 1 }
                        }
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if pageIndex < totalPages - 1 {
                                pageIndex += 1
                            }
                        }
                }
            }
            .overlay(alignment: .bottom) {
                Text("\(min(pageIndex, totalPages - 1) + 1) / \(totalPages)")
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 8)
            }
        case .pdf:
            pdfPreview(score: score)
        }
    }

    @ViewBuilder
    private func pdfPreview(score: Score) -> some View {
        // Pull page size, margins, staff size from the score's
        // `<Style>` block via `PDFExporter.resolve` — the same call
        // path the share-button export uses, so the preview is a
        // truthful proxy for the PDF the user gets.
        let resolved = PDFExporter.resolve(
            options: PDFExporter.Options(), score: score)

        Group {
            if let doc = pdfDoc, !pdfPages.isEmpty {
                pdfPreviewContent(
                    doc: doc, pages: pdfPages,
                    page: resolved.page)
            } else {
                ProgressView("Laying out…")
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.92))
            }
        }
        .task(id: scoreVersion) {
            let pdfOpts = ScoreViewOptions(
                staffSize: resolved.staffSize,
                systemGap: 16,
                wrapToViewWidth: true)
            let availableWidth = max(
                resolved.staffSize * 4,
                resolved.page.size.width
                    - resolved.page.oddMargins.leading
                    - resolved.page.oddMargins.trailing)
            let doc = LayoutEngine.layout(
                score: score, options: pdfOpts,
                availableWidth: availableWidth)
            pdfDoc = doc
            pdfPages = PDFExporter.paginate(
                systems: doc.systems, page: resolved.page)
        }
    }

    @ViewBuilder
    private func pdfPreviewContent(
        doc: LayoutDocument,
        pages: [PDFExporter.PageBatch],
        page: EngravingPage
    ) -> some View {
        let pageSize = page.size
        let pageSpacing: CGFloat = 16 * pdfScale
        let outerPadding: CGFloat = 16 * pdfScale
        let labelHeight: CGFloat = 14 * pdfScale + 6 * pdfScale
        let naturalWidth =
            pageSize.width * pdfScale * CGFloat(pages.count)
            + pageSpacing * CGFloat(max(0, pages.count - 1))
            + outerPadding * 2
        let naturalHeight =
            pageSize.height * pdfScale + labelHeight
            + outerPadding * 2

        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: pageSpacing) {
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, batch in
                    VStack(spacing: 6 * pdfScale) {
                        // PDFPageView's `renderScale` makes the
                        // Canvas draw glyphs at the new resolution
                        // — vector-sharp instead of an upscaled
                        // bitmap. We only update it on gesture-end
                        // (committed `pdfScale`); during the active
                        // pinch the cheap `scaleEffect` overlay
                        // handles motion smoothly.
                        PDFPageView(
                            systems: batch.systems,
                            pageStartY: batch.startY,
                            titleFrame: idx == 0 ? doc.titleFrame : nil,
                            metrics: doc.metrics,
                            pageSize: pageSize,
                            margins: page.margins(forPageIndex: idx),
                            renderScale: pdfScale)
                            .background(Color.white)
                            .border(Color.gray.opacity(0.4))
                            .shadow(radius: 3 * pdfScale)
                        Text("\(idx + 1) / \(pages.count)")
                            .font(.system(size: 11 * pdfScale))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(outerPadding)
            // Apply the gesture overlay AFTER padding so the whole
            // page deck zooms uniformly. `scaleEffect` is visual-
            // only; the explicit frame tells the parent ScrollView
            // the scaled extent so it can scroll the full zoomed
            // area during the gesture.
            .scaleEffect(pdfGestureScale, anchor: .topLeading)
            .frame(
                width: naturalWidth * pdfGestureScale,
                height: naturalHeight * pdfGestureScale,
                alignment: .topLeading)
        }
        .background(Color(white: 0.92))
        .gesture(
            MagnificationGesture()
                .onChanged { rawValue in
                    let target = pdfScale * rawValue
                    let clamped = max(0.25, min(4.0, target))
                    pdfGestureScale = clamped / pdfScale
                }
                .onEnded { _ in
                    pdfScale = max(
                        0.25, min(4.0, pdfScale * pdfGestureScale))
                    pdfGestureScale = 1
                })
    }

    private func handleTap(at location: CGPoint, document: LayoutDocument) {
        let tester = ScoreHitTester(document: document)
        guard let target = tester.hitTest(at: location) else {
            selection = .none
            return
        }
        // A fresh, deliberate selection drops the playback cursor
        // (no-op while playing). The next `togglePlayback` then
        // reads the selection instead of the stale cursor.
        playbackEngine.clearCursor()
        switch target {
        case .note(let id):
            selection = .single(.note(id))
            // MuseScore-style preview on tap.
            if let score {
                playbackEngine.playPreview(
                    noteID: id, in: score)
            }
        case .rest(let id):
            selection = .single(.rest(id))
        case .stem(let notes), .flag(let notes):
            if let first = notes.first {
                selection = .single(.note(first))
                if let score {
                    playbackEngine.playPreview(
                        noteID: first, in: score)
                }
            }
        case .beam(let notes):
            if let first = notes.first, let last = notes.last {
                selection = .range(
                    anchor: .note(first), target: .note(last))
            }
        }
    }

    /// Re-evaluate visibility on every cursor change — `onChange`
    /// of an `@Published` cursor fires per chord / rest step the
    /// playback engine takes. When the cursor's row (system in
    /// vertical mode, measure in horizontal mode) has no overlap
    /// with the visible viewport, scroll its nearest edge to the
    /// viewport's nearest edge:
    ///
    ///   * Off-screen below → bottom staff's bottom → viewport
    ///     bottom (`anchor: .bottom`).
    ///   * Off-screen above → top staff's top → viewport top
    ///     (`anchor: .top`).
    ///
    /// Visibility uses the live frame of each anchor in the scroll
    /// view's named coordinate space, reported by the anchor
    /// views. That avoids the lag and races of trying to derive a
    /// scalar scroll offset from a `PreferenceKey`. The visibility
    /// check itself acts as the natural dedup: once a scroll lands
    /// the system in the viewport, subsequent chord / rest changes
    /// within it short-circuit.
    private func autoScroll(
        cursor: ScoreCursor?,
        doc: LayoutDocument?,
        score: Score,
        axis: ScrollAxis,
        viewport: CGSize,
        proxy: ScrollViewProxy
    ) {
        guard playbackEngine.state == .playing,
              let cursor, let doc
        else { return }
        let mi = cursor.measureIndex

        let pad: CGFloat = 8 * doc.metrics.sp
        switch axis {
        case .vertical:
            // Anchor frame spans the system's staff range in
            // "vScroll" coords; y = 0 is the viewport top, y =
            // viewport.height the viewport bottom.
            guard let sys = doc.systemIndex(forMeasureIndex: mi),
                  let frame = verticalSystemFrames[sys]
            else { return }
            if isFullyVisible(
                anchorMin: frame.minY, anchorMax: frame.maxY,
                anchorSize: frame.height,
                viewportSize: viewport.height
            ) { return }
            let unit = paddedAnchor(
                aboveViewport: frame.minY < 0,
                anchorSize: frame.height,
                viewportSize: viewport.height,
                pad: pad,
                horizontal: false)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(
                    VerticalSystemAnchorID(systemIndex: sys),
                    anchor: unit)
            }
        case .horizontal:
            guard let frame = horizontalMeasureFrames[mi]
            else { return }
            if isFullyVisible(
                anchorMin: frame.minX, anchorMax: frame.maxX,
                anchorSize: frame.width,
                viewportSize: viewport.width
            ) { return }
            let unit = paddedAnchor(
                aboveViewport: frame.minX < 0,
                anchorSize: frame.width,
                viewportSize: viewport.width,
                pad: pad,
                horizontal: true)
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(
                    HorizontalMeasureAnchorID(measureIndex: mi),
                    anchor: unit)
            }
        }
    }

    /// Treat the cursor as "visible" only when fully inside the
    /// viewport — any partial overhang triggers a scroll. The
    /// exception: when the anchor itself is bigger than the
    /// viewport (nothing we can do), fall back to "any overlap"
    /// to avoid oscillating between top and bottom alignment.
    private func isFullyVisible(
        anchorMin: CGFloat,
        anchorMax: CGFloat,
        anchorSize: CGFloat,
        viewportSize: CGFloat
    ) -> Bool {
        if anchorSize > viewportSize {
            return anchorMax > 0 && anchorMin < viewportSize
        }
        return anchorMin >= 0 && anchorMax <= viewportSize
    }

    /// Build a `UnitPoint` that, when passed to `ScrollViewReader.
    /// scrollTo(_, anchor:)`, leaves `pad` points between the
    /// staff edge and the matching viewport edge.
    ///
    /// `scrollTo` aligns target's anchor point with viewport's
    /// anchor point — same `UnitPoint` for both. With `y_unit = y`:
    ///
    ///     scrollOffset = target.minY + y * (target.height - viewport.height)
    ///
    /// To place target.minY at `pad` (i.e. top-aligned with `pad`
    /// inset), solve for y → `y = pad / (viewport - target)`.
    /// Bottom-aligned with `pad` inset is the mirror:
    /// `y = 1 - pad / (viewport - target)`.
    ///
    /// When `target >= viewport` the staff is bigger than the
    /// viewport — there's no room for padding, so fall back to
    /// plain `.top` / `.bottom`.
    private func paddedAnchor(
        aboveViewport: Bool,
        anchorSize: CGFloat,
        viewportSize: CGFloat,
        pad: CGFloat,
        horizontal: Bool
    ) -> UnitPoint {
        let denom = viewportSize - anchorSize
        // `denom <= pad` means there's no room to keep `pad` on the
        // chosen side without pushing the opposite edge off — fall
        // back to plain edge alignment so we don't flip direction.
        let frac: CGFloat
        if denom <= pad {
            frac = aboveViewport ? 0 : 1
        } else if aboveViewport {
            frac = pad / denom
        } else {
            frac = 1 - pad / denom
        }
        return horizontal
            ? UnitPoint(x: frac, y: 0.5)
            : UnitPoint(x: 0.5, y: frac)
    }

    enum ScrollAxis { case vertical, horizontal }

    private func loadBundled() {
        guard let url = Bundle.main.url(
            forResource: "test", withExtension: "mscx")
        else {
            errorMessage = "Bundled test.mscx not found."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try SheetMusic.loadScore(mscxData: data)
            score = loaded
            verticalDoc = nil
            horizontalDoc = nil
            scoreVersion = UUID()
            selection = .none
            // (Re)build samplers for this score. SoundFont parsing
            // can take tens of ms per file; offloading keeps the
            // first-paint latency low even on iPhone.
            let engine = playbackEngine
            Task.detached(priority: .userInitiated) { [loaded] in
                try? engine.prepare(score: loaded)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct VerticalLayoutKey: Hashable {
    let width: CGFloat
    let staffSize: CGFloat
    let scoreVersion: UUID
}

private struct HorizontalLayoutKey: Hashable {
    let staffSize: CGFloat
    let scoreVersion: UUID
}

private struct PDFShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
#endif
