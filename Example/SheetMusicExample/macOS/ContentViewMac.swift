#if os(macOS)
import AppKit
import SheetMusic
import SheetMusicAudio
import SheetMusicPDF
import SheetMusicUI
import SwiftUI
import UniformTypeIdentifiers

private enum LayoutMode: String {
    case horizontal = "Horizontal"
    case vertical = "Vertical"
    case paged = "Page"
    /// Mirrors the PDF export's pagination — same page size, margin,
    /// and packing logic as `PDFExporter` — but laid out side-by-side
    /// in a horizontal scroll view so you can review what the PDF
    /// will look like before saving.
    case pdf = "PDF"
}

@available(macOS 15.0, *)
struct ContentViewMac: View {
    @State private var score: Score?
    @State private var sourceName = "(none)"
    @State private var errorMessage: String?
    @State private var magnification: CGFloat = 1.0
    @State private var layoutMode: LayoutMode = .horizontal
    @State private var pageIndex = 0
    @State private var totalPages = 1
    @State private var selection: ScoreSelection = .none
    /// Pre-computed layout for the current vertical viewport width.
    /// Rebuilt on width / score / mode changes; passed into both
    /// ScoreView (for rendering) and ScoreHitTester (for tap
    /// mapping), so layout runs at most once per change instead of
    /// twice per click.
    @State private var verticalDoc: LayoutDocument?
    /// Pre-computed layout for horizontal mode (one long system at
    /// natural content width). Rebuilt on mode / score changes.
    @State private var horizontalDoc: LayoutDocument?
    /// Per-measure clef / key / time / part-label state. Cached so
    /// the sticky header doesn't recompute it on every body re-eval
    /// (an O(measures × staves) walk that adds up during pinch /
    /// scroll). Refilled when a new score loads.
    @State private var horizontalContexts: [LayoutMeasureContext] = []
    /// Live document-space X of the visible left edge in horizontal
    /// mode. Drives the sticky header overlay.
    @State private var horizontalScrollX: CGFloat = 0
    /// Live document-space Y of the visible top edge. When the user
    /// has zoomed in past the viewport height, the score scrolls
    /// vertically; the sticky pane offsets by this value so its
    /// clef stays attached to the staff.
    @State private var horizontalScrollY: CGFloat = 0
    /// Bumped whenever a new score is loaded so that `.task(id:)`
    /// observers know to rebuild their layouts even if width and
    /// mode did not change.
    @State private var scoreVersion = UUID()
    /// Audio engine for single-note preview + full-score playback.
    /// Held as `@StateObject` so SwiftUI re-evaluates the play / pause
    /// button label and the playback cursor whenever the engine's
    /// `@Published` `state` / `currentCursor` change.
    @StateObject private var playbackEngine = PlaybackEngine(
        soundfontResolver: BundledSoundfontResolver())
    /// Local NSEvent monitor that turns the spacebar into a play /
    /// pause toggle (MuseScore convention). Stored so we can remove
    /// it on disappear.
    @State private var keyMonitor: Any?
    /// Live magnification factor for PDF preview mode (driven by
    /// pinch-to-zoom). Persists across score / mode changes so the
    /// user doesn't lose their zoom level when switching tabs.
    /// Current magnification of the PDF preview, driven by
    /// `NSScrollView.magnification` via `MagnifyingPDFScrollView`.
    /// Persists across mode / score swaps so the user's zoom level
    /// survives.
    @State private var pdfScale: CGFloat = 1.0
    /// Cached PDF-mode layout. Recomputed via `.task(id:)` only on
    /// score change, NOT on every pinch frame — `LayoutEngine.layout`
    /// is expensive on large scores and re-running it per frame
    /// makes the pinch crawl.
    @State private var pdfDoc: LayoutDocument?
    @State private var pdfPages: [PDFExporter.PageBatch] = []

    /// Live frames of each system in the vertical ScrollView's
    /// "vScroll" coordinate space. Drives the on-/off-screen check
    /// in `autoScrollVertical` directly — no scroll-offset
    /// arithmetic.
    @State private var verticalSystemFrames: [Int: CGRect] = [:]
    /// Vertical scroll offset of the SwiftUI vertical-mode scroll
    /// view, mirrored from a PreferenceKey reader.
    /// Pending programmatic scroll target for the horizontal
    /// `MagnifyingScoreScrollView`, in document coords. The wrapper
    /// animates to it and resets the binding to nil. Set by the
    /// auto-scroll path during playback.
    @State private var pendingHorizontalScroll: CGPoint?

