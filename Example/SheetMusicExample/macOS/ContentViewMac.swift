#if os(macOS)
import AppKit
import SheetMusic
import SheetMusicAudio
import SheetMusicPDF
import SheetMusicUI
import SwiftUI
import UniformTypeIdentifiers

enum MacLayoutMode: String {
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
    @State private var layoutMode: MacLayoutMode = .horizontal
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
    @State private var pdfLayout: PDFPreviewLayout?

    /// Pending programmatic scroll target for the horizontal
    /// `MagnifyingScoreScrollView`, in document coords. The wrapper
    /// animates to it and resets the binding to nil. Set by the
    /// auto-scroll path during playback.
    @State private var pendingHorizontalScroll: CGPoint?

    // systemGap targets MuseScore's `Sid::minSystemDistance` of
    // 8.5 sp; with our staff-distance pads contributing ~3.5 sp
    // below the last lyric staff, ~5 sp here (≈ 1.25 × staffSize)
    // lands the visible system-to-system gap in MuseScore range.
    private static let verticalOptions = ScoreViewOptions(
        staffSize: 18, systemGap: 22, wrapToViewWidth: true)
    private static let horizontalOptions = ScoreViewOptions(
        staffSize: 28, systemGap: 40, wrapToViewWidth: false,
        includeTitleFrame: false)

    var body: some View {
        NavigationSplitView {
            ContentSidebar(
                playbackEngine: playbackEngine,
                sourceName: sourceName,
                score: score,
                errorMessage: errorMessage,
                layoutMode: $layoutMode,
                pageIndex: $pageIndex,
                totalPages: totalPages,
                magnification: $magnification,
                onLoadBundled: loadBundled,
                onOpenFile: showOpenPanel,
                onTogglePlayback: togglePlayback,
                onExportPDF: exportPDF)
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

    private func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ScoreFileType.allUTTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open Score"
        guard panel.runModal() == .OK,
              let url = panel.url else { return }
        openUserURL(url)
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
        playbackEngine.togglePlayback(
            score: score, selection: selection)
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
            VerticalScoreContainer(
                score: score,
                verticalDoc: $verticalDoc,
                options: Self.verticalOptions,
                scoreVersion: scoreVersion,
                selection: selection,
                voiceColors: exampleVoiceColors,
                playbackCursor: playbackEngine.currentCursor,
                isPlaying: playbackEngine.state == .playing,
                onTap: { loc, doc in
                    handleTap(at: loc, document: doc)
                })
        case .horizontal:
            // Native NSScrollView handles pinch-zoom-around-cursor
            // reliably; a SwiftUI-only implementation fought
            // ScrollPosition's asynchronous updates.
            if let doc = horizontalDoc {
                HorizontalScoreContainer(
                    score: score,
                    document: doc,
                    measureContexts: horizontalContexts,
                    magnification: $magnification,
                    horizontalScrollX: $horizontalScrollX,
                    horizontalScrollY: $horizontalScrollY,
                    pendingHorizontalScroll: $pendingHorizontalScroll,
                    selection: selection,
                    voiceColors: exampleVoiceColors,
                    playbackCursor: playbackEngine.currentCursor,
                    onTap: { loc in
                        handleTap(at: loc, document: doc)
                    },
                    onCursorChange: { newCursor, viewportWidth in
                        autoScrollHorizontalMac(
                            cursor: newCursor, doc: doc,
                            score: score,
                            isPlaying: playbackEngine.state == .playing,
                            viewportWidth: viewportWidth,
                            magnification: magnification,
                            horizontalScrollX: horizontalScrollX,
                            horizontalScrollY: horizontalScrollY,
                            pendingScroll: $pendingHorizontalScroll)
                    })
            }
        case .paged:
            PagedScoreContainer(
                score: score,
                options: ScoreViewOptions(
                    staffSize: 18, systemGap: 16,
                    wrapToViewWidth: true),
                pageIndex: $pageIndex,
                totalPages: $totalPages)
        case .pdf:
            pdfPreview(score: score)
        }
    }

    @ViewBuilder
    private func pdfPreview(score: Score) -> some View {
        Group {
            if let layout = pdfLayout {
                pdfPreviewContent(
                    doc: layout.doc, pages: layout.pages,
                    page: layout.page)
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

    @ViewBuilder
    private func pdfPreviewContent(
        doc: LayoutDocument,
        pages: [PDFExporter.PageBatch],
        page: EngravingPage
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
            page: page)
    }

    private func handleTap(at location: CGPoint, document: LayoutDocument) {
        let tester = ScoreHitTester(document: document)
        let target = tester.hitTest(at: location)

        // While playing: tap-to-seek. Audio jumps to the tapped
        // note while continuing to play; selection (single or
        // range) and any in-flight shift gesture are left alone.
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
            case .multi:
                // Multi has no obvious anchor for range extension;
                // shift-click after a marquee starts a fresh single.
                selection = .single(primary)
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

    private func loadBundled() {
        do {
            let loaded = try ScoreLoader.loadBundled()
            adoptLoadedScore(loaded, sourceName: "test.mscx")
        } catch {
            errorMessage = "Failed: \(error.localizedDescription)"
        }
    }

    /// User-triggered "Open…" via NSOpenPanel. Reads the file at
    /// `url` (any of the formats `ScoreFileType` recognises),
    /// adopts it as the active score.
    func openUserURL(_ url: URL) {
        do {
            let loaded = try ScoreLoader.load(from: url)
            adoptLoadedScore(
                loaded, sourceName: url.lastPathComponent)
        } catch {
            errorMessage =
                "Could not load \(url.lastPathComponent): "
                + error.localizedDescription
        }
    }

    /// Replace the active score with `loaded`, reset cached
    /// per-score view state, kick off background sampler prep.
    /// Mirrors iOS's `adoptLoadedScore` but also rebuilds the
    /// horizontal layout synchronously (macOS uses it in the
    /// horizontal-mode entry path).
    private func adoptLoadedScore(
        _ loaded: Score, sourceName name: String
    ) {
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
        // Vertical layout still needs the viewport width, so it's
        // built by a .task in the .vertical case.
        verticalDoc = nil
        pdfLayout = nil
        score = loaded
        sourceName = name
        errorMessage = nil
        scoreVersion = UUID()
        selection = .none
        pendingHorizontalScroll = nil
        playbackEngine.prepareInBackground(score: loaded)
    }
}
#endif
