#if !os(macOS)
import SheetMusic
import SheetMusicAudio
import SheetMusicPDF
import SheetMusicUI
import SwiftUI
import UIKit

enum IOSLayoutMode: Int {
    case vertical, horizontal, paged, pdf
}

struct ContentView: View {
    @State private var score: Score?
    @State private var errorMessage: String?
    @State private var layoutMode: IOSLayoutMode = .vertical
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
    /// Drives the `.fileImporter` sheet for loading arbitrary
    /// `.mscx` / `.mscz` / `.musicxml` / `.mxl` documents from the
    /// user's iCloud or local file storage.
    @State private var isImportingFile = false
    /// Live magnification factor for PDF preview mode (driven by
    /// pinch-to-zoom). Persists across score / mode changes so the
    /// user doesn't lose their zoom level when switching tabs.
    @State private var pdfScale: CGFloat = 1.0
    /// Cached PDF-mode layout. Recomputed via `.task(id:)` only on
    /// score change, NOT on every pinch frame — `LayoutEngine.layout`
    /// is expensive on large scores and re-running it per frame
    /// makes the pinch crawl.
    @State private var pdfLayout: PDFPreviewLayout?
    /// Mixer sheet visibility — toolbar mixer button toggles it.
    @State private var isMixerPresented = false
    /// When true, vertical-mode drags become marquee selections
    /// instead of falling through to scroll. Toggled from the
    /// toolbar; OFF restores normal tap/scroll behaviour.
    @State private var isMarqueeMode = false
    /// Active marquee rectangle in vertical-mode local coords.
    /// `nil` outside an in-progress drag; the overlay reads this
    /// to draw the live selection rectangle.
    @State private var marqueeRect: CGRect?

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
                ContentToolbar(
                    playbackEngine: playbackEngine,
                    score: score,
                    layoutMode: $layoutMode,
                    staffSize: $staffSize,
                    isMixerPresented: $isMixerPresented,
                    isImportingFile: $isImportingFile,
                    isMarqueeMode: $isMarqueeMode,
                    onTogglePlayback: togglePlayback,
                    onExportPDF: exportPDF)
            }
        }
        .onAppear(perform: loadBundled)
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: ScoreFileType.allUTTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .sheet(item: $pdfShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $isMixerPresented) {
            NavigationStack {
                MixerView(engine: playbackEngine)
                    .padding()
                    .navigationTitle("Mixer")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { isMixerPresented = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
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
        playbackEngine.togglePlayback(
            score: score, selection: selection)
    }

    @ViewBuilder
    private func scoreContent(score: Score) -> some View {
        // Per-system gap. Horizontal mode laps systems side-by-side
        // so this is unused there but we keep the ratio consistent.
        // MuseScore's `Sid::minSystemDistance = 8.5 sp` is the
        // engraving target between vertical-mode systems; with our
        // staff-distance pads already covering ~3.5 sp below the
        // last lyric staff, ~5 sp more here lands us in MuseScore's
        // territory without crowding the page.
        let gap = staffSize * 1.25
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
                                    voiceColors: exampleVoiceColors,
                                    playbackCursor: playbackEngine.currentCursor)
                                    .onTapGesture { loc in
                                        guard !isMarqueeMode else { return }
                                        handleTap(at: loc, document: doc)
                                    }
                                    .gesture(
                                        isMarqueeMode
                                            ? marqueeDragGesture(document: doc)
                                            : nil)
                                    .overlay(
                                        MarqueeOverlay(rect: marqueeRect))
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
                                    voiceColors: exampleVoiceColors,
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
        Group {
            if let layout = pdfLayout {
                PDFPreviewView(
                    doc: layout.doc, pages: layout.pages,
                    page: layout.page,
                    pdfScale: $pdfScale)
            } else {
                ProgressView("Laying out…")
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.92))
            }
        }
        .task(id: scoreVersion) {
            pdfLayout = PDFPreviewLayout.build(score: score)
        }
    }

    private func handleTap(at location: CGPoint, document: LayoutDocument) {
        let tester = ScoreHitTester(document: document)
        let target = tester.hitTest(at: location)

        // While playing: tapping a note seeks audio to that note
        // without disturbing the user's selection. Tapping empty
        // space is ignored — we don't clear the selection mid-play.
        if playbackEngine.state == .playing {
            if let id = primaryItemID(of: target) {
                playbackEngine.seek(to: .item(id))
            }
            return
        }

        guard let target else {
            selection = .none
            return
        }
        // A fresh, deliberate selection drops the playback cursor
        // (no-op while playing — we already returned above). The next
        // `togglePlayback` then reads the selection instead of the
        // stale cursor.
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

    /// Drag gesture used while marquee mode is on. Uses
    /// `minimumDistance: 0` so a tap+release with no movement still
    /// resolves (clears selection if no events fall in the zero
    /// rect). Coordinates are reported in the gesture's local space,
    /// which matches the `ZStack`'s coordinate system — same space
    /// as `LayoutDocument` because the `.padding` wrappers shift the
    /// content but the gesture sits inside the padding.
    private func marqueeDragGesture(
        document: LayoutDocument
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                marqueeRect = makeRect(
                    from: value.startLocation,
                    to: value.location)
            }
            .onEnded { value in
                let rect = makeRect(
                    from: value.startLocation,
                    to: value.location)
                marqueeRect = nil
                applyMarquee(rect: rect, document: document)
            }
    }

    private func makeRect(
        from a: CGPoint, to b: CGPoint
    ) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y))
    }

    private func applyMarquee(
        rect: CGRect, document: LayoutDocument
    ) {
        let tester = ScoreHitTester(document: document)
        let ids = tester.itemIDs(in: rect)
        if ids.isEmpty {
            selection = .none
        } else {
            selection = .multi(Set(ids))
        }
        // A fresh marquee selection drops the playback cursor for
        // the same reason `handleTap` does.
        playbackEngine.clearCursor()
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
            if isAnchorFullyVisible(
                anchorMin: frame.minY, anchorMax: frame.maxY,
                anchorSize: frame.height,
                viewportSize: viewport.height
            ) { return }
            let unit = paddedScrollAnchor(
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
            if isAnchorFullyVisible(
                anchorMin: frame.minX, anchorMax: frame.maxX,
                anchorSize: frame.width,
                viewportSize: viewport.width
            ) { return }
            let unit = paddedScrollAnchor(
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

    enum ScrollAxis { case vertical, horizontal }

    private func loadBundled() {
        do {
            adoptLoadedScore(try ScoreLoader.loadBundled())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Handle the result of `.fileImporter`. The picker hands us a
    /// security-scoped URL — `ScoreLoader.load(from:)` brackets the
    /// read with `startAccessingSecurityScopedResource()` so loads
    /// from iCloud / external storage don't fail with EPERM.
    private func handleFileImport(
        _ result: Result<[URL], Error>
    ) {
        switch result {
        case .failure(let err):
            errorMessage =
                "File picker failed: \(err.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                adoptLoadedScore(try ScoreLoader.load(from: url))
            } catch {
                errorMessage =
                    "Could not load \(url.lastPathComponent): "
                    + error.localizedDescription
            }
        }
    }

    /// Replace the active score with `loaded`, reset cached
    /// per-score view state, kick off background sampler prep.
    private func adoptLoadedScore(_ loaded: Score) {
        score = loaded
        verticalDoc = nil
        horizontalDoc = nil
        pdfLayout = nil
        scoreVersion = UUID()
        selection = .none
        errorMessage = nil
        playbackEngine.prepareInBackground(score: loaded)
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