    /// Per-voice highlight colors (MuseScore convention: voice 1 blue,
    /// voice 2 green, voice 3 orange, voice 4 purple). The library
    /// provides no defaults — this dictionary lives entirely in the app.
    private let voiceColors: [Int: Color] = [
        0: .blue,
        1: .green,
        2: .orange,
        3: .purple
    ]

    private static let verticalOptions = ScoreViewOptions(
        staffSize: 18, systemGap: 16, wrapToViewWidth: true)
    private static let horizontalOptions = ScoreViewOptions(
        staffSize: 28, systemGap: 40, wrapToViewWidth: false,
        includeTitleFrame: false)

    var body: some View {
        NavigationSplitView {
            List {
                Section("Bundled") {
                    Button("Load test.mscx") {
                        loadBundled()
                    }
                }
                Section("Playback") {
                    HStack {
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
                        .help("Metronome (toggles during playback)")

                        Spacer()

                        Text(playbackStateLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Space = play / pause")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Section("Export") {
                    Button("Save as PDF…") {
                        exportPDF()
                    }
                    .disabled(score == nil)
                }
                Section("Layout") {
                    Picker("Mode", selection: $layoutMode) {
                        Label("Horizontal", systemImage: "arrow.left.and.right")
                            .tag(LayoutMode.horizontal)
                        Label("Vertical", systemImage: "arrow.up.and.down")
                            .tag(LayoutMode.vertical)
                        Label("Page", systemImage: "book.pages")
                            .tag(LayoutMode.paged)
                        Label("PDF", systemImage: "doc.text")
                            .tag(LayoutMode.pdf)
                    }
                    .pickerStyle(.inline)
                }
                if layoutMode == .paged {
                    Section("Page") {
                        Text("\(min(pageIndex, totalPages - 1) + 1) / \(totalPages)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Prev") {
                                if pageIndex > 0 { pageIndex -= 1 }
                            }
                            .disabled(pageIndex <= 0)
                            Button("Next") {
                                if pageIndex < totalPages - 1 {
                                    pageIndex += 1
                                }
                            }
                            .disabled(pageIndex >= totalPages - 1)
                        }
                    }
                }
                Section("Zoom") {
                    Text("\(Int(magnification * 100))%")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Reset (100%)") {
                        magnification = 1.0
                    }
                    .disabled(abs(magnification - 1.0) < 0.001)
                }
                Section("State") {
                    Text(sourceName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let message = errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if let score {
                scoreContent(score: score)
            } else {
                ContentUnavailableView(
                    "No score loaded",
                    systemImage: "music.note.list",
                    description: Text(
                        "Load the bundled test.mscx from the sidebar."))
            }
        }
        .onAppear(perform: loadBundled)
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    private var playbackStateLabel: String {
        switch playbackEngine.state {
        case .stopped: return "stopped"
        case .playing: return "playing"
        case .paused: return "paused"
        }
    }

    private func exportPDF() {
        guard let score else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (sourceName as NSString)
            .deletingPathExtension + ".pdf"
        panel.canCreateDirectories = true
        panel.title = "Save Score as PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PDFExporter.export(
                score: score,
                to: url,
                options: PDFExporter.Options(
                    title: (sourceName as NSString).deletingPathExtension))
            // Reveal the resulting file so the user can inspect it
            // without hunting through Finder.
            NSWorkspace.shared.activateFileViewerSelecting([url])
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

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // keyCode 49 is spacebar on every keyboard layout (it's a
        // physical-key code). Skip auto-repeat so a held space
        // doesn't toggle dozens of times per second.
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { event in
            if event.keyCode == 49 && !event.isARepeat {
                togglePlayback()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    @ViewBuilder
    private func scoreContent(score: Score) -> some View {
        switch layoutMode {
        case .vertical:
            GeometryReader { geo in
                let width = geo.size.width - 32
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
                            .padding()
                        }
                    }
                    .coordinateSpace(name: "vScroll")
                    .onPreferenceChange(VerticalSystemFramesKey.self) { f in
                        verticalSystemFrames = f
                    }
                    .onChange(of: playbackEngine.currentCursor) { newCursor in
                        autoScrollVertical(
                            cursor: newCursor,
                            doc: verticalDoc,
                            score: score,
                            viewportHeight: geo.size.height,
                            proxy: proxy)
                    }
                }
                .task(id: VerticalLayoutKey(
                    width: width, scoreVersion: scoreVersion)
                ) {
                    verticalDoc = LayoutEngine.layout(
                        score: score,
                        options: Self.verticalOptions,
                        availableWidth: max(100, width))
                }
            }
        case .horizontal:
            // Native NSScrollView handles pinch-zoom-around-cursor
            // reliably; a SwiftUI-only implementation fought
            // ScrollPosition's asynchronous updates.
            if let doc = horizontalDoc {
                let inset = MagnifyingScoreScrollView.contentInset
                // Bracket position in hostingView coords (unmag).
                // The bracket sits half a space to the LEFT of the
                // first staff's leading edge — see
                // `ScoreCanvas.swift:91-104` /
                // `ScoreLayerBuilder.drawBracket`. The sticky
                // pane's visibility threshold and its horizontal
                // shift both pivot on this position, so when the
                // score's bracket reaches the viewport's leading
                // edge the sticky takes over with its own bracket
                // landing at the exact same viewport X.
                let staffStartDocX = doc.systems.first?
                    .staffOrigins.first?.x ?? 0
                let bracketDocX = staffStartDocX
                    - doc.metrics.sp / 2
                let bracketHostingX = inset + bracketDocX
                // Score-relative X (unmagnified) of the leftmost
                // visible score pixel.
                let scoreScrollX = max(
                    0, horizontalScrollX - inset)
                // The measure to display in the sticky is driven by
                // its TRAILING edge, not the leftmost-visible pixel
                // (which is hidden behind the pane). That way the
                // displayed measure number flips the moment the
                // NEXT measure's leading barline crosses the pane's
                // trailing edge — i.e. the moment that measure
                // becomes the first thing the user actually sees.
                let stickyLookupX = doc.stickyTrailingX(
                    scoreScrollX: scoreScrollX,
                    measureContexts: horizontalContexts)
                // Hide the sticky until the user has scrolled far
                // enough that the score's bracket has reached the
                // viewport's leading edge. Below that the bracket
                // and everything that follows it are still in
                // their natural unscrolled positions, so showing
                // the sticky would only duplicate what's already
                // on screen.
                ZStack(alignment: .topLeading) {
                    MagnifyingScoreScrollView(
                        document: doc, score: score,
                        magnification: $magnification,
                        documentScrollX: $horizontalScrollX,
                        documentScrollY: $horizontalScrollY,
                        pendingScrollTarget: $pendingHorizontalScroll,
                        selection: selection,
                        voiceColors: voiceColors,
                        playbackCursor: playbackEngine.currentCursor,
                        onTap: { loc in
                            handleTap(at: loc, document: doc)
                        })
                        .background(
                            GeometryReader { hgeo in
                                Color.clear
                                    .onChange(of: playbackEngine.currentCursor) { newCursor in
                                        autoScrollHorizontal(
                                            cursor: newCursor, doc: doc,
                                            score: score,
                                            viewportWidth: hgeo.size.width)
                                    }
                            })
                    if horizontalScrollX > bracketHostingX {
                        StickyHeaderView(
                            document: doc,
                            measureContexts: horizontalContexts,
                            documentScrollX: stickyLookupX)
                            // Match the score's `.padding(inset)`
                            // exactly so vertical alignment is
                            // identical: leading + top padding put
                            // the sticky's white area at the same
                            // (inset, inset) corner as the score's
                            // own white background.
                            .padding(.leading, inset)
                            .padding(.top, inset)
                            // Track vertical scroll: the sticky's
                            // staves stay locked to the score's
                            // staves when zoomed past the viewport
                            // height. Horizontally, shift left by
                            // `bracketHostingX` so the pane's
                            // bracket renders at viewport x = 0 —
                            // exactly where the score's bracket
                            // sits at the visibility threshold,
                            // making the transition seamless and
                            // every other element (clef / key /
                            // time / staff name) overlap its
                            // counterpart at that scroll amount.
                            .offset(
                                x: -bracketHostingX,
                                y: -horizontalScrollY)
                            .scaleEffect(
                                magnification, anchor: .topLeading)
                            .allowsHitTesting(false)
                    }
                }
                // Confine the sticky to the same rect the score
                // scroll view occupies — without this, scaleEffect's
                // overflow can paint into the sidebar / window
                // toolbar, since SwiftUI doesn't auto-clip
                // transformed content. `.contentShape` keeps tap
                // hit-testing aligned with the visible region.
                .clipped()
                .contentShape(Rectangle())
            }
        case .paged:
            let opts = ScoreViewOptions(
                staffSize: 18, systemGap: 16,
                wrapToViewWidth: true)
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
        let pageSize = PDFExporter.Options.usLetter
        let margin: CGFloat = 36

        Group {
            if let doc = pdfDoc, !pdfPages.isEmpty {
                pdfPreviewContent(
                    doc: doc, pages: pdfPages,
                    pageSize: pageSize, margin: margin)
            } else {
                ProgressView("Laying out…")
                    .frame(
                        maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(white: 0.92))
            }
        }
        .task(id: scoreVersion) {
            // Same knobs as `Save as PDF…` so the on-screen pages
            // match the file the user would get from PDFExporter.
            let pdfStaffSize: CGFloat = 14
            let pdfOpts = ScoreViewOptions(
                staffSize: pdfStaffSize,
                systemGap: 16,
                wrapToViewWidth: true)
            let availableWidth = max(
                pdfStaffSize * 4, pageSize.width - 2 * margin)
            let doc = LayoutEngine.layout(
                score: score, options: pdfOpts,
                availableWidth: availableWidth)
            pdfDoc = doc
            pdfPages = PDFExporter.paginate(
                systems: doc.systems,
                pageSize: pageSize, margin: margin)
        }
    }

    @ViewBuilder
    private func pdfPreviewContent(
        doc: LayoutDocument,
        pages: [PDFExporter.PageBatch],
        pageSize: CGSize,
        margin: CGFloat
    ) -> some View {
        // Hosting the page deck inside an `NSScrollView` with
        // `allowsMagnification = true` mirrors how horizontal mode
        // stays sharp during pinch: AppKit re-rasterises the layer
        // tree at the new contents scale instead of bitmap-
        // upscaling a fixed-resolution snapshot. PDFPageView's own
        // `renderScale` stays at 1 — the scroll view supplies the
        // zoom.
        MagnifyingPDFScrollView(
            magnification: $pdfScale,
            doc: doc,
            pages: pages,
            pageSize: pageSize,
            margin: margin)
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
        let shift = NSEvent.modifierFlags.contains(.shift)

        // Beam without shift: range-select every note under the beam
        // run. This is our app-side policy — MuseScore would instead
        // let you edit the beam's length; we don't need that here.
        if case let .beam(notes) = target, !shift,
           let first = notes.first, let last = notes.last {
            selection = .range(
                anchor: .note(first), target: .note(last))
            return
        }

        // Everything else resolves to one "primary" ScoreItemID:
        //   - note/rest: themselves
        //   - stem/flag: the chord's first notehead
        //   - beam (with shift): the chord's first notehead
        let primary: ScoreItemID
        switch target {
        case .note(let id): primary = .note(id)
        case .rest(let id): primary = .rest(id)
        case .stem(let notes), .flag(let notes), .beam(let notes):
            guard let first = notes.first else {
                selection = .none
                return
            }
            primary = .note(first)
        }

        if shift {
            switch selection {
            case .none:
                selection = .single(primary)
            case .single(let anchor):
                selection = .range(anchor: anchor, target: primary)
            case .range(let anchor, _):
                selection = .range(anchor: anchor, target: primary)
            }
        } else {
            selection = .single(primary)
            // MuseScore-style: a click on a single note triggers a
            // brief preview playback of just that note. Skip when
            // shift is held (extending a range) or for non-note
            // targets (rests, stems on chords without notes).
            if case .note(let id) = primary, let score {
                playbackEngine.playPreview(
                    noteID: id, in: score)
            }
        }
    }

    /// Re-evaluated on every cursor change (chord / rest level).
    /// When the cursor's system has no overlap with the visible
    /// band, scroll the nearest staff edge to the matching
    /// viewport edge:
    ///
    ///   * Off-screen below → bottom staff bottom → viewport
    ///     bottom.
    ///   * Off-screen above → top staff top → viewport top.
    ///
    /// The system-overlap visibility check is itself the dedup:
    /// once the scroll lands, the system overlaps the viewport
    /// and subsequent chord / rest changes short-circuit.
    private func autoScrollVertical(
        cursor: ScoreCursor?,
        doc: LayoutDocument?,
        score: Score,
        viewportHeight: CGFloat,
        proxy: ScrollViewProxy
    ) {
        guard playbackEngine.state == .playing,
              let cursor, let doc
        else { return }
        let mi = cursor.measureIndex
        guard let sys = doc.systemIndex(forMeasureIndex: mi),
              let frame = verticalSystemFrames[sys]
        else { return }
        // Any partial overhang triggers a scroll. When the anchor
        // is taller than the viewport (nothing we can do), fall
        // back to "any overlap" to avoid oscillating.
        let fits = frame.height <= viewportHeight
        let visible = fits
            ? (frame.minY >= 0 && frame.maxY <= viewportHeight)
            : (frame.maxY > 0 && frame.minY < viewportHeight)
        if visible { return }
        // Leave `pad` between the matching staff edge and viewport
        // edge. Custom UnitPoint lets `scrollTo` build that gap
        // directly — see iOS `paddedAnchor` for the derivation.
        // `denom <= pad` → no room to keep pad without flipping
        // direction; fall back to plain edge alignment.
        let pad: CGFloat = 8 * doc.metrics.sp
        let aboveViewport = frame.minY < 0
        let denom = viewportHeight - frame.height
        let frac: CGFloat
        if denom <= pad {
            frac = aboveViewport ? 0 : 1
        } else if aboveViewport {
            frac = pad / denom
        } else {
            frac = 1 - pad / denom
        }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(
                VerticalSystemAnchorID(systemIndex: sys),
                anchor: UnitPoint(x: 0.5, y: frac))
        }
    }

    /// Same idea for horizontal mode: snap the measure to the
    /// leading edge via the wrapper's pending-scroll target.
    /// Goes through `MagnifyingScoreScrollView`'s
    /// `pendingScrollTarget` binding, which animates with
    /// `NSAnimationContext`.
    private func autoScrollHorizontal(
        cursor: ScoreCursor?,
        doc: LayoutDocument,
        score: Score,
        viewportWidth: CGFloat
    ) {
        guard playbackEngine.state == .playing,
              let cursor,
              let cursorRect = doc.cursorFrame(for: cursor, in: score),
              let origin = doc.measureOrigin(measureIndex: cursor.measureIndex)
        else { return }
        let inset = MagnifyingScoreScrollView.contentInset
        // `horizontalScrollX` lives in document / clip-view coords;
        // converting to doc coords removes the `inset`-padding
        // around the score so we compare in the same frame as
        // `cursorRect`. Pinch-zoom shrinks the doc-coord region
        // visible inside the clip view: `clipView.bounds.size =
        // clipView.frame.size / magnification`. So the visible
        // doc-coord width is the screen-space `viewportWidth`
        // divided by the live magnification.
        let mag = max(0.01, magnification)
        let visibleDocWidth = viewportWidth / mag
        let visibleDocLeft = horizontalScrollX - inset
        let visibleDocRight = visibleDocLeft + visibleDocWidth
        let cursorVisible = cursorRect.minX >= visibleDocLeft
            && cursorRect.maxX <= visibleDocRight
        if cursorVisible { return }
        // Target: measure leading edge so the measure lands at the
        // visible leading edge after the scroll. Reads back through
        // the clipView coord space (= horizontalScrollX's frame),
        // which is offset from doc by `inset`.
        let targetX = max(0, origin.x)
        pendingHorizontalScroll = CGPoint(
            x: targetX, y: horizontalScrollY)
    }

    private func loadBundled() {
        guard
            let url = Bundle.main.url(
                forResource: "test", withExtension: "mscx")
        else {
            errorMessage = "Bundled test.mscx not found."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try SheetMusic.loadScore(mscxData: data)
            // Pre-build the horizontal layout synchronously. It
            // doesn't depend on the viewport (uses the score's
            // natural content width), so there's no reason to defer
            // it to a .task — and an if-let gated Group can fail
            // to trigger .task(id:) when it starts empty.
            let hOpts = Self.horizontalOptions
            horizontalDoc = LayoutEngine.layout(
                score: loaded, options: hOpts,
                availableWidth: LayoutEngine.naturalContentWidth(
                    score: loaded, options: hOpts))
            horizontalContexts = LayoutEngine.measureContexts(
                for: loaded)
            // Vertical layout still needs the viewport width, so
            // it's built by a .task in the .vertical case.
            verticalDoc = nil
            score = loaded
            sourceName = url.lastPathComponent
            errorMessage = nil
            scoreVersion = UUID()
            selection = .none
            pendingHorizontalScroll = nil
            // (Re)build samplers + timeline for this score. SoundFont
            // loading is potentially slow on first call (tens of ms
            // per file), so do it off-main; the score renders before
            // the first preview is requested in practice. If no SF2
            // is bundled the resolver returns nil and the engine
            // stays silent.
            let engine = playbackEngine
            Task.detached(priority: .userInitiated) { [loaded] in
                try? engine.prepare(score: loaded)
            }
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }
}

private struct VerticalLayoutKey: Hashable {
    let width: CGFloat
    let scoreVersion: UUID
}

// MARK: - NSScrollView wrapper for pinch-to-zoom

/// Hosts a SwiftUI `ScoreView` inside an `NSScrollView` that provides
/// native pinch-to-zoom-around-cursor.
///
/// SwiftUI's own `ScrollView` + `MagnifyGesture` can be coordinated
/// manually, but the commit-time scroll offset update fights
/// concurrent content-size changes and the anchor drifts in
/// small-content axes.  AppKit already solves this with
/// `NSScrollView.allowsMagnification`, so we bridge instead of
/// reinventing it.
@available(macOS 15.0, *)
private struct MagnifyingScoreScrollView: NSViewRepresentable {
    /// Padding (in document/unmagnified points) around the ScoreView
    /// inside the hosting view. Known so the click handler can
    /// subtract it when converting hosting-view coords to doc coords.
    static let contentInset: CGFloat = 16

    let document: LayoutDocument
    let score: Score
    @Binding var magnification: CGFloat
    /// Document-space X (unmagnified) of the visible left edge.
    /// Updated live as the user scrolls so a sticky header pane
    /// overlay can re-render its clef / key / time / measure-number
    /// state to match the leftmost visible measure.
    @Binding var documentScrollX: CGFloat
    /// Document-space Y (unmagnified) of the visible top edge.
    /// When the user zooms in past the viewport height, the score
    /// scrolls vertically too — the sticky pane needs to ride the
    /// same offset so its clef stays glued to the staff lines.
    @Binding var documentScrollY: CGFloat
    /// Programmatic scroll target in document coords. When set,
    /// the wrapper animates the clip view to that point and
    /// resets the binding to `nil`. Used by the playback auto-
    /// scroll path during full-score playback.
    @Binding var pendingScrollTarget: CGPoint?
    let selection: ScoreSelection
    let voiceColors: [Int: Color]
    let playbackCursor: ScoreCursor?
    let onTap: (CGPoint) -> Void

    private var rootView: AnyView {
        AnyView(
            ScoreView(
                document: document, score: score,
                selection: selection,
                voiceColors: voiceColors,
                playbackCursor: playbackCursor)
                .padding(Self.contentInset))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.usesPredominantAxisScrolling = false

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        // Use an NSClickGestureRecognizer rather than SwiftUI's
        // `.onTapGesture` because SwiftUI does NOT compensate for
        // NSScrollView's magnification transform — the tap location
        // it reports drifts off the clicked note as soon as zoom
        // leaves 100 %. `gr.location(in:)` returns coords in the
        // hosting view's own (unmagnified) coord space, so we land
        // on the correct notehead at any zoom level.
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:)))
        click.buttonMask = 0x1
        hosting.addGestureRecognizer(click)

        context.coordinator.hostingView = hosting
        context.coordinator.magnificationBinding = $magnification
        context.coordinator.documentScrollXBinding = $documentScrollX
        context.coordinator.documentScrollYBinding = $documentScrollY
        context.coordinator.contentInset = Self.contentInset
        context.coordinator.onTap = onTap
        // Seed the change-detection cache with the values we just
        // installed in `rootView`, so `updateNSView`'s short-circuit
        // doesn't re-render on the first benign re-eval.
        context.coordinator.lastSelection = selection
        context.coordinator.lastVoiceColors = voiceColors
        context.coordinator.lastDocumentSize = document.size
        context.coordinator.lastPlaybackCursor = playbackCursor

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidEnd(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView)
        // Pinch gesture: NSScrollView fires bounds-changed every
        // frame while magnifying because clipView's size shrinks
        // / grows around the magnification anchor. Each such
        // notification would invalidate the SwiftUI binding and
        // force a full body re-eval (and an NSHostingView refresh
        // of the score), making pinch feel laggy on big scores.
        // Track the live-magnify state so `boundsDidChange` can
        // bail out until the gesture finishes — we then fire one
        // catch-up update from `magnificationDidEnd`.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.willStartLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView)

        // Track the document-space scroll offset live. NSClipView's
        // bounds change every frame during a scroll; we mirror it
        // into the SwiftUI binding so an outer overlay (sticky
        // header pane) can re-render in sync.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.magnificationBinding = $magnification
        coord.documentScrollXBinding = $documentScrollX
        coord.documentScrollYBinding = $documentScrollY
        coord.onTap = onTap

        // Skip the rootView reassignment when none of its inputs
        // actually changed. SwiftUI re-evaluates this view's body
        // every time `documentScrollX` updates (60-120 Hz during
        // scroll), and assigning a fresh `AnyView` makes
        // NSHostingView walk the SwiftUI tree top-to-bottom each
        // time. Comparing `selection` and `voiceColors` is O(few
        // entries), so this guard pays for itself many times over.
        let selectionChanged = coord.lastSelection != selection
        let voiceColorsChanged = coord.lastVoiceColors != voiceColors
        let documentChanged = coord.lastDocumentSize != document.size
        let cursorChanged = coord.lastPlaybackCursor != playbackCursor
        if selectionChanged || voiceColorsChanged
            || documentChanged || cursorChanged {
            coord.hostingView?.rootView = rootView
            coord.lastSelection = selection
            coord.lastVoiceColors = voiceColors
            coord.lastDocumentSize = document.size
            coord.lastPlaybackCursor = playbackCursor
        }

        // Apply external magnification changes (e.g., sidebar reset
        // button) without clobbering a value we just reported. Skip
        // during live pinch — the gesture itself is driving
        // `nsView.magnification`, and writing it back from a
        // mid-gesture binding update would fight the gesture
        // handler (causing visible jitter / glitches at frame
        // boundaries).
        if !coord.isLiveMagnifying
            && abs(nsView.magnification - magnification) > 0.001 {
            nsView.magnification = magnification
        }

        // Programmatic scroll-to (auto-follow during playback).
        // The `pendingScrollTarget != lastHandledScrollTarget` check
        // makes this a one-shot per request: SwiftUI re-evaluates
        // this body on every body input change, so without the
        // guard we'd re-issue the animation each time.
        if let target = pendingScrollTarget,
           target != coord.lastHandledScrollTarget {
            coord.lastHandledScrollTarget = target
            let clipView = nsView.contentView
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = .init(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                clipView.animator().setBoundsOrigin(target)
                nsView.reflectScrolledClipView(clipView)
            }, completionHandler: {
                DispatchQueue.main.async { pendingScrollTarget = nil }
            })
        } else if pendingScrollTarget == nil {
            coord.lastHandledScrollTarget = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentInset: Self.contentInset)
    }

    final class Coordinator: NSObject {
        var contentInset: CGFloat
        var hostingView: NSHostingView<AnyView>?
        var magnificationBinding: Binding<CGFloat>?
        var documentScrollXBinding: Binding<CGFloat>?
        var documentScrollYBinding: Binding<CGFloat>?
        var onTap: ((CGPoint) -> Void)?
        /// Set while the user is actively pinching. The score's
        /// NSScrollView drives its own magnification via Core
        /// Animation; we mustn't write back to `nsView.magnification`
        /// while the gesture is in progress (it would fight the
        /// gesture handler), but we still want to mirror its current
        /// value into the SwiftUI binding so the sticky pane's
        /// scaleEffect tracks the score live.
        var isLiveMagnifying = false
        /// Last `pendingScrollTarget` value the coordinator has
        /// already animated to. Compared against the current binding
        /// in `updateNSView` so the same request isn't re-issued on
        /// every body re-eval.
        var lastHandledScrollTarget: CGPoint?
        /// KVO observation of `NSScrollView.magnification`. Active
        /// only between will-start and did-end live magnification —
        /// AppKit fires no "during" notification, so we observe the
        /// property directly to push live values into the SwiftUI
        /// binding at gesture frame rate.
        var magnificationObservation: NSKeyValueObservation?
        /// Last `rootView` inputs we actually applied. Used to skip
        /// the NSHostingView refresh when only the scroll binding
        /// changed (the common case during scroll / pinch).
        var lastSelection: ScoreSelection = .none
        var lastVoiceColors: [Int: Color] = [:]
        var lastDocumentSize: CGSize = .zero
        var lastPlaybackCursor: ScoreCursor?

        init(contentInset: CGFloat) {
            self.contentInset = contentInset
        }

        @objc func handleClick(_ gr: NSClickGestureRecognizer) {
            guard let hosting = hostingView else { return }
            let local = gr.location(in: hosting)
            // `.padding(inset)` shifts the ScoreView inside the
            // hosting view by (inset, inset); subtract it back out
            // to get coords in the document/ScoreView coord space.
            let docPoint = CGPoint(
                x: local.x - contentInset,
                y: local.y - contentInset)
            onTap?(docPoint)
        }

        @objc func willStartLiveMagnify(_ notification: Notification) {
            isLiveMagnifying = true
            // Observe the scroll view's magnification at gesture
            // frame rate so the sticky pane's scaleEffect can
            // track in lock-step. AppKit doesn't post a "during
            // live magnify" notification — KVO is the only
            // continuous signal available.
            guard let scrollView = notification.object as? NSScrollView
            else { return }
            magnificationObservation = scrollView.observe(
                \.magnification, options: [.new]
            ) { [weak self] _, change in
                guard let self, let value = change.newValue else { return }
                self.magnificationBinding?.wrappedValue = value
            }
        }

        @objc func magnificationDidEnd(_ notification: Notification) {
            isLiveMagnifying = false
            magnificationObservation = nil
            guard let scrollView = notification.object as? NSScrollView
            else { return }
            magnificationBinding?.wrappedValue = scrollView.magnification
            // Catch-up: any final bounds frame that landed on the
            // exact gesture-end boundary should be reflected in the
            // bindings.
            let bounds = scrollView.contentView.bounds
            documentScrollXBinding?.wrappedValue = bounds.origin.x
            documentScrollYBinding?.wrappedValue = bounds.origin.y
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView
            else { return }
            // Pass the raw clipView origin through, even when it
            // briefly slips below zero (over-scroll up / left) or
            // past the document end (over-scroll down / right).
            // The sticky pane needs to follow the elastic bounce so
            // it stays glued to the staves; clamping here would
            // make it freeze at the document edge instead. The
            // visibility check (`horizontalScrollX > 0`) and the
            // measure lookup (`max(0, …)`) absorb negative values
            // downstream without misbehaving.
            //
            // We let this fire during pinch as well: the sticky
            // needs to follow the magnify-anchor's scroll shift
            // live. Body re-evaluation stays cheap thanks to the
            // cached `measureContexts`, the rootView short-circuit
            // in `updateNSView`, and `_LayerBackedSystem`'s
            // identity check — the layer tree doesn't rebuild when
            // the synthetic system is structurally identical.
            documentScrollXBinding?.wrappedValue =
                clipView.bounds.origin.x
            documentScrollYBinding?.wrappedValue =
                clipView.bounds.origin.y
        }
    }
}

// MARK: - PDF preview scroll wrapper

/// Hosts the PDF page deck inside an `NSScrollView` whose
/// `allowsMagnification` does the heavy lifting. AppKit re-
/// rasterises the document layer at the current magnification —
/// SwiftUI Canvas drawings stay vector-sharp at any zoom level
/// without us having to redraw them per pinch frame, exactly the
/// way horizontal mode keeps the score sharp during pinch.
@available(macOS 15.0, *)
private struct MagnifyingPDFScrollView: NSViewRepresentable {
    @Binding var magnification: CGFloat
    let doc: LayoutDocument
    let pages: [PDFExporter.PageBatch]
    let pageSize: CGSize
    let margin: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.usesPredominantAxisScrolling = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.92, alpha: 1)

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        scrollView.magnification = magnification
        context.coordinator.binding = $magnification
        context.coordinator.lastDocId = ObjectIdentifier(
            doc.systems as AnyObject)

        // NSScrollView fires `didEndLiveMagnify` once after the
        // gesture settles; we mirror its final value into the
        // SwiftUI binding so a future external write (e.g. a
        // "Reset zoom" button) can apply.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidEnd(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView)
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.willStartLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.binding = $magnification
        // Rebuild the rootView only when the cached layout actually
        // changed — body re-evals during scroll / magnify shouldn't
        // walk the whole page deck again.
        let newDocId = ObjectIdentifier(doc.systems as AnyObject)
        if context.coordinator.lastDocId != newDocId
            || context.coordinator.lastPageCount != pages.count {
            (nsView.documentView as? NSHostingView<AnyView>)?
                .rootView = rootView
            context.coordinator.lastDocId = newDocId
            context.coordinator.lastPageCount = pages.count
        }
        // Apply external magnification writes (e.g. a sidebar
        // reset). Skip while the user is mid-pinch — writing back
        // during a live gesture would fight AppKit's own update.
        if !context.coordinator.isLiveMagnifying
            && abs(nsView.magnification - magnification) > 0.001 {
            nsView.magnification = magnification
        }
    }

    private var rootView: AnyView {
        AnyView(
            HStack(alignment: .top, spacing: 24) {
                ForEach(Array(pages.enumerated()), id: \.offset) { idx, page in
                    VStack(spacing: 6) {
                        // Layer-tree page (vector CAShapeLayers) so
                        // NSScrollView's `allowsMagnification` re-
                        // rasterises the contents at the new scale
                        // — sharp throughout the pinch, exactly like
                        // horizontal mode's score view.
                        PDFPageLayerView(
                            systems: page.systems,
                            pageStartY: page.startY,
                            titleFrame: idx == 0 ? doc.titleFrame : nil,
                            metrics: doc.metrics,
                            pageSize: pageSize,
                            margin: margin)
                            .frame(
                                width: pageSize.width,
                                height: pageSize.height)
                            .border(Color.gray.opacity(0.4))
                            .shadow(radius: 3)
                        Text("\(idx + 1) / \(pages.count)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var binding: Binding<CGFloat>?
        var lastDocId: ObjectIdentifier?
        var lastPageCount: Int = -1
        var isLiveMagnifying = false

        @objc func willStartLiveMagnify(_ notification: Notification) {
            isLiveMagnifying = true
        }

        @objc func magnificationDidEnd(_ notification: Notification) {
            isLiveMagnifying = false
            guard let scrollView = notification.object as? NSScrollView
            else { return }
            binding?.wrappedValue = scrollView.magnification
        }
    }
}
#endif
