#if os(macOS)
    import AppKit
    import PDFKit
    import SheetMusic
    import SheetMusicAudio

    // SwiftySynth playback backend (pure-Swift, MIT): eliminates AUMIDISynth's
    // voice stealing with lightweight SoundFonts, on iOS and macOS alike.
    import SheetMusicAudioSwiftySynth
    import SheetMusicOMRModel
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
        /// The ORIGINAL imported PDF (via `PDFImporter.parseWithGeometry`),
        /// shown as-is with a playback cursor + click-to-seek driven by the
        /// geometry side-car. Only available after importing a PDF.
        case originalPDF = "Original PDF"
    }

    /// One cell of a copied range — captures a contiguous slice of a
    /// single voice within a single measure. Offsets are relative to
    /// the range's top-left corner so paste can drop the same shape at
    /// any anchor point.
    struct RangeCell: Equatable {
        let staffOffset: Int
        let measureOffset: Int
        let voiceIndex: Int
        let elements: [VoiceElement]
    }

    /// Clipboard payload for a `.range` copy. `cells` is the per-
    /// (staff × measure × voice) breakdown; paste concatenates cells
    /// of each (staffOffset, voiceIndex) pair into a tick stream and
    /// places it starting at the destination's tick offset, splitting
    /// across measures as needed.
    struct RangePayload: Equatable {
        let cells: [RangeCell]
        let staffCount: Int
        let measureCount: Int
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
        @State private var clefPopover: ClefPopoverState?

        struct ClefPopoverState: Equatable, Identifiable {
            let anchor: ClefAnchor
            let currentRawType: String
            /// Document-coord rect of the clef glyph; SwiftUI's
            /// `.popover(item:)` doesn't anchor against this directly,
            /// but it's preserved here so a future PreferenceKey-based
            /// tracker can place the popover precisely on the glyph.
            let attachmentRect: CGRect

            var id: ClefAnchor {
                anchor
            }
        }

        /// Pre-computed layout for the current vertical viewport width.
        /// Rebuilt on width / score / mode changes; passed into both
        /// ScoreView (for rendering) and ScoreHitTester (for tap
        /// mapping), so layout runs at most once per change instead of
        /// twice per click.
        @State private var verticalDoc: LayoutDocument?
        /// Pre-computed layout for horizontal mode (one long system at
        /// natural content width). Rebuilt on mode / score changes.
        @State private var horizontalDoc: LayoutDocument?
        /// The screen-only score used to build `horizontalDoc`. During text
        /// entry it includes the pending command applied to a value copy;
        /// exports continue to read the committed `score` below.
        @State private var horizontalScreenScore: Score?
        /// Invalidates the AppKit-hosted score even when a pending keystroke
        /// changes glyph content without changing the document size.
        @State private var horizontalContentVersion = UUID()
        @State private var renderedTextEntryPreview: ScoreTextEntryPreviewIdentity?
        /// Reused across `adoptEditedScore` calls so `LayoutEngine.layout`
        /// can skip per-measure work for measures unchanged by the edit.
        /// Reset on every `adoptLoadedScore` (a fresh score has no cache
        /// continuity with the previous one).
        @State private var layoutCache = LayoutCache()
        /// The two inline editors share one overlay. Their `begin`
        /// overloads end the other session before taking focus.
        @State private var lyricSession = LyricInputSession()
        @State private var textSession = TextInputSession()
        /// Internal clipboard for ⌘C / ⌘X / ⌘V. Holds whatever
        /// `VoiceElement` was last copied — chord or rest typically.
        /// Not synced with the system pasteboard: the score model isn't
        /// representable as a uniform type, and cross-process paste
        /// doesn't make sense for a single-element copy.
        @State private var voiceElementClipboard: VoiceElement?
        /// Range clipboard. Stores a cell-per-(staff, measure, voice)
        /// payload captured from a `.range` selection — supports copies
        /// that span multiple staves, voices, and measures. Pasted via
        /// per-cell `PasteVoiceElements` calls grouped under one undo
        /// step. Mutually exclusive with `voiceElementClipboard`: a
        /// fresh copy populates one and clears the other.
        @State private var voiceRangeClipboard: RangePayload?
        @FocusState private var textEntryFocused: Bool
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
        /// Held as `@State` so SwiftUI re-evaluates the play / pause
        /// button label and the playback cursor whenever the engine's
        /// observable `state` / `currentCursor` change.
        @State private var playbackEngine = PlaybackEngine(
            soundfontResolver: SelectableSoundfontResolver(
                gmSoundfontURL: SoundfontCatalog.bundledChoices().first?.url,
            ),
            backend: SwiftySynthBackend(),
        )
        /// SoundFonts discovered in the bundled `Sounds/` directory.
        @State private var soundfontChoices = SoundfontCatalog.bundledChoices()
        /// File name of the selected SoundFont. Empty until `onAppear`
        /// picks the first choice. No persistence — resets each launch.
        @State private var selectedSoundfontID = ""
        /// Bridges the engine to `MPNowPlayingInfoCenter` /
        /// `MPRemoteCommandCenter` so macOS Now Playing widget
        /// (Control Center, menu bar, Touch Bar) drives playback.
        /// Lazy-init on first onAppear so we can reference the
        /// engine.
        @State private var nowPlaying: NowPlayingController?
        /// Edit-mode controller. Lives across score reloads —
        /// `reset(score:)` is called from `adoptLoadedScore`.
        @State private var inputController: NoteInputController?
        /// Live size of the horizontal score viewport. Populated by
        /// `HorizontalScoreContainer.onViewportSizeChange` on first
        /// layout / resize. Used by the edit-time scroll helper to
        /// decide whether the affected measure is already in view.
        /// `.zero` until the container reports a real value.
        @State private var horizontalViewportSize: CGSize = .zero
        @Environment(\.undoManager) private var undoManager
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

        /// The original imported PDF document (PDFKit) for `.originalPDF`
        /// mode, and the geometry side-car linking its glyphs to the loaded
        /// `score`. Both `nil` until a PDF is imported via the sidebar.
        @State private var originalPDF: PDFDocument?
        @State private var originalPDFGeometry: PDFScoreGeometry?

        /// Pending programmatic scroll target for the horizontal
        /// `MagnifyingScoreScrollView`, in document coords. The wrapper
        /// animates to it and resets the binding to nil. Set by the
        /// auto-scroll path during playback.
        @State private var pendingHorizontalScroll: CGPoint?
        /// When ON, drags inside vertical / horizontal score viewports
        /// resolve to a marquee selection instead of falling through to
        /// scroll or click. Toggled from the sidebar.
        @State private var isMarqueeMode = false
        @State private var collapseMultiMeasureRests = false
        /// Prepends a metronome pre-roll before playback starts. Default
        /// `true` for easy verification of `PlaybackEngine.play(from:in:countIn:)`.
        @State private var isCountInEnabled = true
        /// Whether the metronome sounds (count-in AND body). Default `false`
        /// so a count-in can be verified in isolation, with the metronome off.
        @State private var isMetronomeEnabled = false
        /// MuseScore "Show Invisible" toggle. When ON, elements with
        /// `visible == false` are laid out and drawn at 50 % opacity
        /// (= MuseScore's `#808080` on white). When OFF (print default),
        /// they are dropped entirely. Wired into `ScoreViewOptions.showsInvisibleElements`.
        @State private var showsInvisibleElements = false
        /// When ON, vertical mode wraps to a fixed page-content width
        /// instead of the window width, so resizing the window scrolls
        /// the engraving instead of re-flowing it. This is
        /// `ScoreViewOptions.fixedLayoutWidth` — the option a reader
        /// app uses to keep line breaks stable while zooming.
        @State private var useFixedLayoutWidth = false
        /// When ON (default), parts the file authored as hidden via
        /// `<Part><show>0</show>` are dropped from the rendered score, the
        /// way a host (Folino) filters authored-hidden staves. Toggling it OFF
        /// draws every staff so you can A/B what `<show>` is hiding.
        @State private var honorAuthoredHiding = true
        /// Transposition offset in semitones (clamped ±7). Applied to
        /// the rendered score via `Score.transposed(bySemitones:)` and
        /// to the audio engine via `PlaybackEngine.setTranspose(semitones:)`.
        @State private var transposeSemitones = 0
        /// Playback speed multiplier (`1.0` = native tempo), applied to the
        /// audio engine via `PlaybackEngine.setRate(_:)`. Score notation is
        /// unaffected — only playback speed changes.
        @State private var playbackRate = 1.0
        @State private var showExport = false
        /// Whole-score repeat toggle (mirrors Folino's
        /// `RepeatMode.loopAll`). When on, the engine loops the full
        /// score so the playhead wraps to the start at the end.
        @State private var isRepeating = false

        /// The score handed to the layout engine: the loaded score with
        /// the active transpose applied, so the engraving reflects it. When
        /// `honorAuthoredHiding` is on, parts the file marked
        /// `<Part><show>0</show>` are filtered out first — the same
        /// `Score.filtered(hidingStaves:)` transform a host applies to honor
        /// authored visibility.
        private func laidOut(_ s: Score) -> Score {
            let transposed = s.transposed(bySemitones: transposeSemitones)
            guard honorAuthoredHiding else { return transposed }
            let hidden = Self.authoredHiddenStaves(of: s)
            return hidden.isEmpty
                ? transposed
                : transposed.filtered(hidingStaves: hidden)
        }

        private var textEntryPreviewIdentity: ScoreTextEntryPreviewIdentity? {
            ScoreTextEntryPreview.identity(
                lyricSession: lyricSession,
                textSession: textSession,
            )
        }

        /// The score a **file** export should serialize: the loaded score with the active transpose applied, so a
        /// saved `.mscx` / `.mscz` / `.mid` is in the key on screen rather than the authored one. Without this the
        /// transpose is a view-only effect and every export silently reverts to the original key.
        ///
        /// Authored-hidden staves are deliberately *not* filtered here, unlike `laidOut(_:)`: `<Part><show>0</show>`
        /// is a display flag of the source file, so dropping those parts on save would delete music the user never
        /// asked to remove.
        private var scoreForFileExport: Score? {
            score.map { $0.transposed(bySemitones: transposeSemitones) }
        }

        /// The committed score a **PDF** export should engrave, with the
        /// detail view's display transform and hidden-staff policy. Pending
        /// inline text is composed only by the horizontal screen-layout path
        /// and deliberately never reaches this value.
        private var scoreForPDFExport: Score? {
            score.map(laidOut)
        }

        /// Staff addresses of every part the file authored as hidden
        /// (`Part.isVisibleInScore == false`, i.e. `<Part><show>0</show>`).
        /// `<show>` is a per-part flag, so a hidden part contributes all of
        /// its staves. Part indices are unaffected by transpose, so this can
        /// be computed from the pre-transpose score.
        private static func authoredHiddenStaves(of score: Score) -> Set<StaffAddress> {
            var hidden: Set<StaffAddress> = []
            for (partIndex, part) in score.parts.enumerated()
                where !part.isVisibleInScore
            {
                for staffIndexInPart in part.staves.indices {
                    hidden.insert(StaffAddress(
                        partIndex: partIndex,
                        staffIndexInPart: staffIndexInPart,
                    ))
                }
            }
            return hidden
        }

        /// The content width of the score's own page geometry — the
        /// same number `PDFPreviewLayout` lays the PDF preview out at,
        /// so "fixed width" means "as wide as a printed page" rather
        /// than an arbitrary constant.
        private var pageContentWidth: CGFloat? {
            guard let score else { return nil }
            let resolved = PDFExporter.resolve(
                options: PDFExporter.Options(), score: score,
            )
            return max(
                resolved.staffSize * 4,
                resolved.page.size.width
                    - resolved.page.oddMargins.leading
                    - resolved.page.oddMargins.trailing,
            )
        }

        /// systemGap targets MuseScore's `Sid::minSystemDistance` of
        /// 8.5 sp; with our staff-distance pads contributing ~3.5 sp
        /// below the last lyric staff, ~5 sp here (≈ 1.25 × staffSize)
        /// lands the visible system-to-system gap in MuseScore range.
        private var verticalOptions: ScoreViewOptions {
            ScoreViewOptions(
                staffSize: 18, systemGap: 22, wrapToViewWidth: true,
                multiMeasureRest: collapseMultiMeasureRests
                    ? .collapse(minimumMeasures: 2)
                    : .disabled,
                showsInvisibleElements: showsInvisibleElements,
                fixedLayoutWidth: useFixedLayoutWidth
                    ? pageContentWidth : nil,
            )
        }

        private var horizontalOptions: ScoreViewOptions {
            ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
                includeTitleFrame: false,
                multiMeasureRest: collapseMultiMeasureRests
                    ? .collapse(minimumMeasures: 2)
                    : .disabled,
                showsInvisibleElements: showsInvisibleElements,
            )
        }

        var body: some View {
            NavigationSplitView {
                ContentSidebar(
                    playbackEngine: playbackEngine,
                    sourceName: sourceName,
                    score: score,
                    errorMessage: errorMessage,
                    layoutMode: $layoutMode,
                    originalPDFAvailable: originalPDF != nil,
                    pageIndex: $pageIndex,
                    totalPages: totalPages,
                    magnification: $magnification,
                    isMarqueeMode: $isMarqueeMode,
                    collapseMultiMeasureRests: $collapseMultiMeasureRests,
                    isCountInEnabled: $isCountInEnabled,
                    isMetronomeEnabled: $isMetronomeEnabled,
                    playbackRate: $playbackRate,
                    showsInvisibleElements: $showsInvisibleElements,
                    useFixedLayoutWidth: $useFixedLayoutWidth,
                    honorAuthoredHiding: $honorAuthoredHiding,
                    transposeSemitones: $transposeSemitones,
                    soundfontChoices: soundfontChoices,
                    selectedSoundfontID: $selectedSoundfontID,
                    onLoadBundled: loadBundled,
                    onLoadHarmonyBasic: loadHarmonyBasic,
                    onLoadLyricsBasic: loadLyricsBasic,
                    onOpenFile: showOpenPanel,
                    onImportPDF: showPDFImportPanel,
                    onTogglePlayback: togglePlayback,
                    isRepeating: isRepeating,
                    onToggleRepeat: toggleRepeatAll,
                    onExportPDF: exportPDF,
                    onExportMSCX: exportMSCX,
                    onExportMSCXv3: exportMSCXv3,
                    onExportMSCZv3: exportMSCZv3,
                    onExportMIDI: exportMIDI,
                    onExportAudio: { showExport = true },
                )
            } detail: {
                if let score {
                    scoreContent(score: laidOut(score))
                        .popover(item: $clefPopover, arrowEdge: .top) { state in
                            ClefPopover(
                                current: ClefChoice.from(rawType: state.currentRawType),
                            ) { choice in
                                applyClefChoice(choice, for: state.anchor)
                            }
                        }
                } else {
                    ContentUnavailableView(
                        "No score loaded",
                        systemImage: "music.note.list",
                        description: Text(
                            "Load the bundled test.mscx from the sidebar.",
                        ),
                    )
                }
            }
            .onAppear(perform: loadBundled)
            .onAppear(perform: installKeyMonitor)
            .onAppear {
                if nowPlaying == nil {
                    nowPlaying = NowPlayingController(engine: playbackEngine)
                }
                if selectedSoundfontID.isEmpty {
                    selectedSoundfontID = soundfontChoices.first?.id ?? ""
                }
            }
            .onChange(of: score) { _, newScore in
                nowPlaying?.update(score: newScore)
            }
            .onChange(of: playbackEngine.state) { _, _ in
                nowPlaying?.refreshNowPlayingInfo()
            }
            .onChange(of: playbackEngine.totalTimeSeconds) { _, _ in
                nowPlaying?.refreshNowPlayingInfo()
            }
            .onDisappear(perform: removeKeyMonitor)
            .onChange(of: collapseMultiMeasureRests) { _, _ in
                rebuildLayoutsForOptionsChange()
            }
            .onChange(of: showsInvisibleElements) { _, _ in
                rebuildLayoutsForOptionsChange()
            }
            .onChange(of: honorAuthoredHiding) { _, _ in
                rebuildLayoutsForOptionsChange()
            }
            .onChange(of: textEntryPreviewIdentity) { _, _ in
                rebuildHorizontalTextEntryPreview()
            }
            .onChange(of: isMetronomeEnabled) { _, newValue in
                playbackEngine.setMuted(forChannel: .metronome, to: !newValue)
            }
            .onChange(of: transposeSemitones) { _, newValue in
                playbackEngine.setTranspose(semitones: newValue)
                rebuildLayoutsForOptionsChange()
            }
            .onChange(of: playbackRate) { _, newValue in
                playbackEngine.setRate(Float(newValue))
            }
            .onChange(of: selectedSoundfontID) { _, newID in
                guard let choice = soundfontChoices.first(where: { $0.id == newID })
                else { return }
                playbackEngine.reloadSoundfont(
                    resolver: SelectableSoundfontResolver(gmSoundfontURL: choice.url),
                )
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Label(
                        score?.source.displayName ?? "No Score",
                        systemImage: "doc.badge.gearshape",
                    )
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help("Format the current score was loaded from.")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        inputController?.isInputModeOn.toggle()
                    } label: {
                        let on = inputController?.isInputModeOn ?? false
                        Label(
                            on ? "Input Mode (on)" : "Input Mode",
                            systemImage: on ? "pencil.tip.crop.circle.fill" : "pencil.tip",
                        )
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(on ? Color.accentColor : .primary)
                    }
                    .disabled(inputController == nil)
                    .help(
                        """
                        Toggle note input mode. Then click a rest and type \
                        C/D/E/F/G/A/B; ↑/↓ shifts octave; ⌘Z undoes.
                        """,
                    )
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    accidentalButton(
                        .doubleFlat,
                        glyph: "𝄫",
                        help: "Double flat (𝄫) on the selected note",
                    )
                    accidentalButton(
                        .flat,
                        glyph: "♭",
                        help: "Flat (♭) on the selected note",
                    )
                    accidentalButton(
                        .natural,
                        glyph: "♮",
                        help: "Natural (♮) on the selected note",
                    )
                    accidentalButton(
                        .sharp,
                        glyph: "♯",
                        help: "Sharp (♯) on the selected note",
                    )
                    accidentalButton(
                        .doubleSharp,
                        glyph: "𝄪",
                        help: "Double sharp (𝄪) on the selected note",
                    )
                    Button {
                        if case let .single(.note(id)) = selection {
                            applyAccidental(nil, to: id)
                        }
                    } label: {
                        Label(
                            "No Accidental",
                            systemImage: "minus.circle",
                        )
                    }
                    .disabled(!isAccidentalActionable)
                    .help(
                        "Clear the explicit accidental glyph; the "
                            + "note reverts to whatever the key signature "
                            + "implies.",
                    )
                }
            }
            .sheet(isPresented: $showExport) {
                // Deliberately the *untransposed* score: audio transpose is a
                // tuning shift the offline render reproduces from the engine's
                // snapshot (`PlaybackEngine.transposeSemitones`), never a
                // re-render. Passing `scoreForFileExport` here would transpose
                // twice.
                if let score {
                    AudioExportSheet(engine: playbackEngine, score: score)
                        .frame(minWidth: 360, minHeight: 320)
                }
            }
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

        /// Import a music PDF: reconstruct the `Score` + geometry side-car,
        /// adopt the score (so playback prepares against it), keep the
        /// original PDF document for display, and switch to `.originalPDF`.
        ///
        /// Scanned (image-only) pages are read too, through the bundled OMR
        /// model. That is seconds per page in a Debug build, so the parse
        /// runs off the main actor and the sidebar shows what it read.
        func importOriginalPDF(from url: URL) {
            errorMessage = "Importing \(url.lastPathComponent)…"
            Task {
                do {
                    let data = try Data(contentsOf: url)
                    let result = try await Self.parseMusicPDF(data)
                    guard let document = PDFDocument(data: data) else {
                        errorMessage = "Could not open PDF: \(url.lastPathComponent)"
                        return
                    }
                    adoptLoadedScore(result.score, sourceName: url.lastPathComponent)
                    originalPDF = document
                    originalPDFGeometry = result.geometry
                    layoutMode = .originalPDF
                    errorMessage = Self.describeImport(result.diagnostics)
                } catch {
                    errorMessage =
                        "PDF import failed: " + exampleErrorDescription(error)
                }
            }
        }

        /// Collects the importer's diagnostics from its `@Sendable` callback.
        /// The callback runs synchronously inside the parse, on the detached
        /// task's thread, and nothing reads `items` until the parse returns.
        private final class ImportDiagnosticLog: @unchecked Sendable {
            var items: [PDFImportDiagnostic] = []
        }

        /// `parseWithGeometry` with the bundled OMR model attached. Detached
        /// because the parse — and the model load before it — is synchronous
        /// and CPU-bound.
        private nonisolated static func parseMusicPDF(
            _ data: Data,
        ) async throws -> (score: Score, geometry: PDFScoreGeometry, diagnostics: [PDFImportDiagnostic]) {
            try await Task.detached(priority: .userInitiated) {
                let log = ImportDiagnosticLog()
                var options = PDFImportOptions()
                options.omrTileClassifier = try CoreMLTileClassifier()
                options.diagnostics = { log.items.append($0) }
                let result = try PDFImporter.parseWithGeometry(pdfData: data, options: options)
                return (result.score, result.geometry, log.items)
            }.value
        }

        /// One sidebar line for the import; every diagnostic also goes to the
        /// console, where a warning's page and reason are readable in full.
        private static func describeImport(_ diagnostics: [PDFImportDiagnostic]) -> String? {
            for diagnostic in diagnostics {
                print("[pdf-import] \(diagnostic.severity) \(diagnostic.location): \(diagnostic.message)")
            }
            let rasterNote = diagnostics.first { $0.message.hasPrefix("OMR: no geometry") }
            let warnings = diagnostics.filter { $0.severity == .warning }.count
            var parts: [String] = []
            if rasterNote != nil {
                parts.append("Read scanned page(s) with OMR — no playback cursor on those pages")
            }
            if warnings > 0 {
                parts.append("\(warnings) import warning(s); see the console")
            }
            return parts.isEmpty ? nil : parts.joined(separator: ". ")
        }

        private func showPDFImportPanel() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.title = "Import Music PDF"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            importOriginalPDF(from: url)
        }

        private func exportPDF() {
            guard let score = scoreForPDFExport else { return }
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
                        title: (sourceName as NSString).deletingPathExtension,
                    ),
                )
                // Reveal the resulting file so the user can inspect it
                // without hunting through Finder.
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = "PDF export failed: \(exampleErrorDescription(error))"
            }
        }

        private func exportMSCX() {
            exportMSCX(targetVersion: .v4, title: "Save Score as MSCX (MS4)")
        }

        private func exportMSCXv3() {
            exportMSCX(targetVersion: .v3, title: "Save Score as MSCX (MS3)")
        }

        private func exportMSCX(targetVersion: MSCXVersion, title: String) {
            guard let score = scoreForFileExport else { return }
            let panel = NSSavePanel()
            if let mscx = UTType(filenameExtension: "mscx") {
                panel.allowedContentTypes = [mscx]
            }
            panel.nameFieldStringValue = (sourceName as NSString)
                .deletingPathExtension + ".mscx"
            panel.canCreateDirectories = true
            panel.title = title
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try SheetMusic.exportMSCX(
                    score,
                    options: MSCXEncoderOptions(targetVersion: targetVersion),
                    to: url,
                )
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = "MSCX export failed: \(exampleErrorDescription(error))"
            }
        }

        private func exportMIDI() {
            guard let score = scoreForFileExport else { return }
            let panel = NSSavePanel()
            if let mid = UTType(filenameExtension: "mid") {
                panel.allowedContentTypes = [mid]
            }
            panel.nameFieldStringValue = (sourceName as NSString)
                .deletingPathExtension + ".mid"
            panel.canCreateDirectories = true
            panel.title = "Save Score as MIDI"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                let data = try SheetMusic.exportMIDI(score: score)
                try data.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = "MIDI export failed: \(exampleErrorDescription(error))"
            }
        }

        private func exportMSCZv3() {
            guard let score = scoreForFileExport else { return }
            let panel = NSSavePanel()
            if let mscz = UTType(filenameExtension: "mscz") {
                panel.allowedContentTypes = [mscz]
            }
            panel.nameFieldStringValue = (sourceName as NSString)
                .deletingPathExtension + ".mscz"
            panel.canCreateDirectories = true
            panel.title = "Save Score as MSCZ (MS3)"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try SheetMusic.exportMSCZ(
                    score,
                    options: MSCXEncoderOptions(targetVersion: .v3),
                    to: url,
                )
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                errorMessage = "MSCZ export failed: \(exampleErrorDescription(error))"
            }
        }

        private func togglePlayback() {
            guard let score else { return }
            // Re-assert the toggle's value right before starting playback —
            // `prepare(score:)` rebuilds the mixer channels (incl. the
            // metronome strip) to their defaults on every score (re)load, so
            // a stale mixer state could otherwise silently win.
            playbackEngine.setMuted(forChannel: .metronome, to: !isMetronomeEnabled)
            playbackEngine.togglePlayback(
                score: score, selection: selection, countIn: isCountInEnabled,
            )
        }

        /// Toggle a playback loop bracketing the current range
        /// selection. Bound to bare `L` from the key monitor — see
        /// `installKeyMonitor`. The loop wraps once the last selected
        /// note has finished its notated duration, so the user hears
        /// the full selection before each loop iteration.
        /// Toggle whole-score repeat (Folino's `RepeatMode.loopAll`).
        /// On → loop the full score so the playhead wraps to the start
        /// each time it reaches the end; off → clear the loop. The
        /// engine's `tickCursor` performs the wrap — the path that
        /// re-fires the SMF's tick-0 program changes and clobbers
        /// per-staff program overrides (the bug under investigation).
        private func toggleRepeatAll() {
            if isRepeating {
                playbackEngine.clearLoop()
                isRepeating = false
                return
            }
            guard let score,
                  let bounds = fullScoreLoopBounds(score: score)
            else { return }
            playbackEngine.setLoop(
                from: .item(bounds.first), throughEndOf: bounds.last,
            )
            isRepeating = true
        }

        /// First and last `.chord`-anchored `ScoreItemID` of the whole
        /// score (voice 0 of staff 0 — the same spine the cursor mapping
        /// uses). Mirrors Folino's `LoopBounds` so the repro range
        /// matches the app's `loopAll`.
        private func fullScoreLoopBounds(
            score: Score,
        ) -> (first: ScoreItemID, last: ScoreItemID)? {
            guard let staff = score.parts.first?.staves.first else { return nil }
            let measureCount = staff.measures.count
            guard measureCount > 0 else { return nil }
            let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)

            func itemID(
                chord: Chord, measureIndex: Int, elementIndex: Int,
            ) -> ScoreItemID {
                if chord.notes.isEmpty {
                    return .rest(RestID(
                        staff: address,
                        measureIndex: measureIndex,
                        voiceIndex: 0,
                        elementIndex: elementIndex,
                    ))
                }
                return .note(NoteID(
                    staff: address,
                    measureIndex: measureIndex,
                    voiceIndex: 0,
                    elementIndex: elementIndex,
                    noteIndexInChord: 0,
                ))
            }

            func firstChordID(inMeasure mi: Int) -> ScoreItemID? {
                guard let voice = staff.measures[mi].voices.first else { return nil }
                for (idx, element) in voice.elements.enumerated() {
                    guard case let .chord(chord) = element else { continue }
                    return itemID(chord: chord, measureIndex: mi, elementIndex: idx)
                }
                return nil
            }

            func lastChordID(inMeasure mi: Int) -> ScoreItemID? {
                guard let voice = staff.measures[mi].voices.first else { return nil }
                var last: ScoreItemID?
                for (idx, element) in voice.elements.enumerated() {
                    guard case let .chord(chord) = element else { continue }
                    last = itemID(chord: chord, measureIndex: mi, elementIndex: idx)
                }
                return last
            }

            var first: ScoreItemID?
            for mi in 0 ..< measureCount {
                if let id = firstChordID(inMeasure: mi) { first = id; break }
            }
            var last: ScoreItemID?
            for mi in stride(from: measureCount - 1, through: 0, by: -1) {
                if let id = lastChordID(inMeasure: mi) { last = id; break }
            }
            guard let first, let last else { return nil }
            return (first, last)
        }

        private func toggleLoopForSelection() {
            if playbackEngine.loopRange != nil {
                playbackEngine.clearLoop()
                return
            }
            guard case let .range(a, b) = selection else { return }
            let first = playbackEngine.earliest(of: [a, b]) ?? a
            let last = (first == a) ? b : a
            playbackEngine.setLoop(
                from: .item(first), throughEndOf: last,
            )
            playbackEngine.seek(to: .item(first))
        }

        private func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            // keyCode 49 is spacebar on every keyboard layout (it's a
            // physical-key code). Skip auto-repeat so a held space
            // doesn't toggle dozens of times per second.
            keyMonitor = NSEvent.addLocalMonitorForEvents(
                matching: .keyDown,
            ) { event in
                // Space (keyCode 49). An inline input session commits
                // and advances; otherwise it toggles playback.
                if event.keyCode == 49,
                   !event.isARepeat,
                   event.modifierFlags.isDisjoint(
                       with: [.command, .control, .option],
                   )
                {
                    if let controller = inputController,
                       lyricSession.isActive
                    {
                        if event.modifierFlags.contains(.shift) {
                            lyricSession.movePrevious(
                                controller: controller,
                            )
                            syncSelectionToLyricCursor()
                            if let cursor = lyricSession.cursor {
                                scrollToAffectedMeasure(
                                    measureIndex: cursor.location.measureIndex,
                                )
                            }
                        } else {
                            do {
                                let affected = try lyricSession.commit(
                                    .word,
                                    controller: controller,
                                    undoManager: undoManager,
                                )
                                adoptEditedScore(controller.score)
                                syncSelectionToLyricCursor()
                                if let affected {
                                    scrollToAffectedMeasure(
                                        measureIndex: affected.measureIndex,
                                    )
                                }
                            } catch {
                                errorMessage = exampleErrorDescription(error)
                            }
                        }
                        textEntryFocused = lyricSession.isActive
                        return nil
                    }
                    if let controller = inputController,
                       textSession.isActive
                    {
                        do {
                            let affected = try textSession.commit(
                                advance: true,
                                controller: controller,
                                undoManager: undoManager,
                            )
                            adoptEditedScore(controller.score)
                            if let affected {
                                scrollToAffectedMeasure(
                                    measureIndex: affected.measureIndex,
                                )
                            }
                        } catch {
                            errorMessage = exampleErrorDescription(error)
                        }
                        textEntryFocused = textSession.isActive
                        return nil
                    }
                    togglePlayback()
                    return nil
                }
                // Bare `L` toggles a playback loop over the current
                // range selection. ⌘L (handled below) opens the lyric
                // editor, so we filter to no-modifier presses. While
                // an inline editor is up we let the keystroke through
                // so the user can type the letter.
                if !event.isARepeat,
                   event.modifierFlags.isDisjoint(
                       with: [.command, .control, .option, .shift],
                   ),
                   let chars = event.charactersIgnoringModifiers,
                   chars.first?.lowercased() == "l",
                   !lyricSession.isActive,
                   !textSession.isActive
                {
                    toggleLoopForSelection()
                    return nil
                }
                // ⌘Z / ⌘⇧Z routed to our editor directly. SwiftUI's
                // `@Environment(\.undoManager)` requires the focused
                // responder to also expose one; our score viewport is
                // not a text-input responder, so the Edit menu's Undo
                // never reaches us. Catching the chord here works
                // regardless of focus state. The `UndoManager`
                // registration in `NoteInputController` is kept for
                // future Edit-menu integration.
                if event.modifierFlags.contains(.command),
                   !event.isARepeat,
                   let chars = event.charactersIgnoringModifiers,
                   chars.first?.lowercased() == "z"
                {
                    if let controller = inputController {
                        handleEditorUndoRedo(
                            controller: controller,
                            redo: event.modifierFlags.contains(.shift),
                        )
                        return nil
                    }
                }
                // ⌘L on a selected note opens the lyric editor.
                // Independent of input mode — editing existing lyrics is
                // a normal browse-mode action too. Caught here (alongside
                // ⌘Z) for the same reason: the score viewport isn't a
                // text-input responder.
                if event.modifierFlags.contains(.command),
                   !event.isARepeat,
                   let chars = event.charactersIgnoringModifiers,
                   chars.first?.lowercased() == "l"
                {
                    if case let .single(.note(noteID)) = selection,
                       let controller = inputController
                    {
                        lyricSession.begin(
                            at: VoiceElementID(noteID),
                            verse: 0,
                            controller: controller,
                            ending: textSession,
                        )
                        syncSelectionToLyricCursor()
                        textEntryFocused = true
                        return nil
                    }
                }
                // Text-entry shortcuts all accept a selected note or rest.
                // With no timed selection the event is left untouched so
                // normal macOS menu handling can still see it.
                if event.modifierFlags.contains(.command),
                   !event.isARepeat,
                   event.modifierFlags.isDisjoint(
                       with: [.control, .option],
                   ),
                   let chars = event.charactersIgnoringModifiers,
                   let key = chars.first?.lowercased()
                {
                    let kind: TextInputPlanner.Kind? = switch key {
                    case "t": event.modifierFlags.contains(.shift)
                        ? .systemText : .staffText
                    case "k" where !event.modifierFlags.contains(.shift):
                        .chordSymbol
                    case "m" where !event.modifierFlags.contains(.shift):
                        .rehearsalMark
                    default: nil
                    }
                    if let kind {
                        guard let anchor = selectedVoiceElementID(),
                              let controller = inputController
                        else {
                            errorMessage = "Select a note or rest before entering text."
                            return event
                        }
                        textSession.begin(
                            kind: kind,
                            at: anchor,
                            controller: controller,
                            ending: lyricSession,
                        )
                        textEntryFocused = true
                        return nil
                    }
                }
                // ⌘C / ⌘X / ⌘V: clipboard for one VoiceElement. Cut and
                // copy capture the currently-selected chord or rest into
                // an in-memory slot; paste calls PasteVoiceElement, which
                // refuses if the destination's duration doesn't match.
                if event.modifierFlags.contains(.command),
                   !event.isARepeat,
                   event.modifierFlags.isDisjoint(
                       with: [.option, .control],
                   ),
                   let chars = event.charactersIgnoringModifiers,
                   let key = chars.first?.lowercased()
                {
                    switch key {
                    case "c":
                        if copySelectedElement() { return nil }
                    case "x":
                        if cutSelectedElement() { return nil }
                    case "v":
                        if pasteAtSelection() { return nil }
                    default: break
                    }
                }
                // ⌘3 / ⌘5 / ⌘7 / …: convert the selected chord/rest
                // into a tuplet (triplet / quintuplet / septuplet …).
                // Matches MuseScore's macOS shortcut.
                if event.modifierFlags.contains(.command),
                   !event.isARepeat,
                   event.modifierFlags.isDisjoint(
                       with: [.control, .option, .shift],
                   ),
                   let chars = event.charactersIgnoringModifiers,
                   let ratio = Self.tupletRatio(forCharacter: chars.first)
                {
                    if applyCreateTuplet(
                        actualNotes: ratio.actual,
                        normalNotes: ratio.normal,
                    ) {
                        return nil
                    }
                }
                // Lyric navigation takes priority over note-input arrows.
                if lyricSession.isActive,
                   let controller = inputController,
                   !event.isARepeat
                {
                    if event.keyCode == 125 || event.keyCode == 126 {
                        lyricSession.moveVerse(
                            event.keyCode == 125 ? .next : .previous,
                            controller: controller,
                        )
                        syncSelectionToLyricCursor()
                        textEntryFocused = true
                        return nil
                    }
                    if event.keyCode == 36 {
                        do {
                            let affected = try lyricSession.commit(
                                .none,
                                controller: controller,
                                undoManager: undoManager,
                            )
                            adoptEditedScore(controller.score)
                            if let affected {
                                scrollToAffectedMeasure(
                                    measureIndex: affected.measureIndex,
                                )
                            }
                        } catch {
                            errorMessage = exampleErrorDescription(error)
                        }
                        lyricSession.end()
                        textEntryFocused = false
                        return nil
                    }
                    if event.keyCode == 53 {
                        lyricSession.end()
                        textEntryFocused = false
                        return nil
                    }
                    if event.modifierFlags.isDisjoint(
                        with: [.command, .control, .option],
                    ),
                        let character = event.characters?.first,
                        character == "-" || character == "_"
                    {
                        let terminator: LyricInputPlanner.Terminator =
                            character == "-" ? .syllable : .melisma
                        do {
                            let affected = try lyricSession.commit(
                                terminator,
                                controller: controller,
                                undoManager: undoManager,
                            )
                            adoptEditedScore(controller.score)
                            syncSelectionToLyricCursor()
                            if let affected {
                                scrollToAffectedMeasure(
                                    measureIndex: affected.measureIndex,
                                )
                            }
                        } catch {
                            errorMessage = exampleErrorDescription(error)
                        }
                        textEntryFocused = lyricSession.isActive
                        return nil
                    }
                }
                // Note input must not fire while an inline text field has
                // the caret: the monitor runs ahead of the responder
                // chain, so an unguarded `handleInputModeKey` would turn
                // the `a` of a typed syllable into an A natural instead
                // of letting the TextField have it.
                if let controller = inputController, controller.isInputModeOn,
                   !lyricSession.isActive, !textSession.isActive
                {
                    if handleInputModeKey(event, controller: controller) {
                        return nil
                    }
                }
                return event
            }
        }

        /// Map a digit to the (actual:normal) ratio of the tuplet it
        /// triggers. nil for digits that don't carry a default tuplet.
        private static func tupletRatio(
            forCharacter char: Character?,
        ) -> (actual: Int, normal: Int)? {
            switch char {
            case "3": return (3, 2) // triplet
            case "5": return (5, 4) // quintuplet
            case "6": return (6, 4) // sextuplet
            case "7": return (7, 4) // septuplet
            case "9": return (9, 8) // nonuplet
            default: return nil
            }
        }

        private func handleEditorUndoRedo(
            controller: NoteInputController,
            redo: Bool,
        ) {
            do {
                if redo {
                    try controller.redo()
                } else {
                    try controller.undo()
                }
            } catch {
                errorMessage = exampleErrorDescription(error)
                return
            }
            // Defer @State mutations to the next runloop tick.
            // Repeatedly mutating @State from inside an `NSEvent`
            // monitor closure (e.g. holding ⌘Z) doesn't reliably
            // invalidate the SwiftUI view: the second-and-onward
            // writes to the same property within one event-handling
            // pass can be no-ops (Equatable check), and `scoreVersion`
            // alone hasn't been enough to nudge body re-eval.
            // `DispatchQueue.main.async` puts the mutations on the
            // next runloop iteration, fully outside the NSEvent
            // dispatch path, where SwiftUI's normal update cycle
            // applies. The same fix shape can later be applied to
            // the apply path if the rapid-typing case shows similar
            // staleness.
            let edited = controller.score
            let isRedo = redo
            let affectedMeasure = controller.editor.lastAffectedLocation?.measureIndex
            DispatchQueue.main.async {
                errorMessage = isRedo ? "Redo" : "Undo"
                selection = .none
                adoptEditedScore(edited)
                if let mi = affectedMeasure {
                    scrollToAffectedMeasure(measureIndex: mi)
                }
            }
        }

        /// Scroll the horizontal viewport so `measureIndex`'s leading
        /// edge sits at the visible left edge. No-ops in non-horizontal
        /// modes (vertical / paged / pdf each have their own pathway,
        /// and editing them isn't supported in this slice yet).
        private func scrollToAffectedMeasure(measureIndex: Int) {
            guard layoutMode == .horizontal,
                  let doc = horizontalDoc,
                  horizontalViewportSize.width > 0
            else { return }
            scrollToMeasureMac(
                measureIndex: measureIndex,
                doc: doc,
                viewportWidth: horizontalViewportSize.width,
                magnification: magnification,
                horizontalScrollX: horizontalScrollX,
                horizontalScrollY: horizontalScrollY,
                pendingScroll: $pendingHorizontalScroll,
            )
        }

        private func removeKeyMonitor() {
            if let m = keyMonitor {
                NSEvent.removeMonitor(m)
                keyMonitor = nil
            }
        }

        /// Routes a keydown while input mode is on. Returns `true` when
        /// the event has been consumed (caller returns `nil` to AppKit
        /// so no beep plays); `false` when it should propagate (e.g. a
        /// letter unrelated to note input, leaving other shortcuts
        /// reachable).
        private func handleInputModeKey(
            _ event: NSEvent,
            controller: NoteInputController,
        ) -> Bool {
            // We only filter out the "real" modifier keys (cmd / ctrl /
            // option / shift). Arrow keys themselves carry `.function`
            // and `.numericPad` flags on macOS — testing against the
            // full `deviceIndependentFlagsMask` for `.isEmpty` rejects
            // every plain arrow press.
            let blockingMods: NSEvent.ModifierFlags =
                [.command, .control, .option, .shift]

            // Shift+Backspace / Shift+forward-Delete with a note
            // selected: remove only that note from its chord.
            // `RemoveNoteFromChord` collapses to a rest if it was the
            // last note. Lets the user prune one head from a chord
            // without losing the chord-level duration / lyrics in the
            // multi-note case. Plain Backspace below stays "delete the
            // whole element".
            if event.modifierFlags
                .isDisjoint(with: [.command, .control, .option]),
                event.modifierFlags.contains(.shift),
                event.keyCode == 51 || event.keyCode == 117,
                case let .single(.note(noteID)) = selection
            {
                removeNoteFromChord(
                    noteID: noteID, controller: controller,
                )
                return true
            }
            // Backspace (keyCode 51) / forward Delete (keyCode 117):
            // replace the selected chord/rest with a rest of the same
            // duration. Drum notes included — DeleteVoiceElement just
            // calls into ReplaceVoiceElement at the library level.
            if event.modifierFlags
                .isDisjoint(with: blockingMods),
                event.keyCode == 51 || event.keyCode == 117
            {
                deleteSelectedElement(controller: controller)
                return true
            }
            // Up / down arrow: shift the selected note by ±1 semitone
            // when a note is selected; otherwise shift the input
            // octave (used for the next letter typed onto a rest).
            // Always consume so AppKit doesn't beep on unhandled events.
            if event.modifierFlags
                .isDisjoint(with: blockingMods),
                event.keyCode == 126 || event.keyCode == 125
            {
                let delta = event.keyCode == 126 ? 1 : -1
                if case let .single(.note(noteID)) = selection {
                    shiftSelectedNote(
                        noteID: noteID, by: delta, controller: controller,
                    )
                } else if !event.isARepeat {
                    // Octave shift only fires on the initial press —
                    // holding the key shouldn't crank the octave through
                    // the whole keyboard.
                    controller.inputOctave = max(
                        0, min(8, controller.inputOctave + delta),
                    )
                    errorMessage = "Input octave: \(controller.inputOctave)"
                }
                return true
            }
            // `+` (shift+; on JIS, shift+= on US) toggles a tie from the
            // selected note to the next same-pitch chord in its voice.
            // Checked BEFORE the letter-key insertion path so `+` never
            // lands in a note-input lookup that doesn't know about it.
            if event.characters == "+",
               event.modifierFlags
                   .isDisjoint(with: [.command, .control, .option]),
                   case let .single(.note(noteID)) = selection
            {
                toggleTieForward(
                    noteID: noteID, controller: controller,
                )
                return true
            }
            // Number keys 1–7 with a note OR rest selected → change
            // that element's duration. Mapping mirrors MuseScore:
            //   1=64th, 2=32nd, 3=16th, 4=8th, 5=quarter, 6=half, 7=whole.
            // Notes route through SetChordDuration; rests through
            // SetRestDuration (both share the same shorten / lengthen
            // / chord-overshoot algorithm).
            if event.modifierFlags
                .isDisjoint(with: [.command, .control, .option]),
                let duration = NoteInputKeyMap.duration(
                    forCharacter: event.characters ?? "",
                )
            {
                switch selection {
                case let .single(.note(noteID)):
                    setSelectedChordDuration(
                        noteID: noteID, duration: duration,
                        controller: controller,
                    )
                    return true
                case let .single(.rest(restID)):
                    setSelectedRestDuration(
                        restID: restID, duration: duration,
                        controller: controller,
                    )
                    return true
                default:
                    break
                }
            }
            guard let chars = event.charactersIgnoringModifiers,
                  let letter = chars.first
            else {
                return false
            }
            guard let mapped = NoteInputKeyMap.pitch(
                forLetter: letter,
                octave: controller.inputOctave,
            )
            else {
                // Letter unrelated to note entry — let other shortcuts /
                // text inputs through. (No beep risk because the system
                // will deliver it to whatever responder is appropriate.)
                return false
            }
            // Shift+letter on a selected note → add the letter's pitch
            // to that note's chord. Mirrors MuseScore's chord-input
            // shortcut. The accidental glyph is computed against the
            // active key sig so the new note's spelling matches what
            // the staff already shows for that letter.
            if event.modifierFlags.contains(.shift),
               case let .single(.note(noteID)) = selection
            {
                addNoteToChord(
                    noteID: noteID, mapped: mapped,
                    controller: controller,
                )
                return true
            }
            guard case let .single(.rest(restID)) = selection else {
                // Letter is mapped but there's no rest to drop it onto.
                // Consume it so the user doesn't get a beep, and give
                // visible feedback.
                errorMessage = "Click a rest to insert a note. Current selection: \(describeSelection(selection))."
                return true
            }
            do {
                try controller.apply(
                    InputNote(
                        at: restID,
                        pitch: mapped.pitch,
                        tpc: mapped.tpc,
                    ),
                    undoManager: undoManager,
                )
                // After successful insertion the rest is gone — select
                // the freshly-inserted note so the user sees what they
                // just typed.
                let noteID = NoteID(
                    staff: restID.staff,
                    measureIndex: restID.measureIndex,
                    voiceIndex: restID.voiceIndex,
                    elementIndex: restID.elementIndex,
                    noteIndexInChord: 0,
                )
                selection = .single(.note(noteID))
                adoptEditedScore(controller.score)
                // Match the click-on-note feedback path: brief preview
                // of the just-inserted pitch via the playback engine.
                playbackEngine.playPreview(
                    noteID: noteID, in: controller.score,
                )
                // Pull the affected measure into view if it isn't
                // already (handles fast typing past the visible window
                // and edits on offscreen rests).
                scrollToAffectedMeasure(
                    measureIndex: restID.measureIndex,
                )
                errorMessage = """
                Inserted \(String(letter).uppercased())\
                \(controller.inputOctave) (MIDI \(mapped.pitch)). \
                Click another rest to keep typing.
                """
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
            return true
        }

        /// Add a new note (Shift+letter mapping → pitch in input
        /// octave) to the chord that contains the currently-selected
        /// note. The accidental is auto-computed against the active key
        /// signature; the chord's other metadata (duration, lyrics,
        /// arpeggio) is preserved by `AddNoteToChord`.
        private func addNoteToChord(
            noteID: NoteID,
            mapped: (pitch: Int, tpc: Int),
            controller: NoteInputController,
        ) {
            let chordID = VoiceElementID(noteID)
            let activeKey = controller.score.activeKey(at: noteID)
            let accidental: Accidental? = isDrumStaff(
                noteID: noteID,
                controller: controller,
            )
                ? nil
                : PitchSpelling.displayedAccidental(
                    forTpc: mapped.tpc, in: activeKey,
                )
            // Capture the chord's prior note count so we can address
            // the freshly-appended note after the apply.
            let priorNoteCount: Int
            if case let .chord(c) = controller.score[chordID] {
                priorNoteCount = c.notes.count
            } else {
                priorNoteCount = 0
            }
            do {
                try controller.apply(
                    AddNoteToChord(
                        at: chordID,
                        pitch: mapped.pitch,
                        tpc: mapped.tpc,
                        accidental: accidental,
                    ),
                    undoManager: undoManager,
                )
                adoptEditedScore(controller.score)
                // Move selection to the freshly-added note (it sits at
                // the end of `chord.notes` per AddNoteToChord) and
                // preview that pitch — matches the rest-input flow's
                // "select what you just typed + play it" feedback.
                let newNoteID = NoteID(
                    staff: noteID.staff,
                    measureIndex: noteID.measureIndex,
                    voiceIndex: noteID.voiceIndex,
                    elementIndex: noteID.elementIndex,
                    noteIndexInChord: priorNoteCount,
                )
                selection = .single(.note(newNoteID))
                playbackEngine.playPreview(
                    noteID: newNoteID, in: controller.score,
                )
                errorMessage = "Added \(mapped.pitch) to chord"
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
        }

        private func isDrumStaff(
            noteID: NoteID,
            controller: NoteInputController,
        ) -> Bool {
            controller.score.part(at: noteID.staff)?
                .instrument.useDrumset ?? false
        }

        /// Set the duration of the chord that contains the currently-
        /// selected note via `SetChordDuration`. Maps MuseScore-style
        /// shortenings to leftover rests and lengthenings to consumed
        /// following elements. Surfaces `invalidEdit` reasons (tuplet,
        /// measure boundary, non-timed element in path) as user-visible
        /// `errorMessage` text.
        private func setSelectedChordDuration(
            noteID: NoteID,
            duration: NoteDuration,
            controller: NoteInputController,
        ) {
            let chordID = VoiceElementID(noteID)
            do {
                try controller.apply(
                    SetChordDuration(at: chordID, duration: duration),
                    undoManager: undoManager,
                )
                adoptEditedScore(controller.score)
                errorMessage = "Duration changed"
                scrollToAffectedMeasure(measureIndex: noteID.measureIndex)
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
        }

        /// Same as `setSelectedChordDuration` but for the
        /// `SetRestDuration` command.
        private func setSelectedRestDuration(
            restID: RestID,
            duration: NoteDuration,
            controller: NoteInputController,
        ) {
            let veID = VoiceElementID(restID)
            do {
                try controller.apply(
                    SetRestDuration(at: veID, duration: duration),
                    undoManager: undoManager,
                )
                adoptEditedScore(controller.score)
                errorMessage = "Duration changed"
                scrollToAffectedMeasure(measureIndex: restID.measureIndex)
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
        }

        /// Toggle a tie from the currently-selected note to the next
        /// chord in the same voice that contains a note of the same
        /// pitch. Adds the tie when none is present, removes it when
        /// one is.
        private func toggleTieForward(
            noteID: NoteID,
            controller: NoteInputController,
        ) {
            guard let source = controller.score[noteID] else {
                errorMessage = "Selected note not found in score"
                return
            }
            guard let target = controller.score
                .nextTieTarget(after: noteID)
            else {
                errorMessage = "No tie target — the next chord in this "
                    + "voice must contain a note of the same pitch."
                return
            }
            let alreadyTied = source.tieForward != nil
            let cmd = SetTie(
                from: noteID, to: target,
                sourceTieForward: alreadyTied ? nil : 1,
                targetTieBack: alreadyTied ? nil : 1,
            )
            do {
                try controller.apply(cmd, undoManager: undoManager)
                adoptEditedScore(controller.score)
                errorMessage = alreadyTied ? "Tie removed" : "Tied"
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
        }

        /// Copy the current selection into one of the two clipboards.
        /// `.single` populates `voiceElementClipboard` (and clears the
        /// range one); `.range` resolved to a contiguous in-voice slice
        /// populates `voiceElementsClipboard`. Returns true when the
        /// event was actionable so the key monitor can swallow ⌘C.
        private func copySelectedElement() -> Bool {
            guard let controller = inputController else { return false }
            switch selection {
            case .single:
                guard let id = selectedVoiceElementID(),
                      let element = controller.score[id]
                else { return false }
                voiceElementClipboard = element
                voiceRangeClipboard = nil
                errorMessage = "Copied"
                return true
            case let .range(anchor, target):
                guard let payload = collectRangePayload(
                    anchor: anchor, target: target,
                    score: controller.score,
                )
                else {
                    errorMessage = "Range copy: nothing to copy."
                    return true
                }
                voiceRangeClipboard = payload
                voiceElementClipboard = nil
                let total = payload.cells.reduce(0) {
                    $0 + $1.elements.count
                }
                errorMessage = "Copied \(total) element"
                    + (total == 1 ? "" : "s")
                    + " across \(payload.cells.count) voice/measure cell"
                    + (payload.cells.count == 1 ? "" : "s")
                return true
            default:
                return false
            }
        }

        /// Build a `RangePayload` for a `.range` selection. Captures
        /// every chord / rest in every (staff × measure × voice) cell
        /// inside the selection rectangle (non-timed elements like
        /// clef / key sig are skipped — pasting those wholesale would
        /// surprise the user). Returns `nil` if the range references
        /// elements that don't resolve in the score.
        private func collectRangePayload(
            anchor: ScoreItemID, target: ScoreItemID, score: Score,
        ) -> RangePayload? {
            let division = score.division
            guard let anchorStart = elementTickPosition(
                of: anchor, in: score,
            ),
                let targetStart = elementTickPosition(
                    of: target, in: score,
                ),
                let targetEnd = elementEndTickPosition(
                    of: target, in: score,
                )
            else { return nil }
            let allStaves = score.allStaves
            let anchorFlatIdx = allStaves.firstIndex(where: {
                $0.address == anchor.staff
            }) ?? 0
            let targetFlatIdx = allStaves.firstIndex(where: {
                $0.address == target.staff
            }) ?? 0
            let staffLo = min(anchorFlatIdx, targetFlatIdx)
            let staffHi = max(anchorFlatIdx, targetFlatIdx)
            // (lo, hi) bracket the time region: lo = whichever of the
            // two endpoints starts earlier; hi = whichever ENDS later.
            // `targetEnd` is the tick offset just past `target`'s
            // duration, so pasting respects the full extent of the
            // last selected element.
            let aFirst = anchorStart <= targetStart
            let timeLo = aFirst ? anchorStart : targetStart
            let timeHi = aFirst
                ? max(
                    targetEnd,
                    anchorEndPosition(of: anchor, in: score)
                        ?? anchorStart,
                )
                : max(
                    anchorEndPosition(of: anchor, in: score) ?? anchorStart,
                    targetEnd,
                )

            var cells: [RangeCell] = []
            for staffIdx in staffLo ... staffHi {
                guard allStaves.indices.contains(staffIdx) else {
                    continue
                }
                let measures = allStaves[staffIdx].staff.measures
                for measureIdx in timeLo.measure ... timeHi.measure {
                    guard measures.indices.contains(measureIdx) else {
                        continue
                    }
                    for (voiceIdx, voice)
                        in measures[measureIdx].voices.enumerated()
                    {
                        let measureTotalTicks =
                            Self.totalTicks(of: voice, division: division)
                        let tickStart = (measureIdx == timeLo.measure)
                            ? timeLo.tick : 0
                        let tickEnd = (measureIdx == timeHi.measure)
                            ? timeHi.tick : measureTotalTicks
                        var captured: [VoiceElement] = []
                        var tick = 0
                        for el in voice.elements {
                            let elTicks: Int
                            switch el {
                            case let .chord(c):
                                elTicks = c.duration.ticks(division: division)
                            case let .chord(r) where r.notes.isEmpty:
                                elTicks = r.duration.ticks(division: division)
                            default:
                                // Non-timed (clef / key sig / barline /
                                // …) skipped — they don't move under
                                // paste alignment, and pasting them
                                // wholesale would surprise the user.
                                continue
                            }
                            if tick >= tickStart && tick < tickEnd {
                                captured.append(el)
                            }
                            tick += elTicks
                        }
                        if !captured.isEmpty {
                            cells.append(RangeCell(
                                staffOffset: staffIdx - staffLo,
                                measureOffset:
                                measureIdx - timeLo.measure,
                                voiceIndex: voiceIdx,
                                elements: captured,
                            ))
                        }
                    }
                }
            }
            guard !cells.isEmpty else { return nil }
            return RangePayload(
                cells: cells,
                staffCount: staffHi - staffLo + 1,
                measureCount: timeHi.measure - timeLo.measure + 1,
            )
        }

        private struct MeasureTick: Comparable {
            let measure: Int
            let tick: Int
            static func < (lhs: MeasureTick, rhs: MeasureTick) -> Bool {
                if lhs.measure != rhs.measure {
                    return lhs.measure < rhs.measure
                }
                return lhs.tick < rhs.tick
            }
        }

        private func elementTickPosition(
            of id: ScoreItemID, in score: Score,
        ) -> MeasureTick? {
            guard let staffVal = score[id.staff] else {
                return nil
            }
            let measures = staffVal.measures
            guard measures.indices.contains(id.measureIndex) else {
                return nil
            }
            let voices = measures[id.measureIndex].voices
            guard voices.indices.contains(id.voiceIndex) else {
                return nil
            }
            let elements = voices[id.voiceIndex].elements
            guard elements.indices.contains(id.elementIndex) else {
                return nil
            }
            var tick = 0
            for i in 0 ..< id.elementIndex {
                switch elements[i] {
                case let .chord(c):
                    tick += c.duration.ticks(division: score.division)
                case let .chord(r) where r.notes.isEmpty:
                    tick += r.duration.ticks(division: score.division)
                default: continue
                }
            }
            return MeasureTick(measure: id.measureIndex, tick: tick)
        }

        /// Tick position one element-width past `id` — the slice's
        /// upper bound when copying so the target's full duration is
        /// included in the captured range.
        private func elementEndTickPosition(
            of id: ScoreItemID, in score: Score,
        ) -> MeasureTick? {
            guard let start = elementTickPosition(of: id, in: score),
                  let element = score[id.staff]
                      .flatMap({ staff -> VoiceElement? in
                          guard staff.measures.indices.contains(id.measureIndex),
                                staff.measures[id.measureIndex].voices
                                    .indices.contains(id.voiceIndex),
                                    staff.measures[id.measureIndex]
                                        .voices[id.voiceIndex].elements
                                        .indices.contains(id.elementIndex)
                          else { return nil }
                          return staff.measures[id.measureIndex]
                              .voices[id.voiceIndex]
                              .elements[id.elementIndex]
                      })
            else { return nil }
            let division = score.division
            switch element {
            case let .chord(c):
                return MeasureTick(
                    measure: start.measure,
                    tick: start.tick + c.duration.ticks(division: division),
                )
            case let .chord(r) where r.notes.isEmpty:
                return MeasureTick(
                    measure: start.measure,
                    tick: start.tick + r.duration.ticks(division: division),
                )
            default:
                return start
            }
        }

        private func anchorEndPosition(
            of id: ScoreItemID, in score: Score,
        ) -> MeasureTick? {
            elementEndTickPosition(of: id, in: score)
        }

        private static func totalTicks(
            of voice: Voice, division: Int,
        ) -> Int {
            voice.elements.reduce(0) { acc, el in
                switch el {
                case let .chord(c):
                    return acc + c.duration.ticks(division: division)
                case let .chord(r) where r.notes.isEmpty:
                    return acc + r.duration.ticks(division: division)
                default:
                    return acc
                }
            }
        }

        /// Capture the selection like `copy`, then replace each
        /// captured element with a rest of the same duration via
        /// `DeleteVoiceElement`. For `.range` the deletes run from the
        /// last element to the first so element indices stay valid as
        /// the loop progresses.
        private func cutSelectedElement() -> Bool {
            guard let controller = inputController else { return false }
            switch selection {
            case .single:
                guard let id = selectedVoiceElementID(),
                      let element = controller.score[id]
                else { return false }
                voiceElementClipboard = element
                voiceRangeClipboard = nil
                do {
                    try controller.apply(
                        DeleteVoiceElement(at: id),
                        undoManager: undoManager,
                    )
                    adoptEditedScore(controller.score)
                    selection = .single(.rest(RestID(
                        staff: id.staff,
                        measureIndex: id.measureIndex,
                        voiceIndex: id.voiceIndex,
                        elementIndex: id.elementIndex,
                    )))
                    errorMessage = "Cut"
                } catch {
                    errorMessage = exampleErrorDescription(error)
                }
                return true
            case let .range(anchor, target):
                guard let payload = collectRangePayload(
                    anchor: anchor, target: target,
                    score: controller.score,
                )
                else {
                    errorMessage = "Range cut: nothing to cut."
                    return true
                }
                voiceRangeClipboard = payload
                voiceElementClipboard = nil
                let total = payload.cells.reduce(0) {
                    $0 + $1.elements.count
                }
                do {
                    // Bundle every cell's deletes into one composite
                    // command so a single ⌘Z restores the whole range
                    // at once. Identifying each cell's live element
                    // index range can't go by reference (VoiceElement
                    // is a value type) — find it by position.
                    let cutAllStaves = controller.score.allStaves
                    let anchorFlatIdx = cutAllStaves.firstIndex(where: {
                        $0.address == anchor.staff
                    }) ?? 0
                    let targetFlatIdx = cutAllStaves.firstIndex(where: {
                        $0.address == target.staff
                    }) ?? 0
                    let staffBase = min(anchorFlatIdx, targetFlatIdx)
                    let measureBase = min(
                        anchor.measureIndex, target.measureIndex,
                    )
                    var subCommands: [any EditCommand] = []
                    for cell in payload.cells {
                        let staffFlat = staffBase + cell.staffOffset
                        let measure = measureBase + cell.measureOffset
                        guard cutAllStaves.indices.contains(staffFlat) else {
                            continue
                        }
                        let staffAddress = cutAllStaves[staffFlat].address
                        let staffVal = cutAllStaves[staffFlat].staff
                        let voice = staffVal
                            .measures[measure].voices[cell.voiceIndex]
                        let baseIndices = Self.findContiguousIndices(
                            of: cell.elements, in: voice.elements,
                        )
                        guard let (lo, hi) = baseIndices else { continue }
                        // Schedule deletes back-to-front so indices
                        // stay valid as the composite executes.
                        for elemIdx in stride(
                            from: hi, through: lo, by: -1,
                        ) {
                            let id = VoiceElementID(
                                staff: staffAddress,
                                measureIndex: measure,
                                voiceIndex: cell.voiceIndex,
                                elementIndex: elemIdx,
                            )
                            subCommands.append(DeleteVoiceElement(at: id))
                        }
                    }
                    let staffBaseAddress = cutAllStaves.indices
                        .contains(staffBase)
                        ? cutAllStaves[staffBase].address
                        : StaffAddress(partIndex: 0, staffIndexInPart: 0)
                    try controller.apply(
                        CompositeEditCommand(
                            commands: subCommands,
                            location: VoiceElementID(
                                staff: staffBaseAddress,
                                measureIndex: measureBase,
                                voiceIndex: payload.cells.first?
                                    .voiceIndex ?? 0,
                                elementIndex: 0,
                            ),
                        ),
                        undoManager: undoManager,
                    )
                    adoptEditedScore(controller.score)
                    selection = .none
                    errorMessage = "Cut \(total) element"
                        + (total == 1 ? "" : "s")
                } catch {
                    errorMessage = exampleErrorDescription(error)
                }
                return true
            default:
                return false
            }
        }

        /// Locate the `[lo...hi]` element index range in `live` whose
        /// values are `Equatable`-equal to `slice` in order. Returns
        /// the first such match or nil. Used by range cut to find the
        /// live position of captured cells (we can't track by reference
        /// because VoiceElement is a value type).
        private static func findContiguousIndices(
            of slice: [VoiceElement], in live: [VoiceElement],
        ) -> (Int, Int)? {
            guard !slice.isEmpty else { return nil }
            outer: for start in 0 ... (live.count - slice.count) {
                for k in 0 ..< slice.count where live[start + k] != slice[k] {
                    continue outer
                }
                return (start, start + slice.count - 1)
            }
            return nil
        }

        /// Paste the clipboard onto the currently-selected chord or rest.
        /// `voiceElementClipboard` (single) → `PasteVoiceElement`.
        /// `voiceRangeClipboard` (range) → per-cell `PasteVoiceElements`
        /// loop, with all cells grouped under one undo step. The range
        /// path refuses when the destination's tick offset within its
        /// measure doesn't match the source's leading edge — paste only
        /// drops the captured shape onto an aligned beat.
        private func pasteAtSelection() -> Bool {
            if voiceElementClipboard == nil
                && voiceRangeClipboard == nil
            {
                errorMessage = "Clipboard is empty."
                return true
            }
            guard let id = selectedVoiceElementID(),
                  let controller = inputController
            else {
                errorMessage = "Select a chord or rest to paste onto."
                return true
            }
            do {
                if let payload = voiceRangeClipboard {
                    try pasteRangePayload(
                        payload, at: id, controller: controller,
                    )
                } else if let element = voiceElementClipboard {
                    // Reuse the cross-measure paste path so a single
                    // long element (e.g. a whole copied to a position
                    // too close to the bar end) spills into following
                    // measures with a tied chord chain instead of
                    // refusing with "not enough room".
                    let singleCell = RangeCell(
                        staffOffset: 0, measureOffset: 0,
                        voiceIndex: id.voiceIndex,
                        elements: [element],
                    )
                    let payload = RangePayload(
                        cells: [singleCell],
                        staffCount: 1, measureCount: 1,
                    )
                    try pasteRangePayload(
                        payload, at: id, controller: controller,
                    )
                }
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
            return true
        }

        /// Drop a range payload onto the score at `targetID`. Source
        /// cells are concatenated per (staff, voice) into tick streams;
        /// each stream walks from the target's tick offset, splitting
        /// elements at destination measure boundaries (chord → tied
        /// chain, rest → aligned rests). For each affected destination
        /// measure the function builds a single replacement payload
        /// (with leading/trailing trim of any boundary elements) and
        /// applies it via `PasteVoiceElements`. All sub-commands run
        /// inside a `CompositeEditCommand` so one ⌘Z reverses the
        /// entire paste.
        private func pasteRangePayload(
            _ payload: RangePayload,
            at targetID: VoiceElementID,
            controller: NoteInputController,
        ) throws {
            let score = controller.score
            let targetTick = Self.elementTickOffset(
                of: targetID, in: score,
            ) ?? 0

            // Group cells into (staffOffset, voiceIndex) streams,
            // sorted by source measureOffset, with elements
            // concatenated.  Multi-measure source cells become one
            // continuous tick stream per destination voice.
            struct StreamKey: Hashable {
                let staffOffset: Int
                let voiceIndex: Int
            }
            var streams: [StreamKey: [VoiceElement]] = [:]
            for cell in payload.cells {
                let key = StreamKey(
                    staffOffset: cell.staffOffset,
                    voiceIndex: cell.voiceIndex,
                )
                streams[key, default: []].append(contentsOf: cell.elements)
            }

            let pasteAllStaves = score.allStaves
            let targetFlatIdx = pasteAllStaves.firstIndex(where: {
                $0.address == targetID.staff
            }) ?? 0

            var subCommands: [any EditCommand] = []
            for (key, streamElements) in streams {
                let destFlatStaff = targetFlatIdx + key.staffOffset
                guard pasteAllStaves.indices.contains(destFlatStaff) else {
                    throw SheetMusicError.invalidEdit(EditRefusal(
                        operation: "Paste",
                        reason: .staffNotFound(StaffAddress(
                            partIndex: destFlatStaff,
                            staffIndexInPart: 0,
                        )),
                    ))
                }
                let destAddress = pasteAllStaves[destFlatStaff].address
                guard score[destAddress]?.measures
                    .indices.contains(targetID.measureIndex) ?? false
                else {
                    throw SheetMusicError.invalidEdit(EditRefusal(
                        operation: "Paste",
                        reason: .targetNotFound(VoiceElementID(
                            staff: destAddress,
                            measureIndex: targetID.measureIndex,
                            voiceIndex: targetID.voiceIndex,
                            elementIndex: targetID.elementIndex,
                        )),
                    ))
                }

                // Walk the stream tick-by-tick across destination
                // measures, splitting elements at boundaries.
                let pieces = try Self.buildStreamPieces(
                    stream: streamElements,
                    destStaffAddress: destAddress,
                    destVoice: key.voiceIndex,
                    startMeasure: targetID.measureIndex,
                    startTickInMeasure: targetTick,
                    score: score,
                )

                for piece in pieces {
                    let cmd = try Self.buildMeasureReplaceCommand(
                        staffAddress: destAddress,
                        measure: piece.measureIdx,
                        voice: key.voiceIndex,
                        tickStartInMeasure: piece.tickStartInMeasure,
                        pieceElements: piece.elements,
                        score: score,
                    )
                    subCommands.append(cmd)
                }
            }

            try controller.apply(
                CompositeEditCommand(
                    commands: subCommands, location: targetID,
                ),
                undoManager: undoManager,
            )
            adoptEditedScore(controller.score)
            if let firstCell = payload.cells.first,
               let firstElement = firstCell.elements.first
            {
                anchorSelectionAfterPaste(
                    at: targetID, firstElement: firstElement,
                )
            }
            let total = payload.cells.reduce(0) {
                $0 + $1.elements.count
            }
            errorMessage = "Pasted \(total) element"
                + (total == 1 ? "" : "s")
        }

        /// One contiguous slice of a paste stream that lives in a
        /// single destination measure. `tickStartInMeasure` is the
        /// tick where the first element of the slice begins; the slice
        /// runs to `tickStartInMeasure + sum(durations)`.
        private struct DestinationPiece {
            let measureIdx: Int
            let tickStartInMeasure: Int
            let elements: [VoiceElement]
        }

        /// Walk a flat source stream and split it into per-measure
        /// destination pieces. Source elements that overflow the
        /// current destination measure boundary become tied chord
        /// chains (chord case) or aligned rests (rest case) on each
        /// side of the boundary.
        private static func buildStreamPieces(
            stream: [VoiceElement],
            destStaffAddress: StaffAddress,
            destVoice: Int,
            startMeasure: Int,
            startTickInMeasure: Int,
            score: Score,
        ) throws -> [DestinationPiece] {
            var result: [DestinationPiece] = []
            let division = score.division
            guard let destStaffVal = score[destStaffAddress] else {
                throw SheetMusicError.invalidEdit(EditRefusal(
                    operation: "Paste",
                    reason: .staffNotFound(destStaffAddress),
                ))
            }
            let measures = destStaffVal.measures

            var pieceMeasure = startMeasure
            var pieceTickStart = startTickInMeasure
            var pieceElements: [VoiceElement] = []
            var measureTickCursor = startTickInMeasure

            func flushPiece() {
                guard !pieceElements.isEmpty else { return }
                result.append(DestinationPiece(
                    measureIdx: pieceMeasure,
                    tickStartInMeasure: pieceTickStart,
                    elements: pieceElements,
                ))
                pieceElements = []
            }

            func advanceMeasure() throws {
                flushPiece()
                pieceMeasure += 1
                pieceTickStart = 0
                measureTickCursor = 0
                if pieceMeasure >= measures.count {
                    throw SheetMusicError.invalidEdit(EditRefusal(
                        operation: "Paste",
                        reason: .targetNotFound(VoiceElementID(
                            staff: destStaffAddress,
                            measureIndex: pieceMeasure,
                            voiceIndex: destVoice,
                            elementIndex: 0,
                        )),
                    ))
                }
            }

            for srcEl in stream {
                var elementTicksRemaining: Int
                switch srcEl {
                case let .chord(c):
                    elementTicksRemaining = c.duration
                        .ticks(division: division)
                case let .chord(r) where r.notes.isEmpty:
                    elementTicksRemaining = r.duration
                        .ticks(division: division)
                default:
                    continue
                }
                var isFirstSplit = true

                while elementTicksRemaining > 0 {
                    let voice = measures[pieceMeasure]
                        .voices[destVoice]
                    let measureTotal = totalTicks(
                        of: voice, division: division,
                    )
                    if measureTickCursor >= measureTotal {
                        try advanceMeasure()
                        continue
                    }
                    let measureRemaining = measureTotal - measureTickCursor
                    let partTicks = min(
                        elementTicksRemaining, measureRemaining,
                    )
                    let isLastSplit = (partTicks == elementTicksRemaining)

                    let durations = DurationChangeAlgorithm
                        .alignedDurations(
                            forTicks: partTicks,
                            rtickStart: measureTickCursor,
                            division: division,
                        )
                    switch srcEl {
                    case let .chord(c) where !c.notes.isEmpty:
                        for (i, dur) in durations.enumerated() {
                            let isFirstChain =
                                isFirstSplit && i == 0
                            let isLastChain =
                                isLastSplit && i == durations.count - 1
                            var notes = c.notes
                            for ni in notes.indices {
                                notes[ni].tieBack = isFirstChain
                                    ? c.notes[ni].tieBack : 1
                                notes[ni].tieForward = isLastChain
                                    ? c.notes[ni].tieForward : 1
                            }
                            pieceElements.append(.chord(Chord(
                                duration: dur,
                                notes: notes,
                                arpeggio: isFirstChain
                                    ? c.arpeggio : nil,
                                lyrics: isFirstChain
                                    ? c.lyrics : [],
                            )))
                        }
                    case .chord:
                        // Empty chord = rest.
                        for dur in durations {
                            pieceElements.append(
                                .rest(duration: dur),
                            )
                        }
                    default:
                        break
                    }

                    measureTickCursor += partTicks
                    elementTicksRemaining -= partTicks
                    isFirstSplit = false
                }
            }
            flushPiece()
            return result
        }

        /// Build one `PasteVoiceElements` for a single destination
        /// measure: replaces the element range covering
        /// `[tickStartInMeasure, tickStartInMeasure + sum(piece))` with
        /// `[trimmedLeading] + pieceElements + [trimmedTrailing]`. The
        /// total replacement ticks equal the consumed range's ticks, so
        /// `PasteVoiceElements`' rebalance lengthen path simply
        /// substitutes — no rest spillover.
        private static func buildMeasureReplaceCommand(
            staffAddress: StaffAddress,
            measure: Int,
            voice: Int,
            tickStartInMeasure: Int,
            pieceElements: [VoiceElement],
            score: Score,
        ) throws -> any EditCommand {
            let division = score.division
            guard let staffVal = score[staffAddress] else {
                throw SheetMusicError.invalidEdit(EditRefusal(
                    operation: "Paste",
                    reason: .staffNotFound(staffAddress),
                ))
            }
            let v = staffVal.measures[measure].voices[voice]
            let pieceTicks = pieceElements.reduce(0) {
                $0 + tickOf($1, division: division)
            }
            let tickEnd = tickStartInMeasure + pieceTicks

            // Locate the leading element (the one whose range covers
            // tickStartInMeasure) and the trailing element (whose range
            // covers tickEnd-1). Walk voice.elements summing ticks.
            var tick = 0
            var leadingIdx: Int?
            var leadingStart = 0
            var leadingEnd = 0
            var trailingIdx: Int?
            var trailingStart = 0
            var trailingEnd = 0
            for (i, el) in v.elements.enumerated() {
                let elTicks = tickOf(el, division: division)
                if elTicks == 0 { continue }
                let elStart = tick
                let elEnd = tick + elTicks
                if leadingIdx == nil
                    && elStart <= tickStartInMeasure
                    && tickStartInMeasure < elEnd
                {
                    leadingIdx = i
                    leadingStart = elStart
                    leadingEnd = elEnd
                }
                if elStart < tickEnd && tickEnd <= elEnd {
                    trailingIdx = i
                    trailingStart = elStart
                    trailingEnd = elEnd
                }
                tick = elEnd
            }
            guard let loIdx = leadingIdx else {
                throw SheetMusicError.invalidEdit(EditRefusal(
                    operation: "Paste",
                    reason: .targetNotFound(VoiceElementID(
                        staff: staffAddress,
                        measureIndex: measure,
                        voiceIndex: voice,
                        elementIndex: 0,
                    )),
                ))
            }
            // Single-element overlap (loIdx == hiIdx) is fine — we
            // trim both ends of the same element. trailingIdx unset
            // means tickEnd reached past the measure tail; treat it
            // as a no-trailing-trim case using the leading element
            // as the consumed extent.
            let hiIdx = trailingIdx ?? loIdx
            let hiStart = trailingIdx == nil ? leadingStart : trailingStart
            let hiEnd = trailingIdx == nil ? leadingEnd : trailingEnd

            let leadingTrim = tickStartInMeasure - leadingStart
            let trailingTrim = hiEnd - tickEnd
            // If the trailing trim is negative (shouldn't happen given
            // the scan), bail.
            guard trailingTrim >= 0 else {
                throw SheetMusicError.invalidEdit(EditRefusal(
                    operation: "Paste",
                    reason: .insufficientRoom(
                        neededTicks: tickEnd - tickStartInMeasure,
                        availableTicks: hiEnd - hiStart,
                    ),
                ))
            }

            var replacement: [VoiceElement] = []
            // Leading trim: keep [leadingStart, tickStartInMeasure).
            if leadingTrim > 0 {
                replacement.append(contentsOf: trimmedBoundary(
                    element: v.elements[loIdx],
                    ticks: leadingTrim,
                    rtickStart: leadingStart,
                    tieBackKeepsOriginal: true,
                    tieForwardKeepsOriginal: false,
                    division: division,
                ))
            }
            replacement.append(contentsOf: pieceElements)
            // Trailing trim: keep [tickEnd, hiEnd).
            if trailingTrim > 0 {
                replacement.append(contentsOf: trimmedBoundary(
                    element: v.elements[hiIdx],
                    ticks: trailingTrim,
                    rtickStart: tickEnd,
                    tieBackKeepsOriginal: false,
                    tieForwardKeepsOriginal: true,
                    division: division,
                ))
            }

            return PasteVoiceElements(
                at: VoiceElementID(
                    staff: staffAddress,
                    measureIndex: measure,
                    voiceIndex: voice,
                    elementIndex: loIdx,
                ),
                elements: replacement,
            )
        }

        /// Build a tied chord chain or aligned rest sequence for a
        /// trimmed boundary element. `tieBackKeepsOriginal` and
        /// `tieForwardKeepsOriginal` control whether the chain's outer
        /// tie endpoints inherit the source element's ties (so the
        /// trim integrates with the surrounding score) or get cleared
        /// (the trimmed end abuts pasted content from a different
        /// origin).
        private static func trimmedBoundary(
            element: VoiceElement,
            ticks: Int,
            rtickStart: Int,
            tieBackKeepsOriginal: Bool,
            tieForwardKeepsOriginal: Bool,
            division: Int,
        ) -> [VoiceElement] {
            let durations = DurationChangeAlgorithm.alignedDurations(
                forTicks: ticks,
                rtickStart: rtickStart,
                division: division,
            )
            switch element {
            case let .chord(c) where !c.notes.isEmpty:
                var pieces: [VoiceElement] = []
                for (i, dur) in durations.enumerated() {
                    let isFirst = i == 0
                    let isLast = i == durations.count - 1
                    var notes = c.notes
                    for ni in notes.indices {
                        notes[ni].tieBack = isFirst
                            ? (
                                tieBackKeepsOriginal
                                    ? c.notes[ni].tieBack : nil
                            )
                            : 1
                        notes[ni].tieForward = isLast
                            ? (
                                tieForwardKeepsOriginal
                                    ? c.notes[ni].tieForward : nil
                            )
                            : 1
                    }
                    pieces.append(.chord(Chord(
                        duration: dur,
                        notes: notes,
                        arpeggio: isFirst && tieBackKeepsOriginal
                            ? c.arpeggio : nil,
                        lyrics: isFirst && tieBackKeepsOriginal
                            ? c.lyrics : [],
                    )))
                }
                return pieces
            case .chord:
                // Empty chord = rest.
                return durations.map { .rest(duration: $0) }
            default:
                return [element]
            }
        }

        private static func tickOf(
            _ el: VoiceElement, division: Int,
        ) -> Int {
            switch el {
            case let .chord(c):
                return c.duration.ticks(division: division)
            default:
                return 0
            }
        }

        /// Tick offset of the element at `id` within its destination
        /// measure. Sums the ticks of preceding chord/rest elements;
        /// non-timed elements contribute zero.
        private static func elementTickOffset(
            of id: VoiceElementID, in score: Score,
        ) -> Int? {
            guard let staffVal = score[id.staff] else { return nil }
            let measures = staffVal.measures
            guard measures.indices.contains(id.measureIndex)
            else { return nil }
            let voices = measures[id.measureIndex].voices
            guard voices.indices.contains(id.voiceIndex)
            else { return nil }
            let elements = voices[id.voiceIndex].elements
            guard elements.indices.contains(id.elementIndex)
            else { return nil }
            var tick = 0
            for i in 0 ..< id.elementIndex {
                tick += tickOf(elements[i], division: score.division)
            }
            return tick
        }

        /// Keep the score selection on the chord the lyric caret sits on, so
        /// ⌘L, Delete and the arrow shortcuts all target what the user is
        /// typing into. The pre-session lyric editor did this inline on every
        /// advance; the session-based flow has to do it at each caret move.
        private func syncSelectionToLyricCursor() {
            guard let cursor = lyricSession.cursor,
                  let controller = inputController,
                  case let .chord(chord) = controller.score[cursor.location],
                  !chord.notes.isEmpty
            else { return }
            let location = cursor.location
            selection = .single(.note(NoteID(
                staff: location.staff,
                measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex,
                elementIndex: location.elementIndex,
                noteIndexInChord: 0,
            )))
        }

        /// Re-anchor the selection on the first chord/rest produced by
        /// a paste so subsequent edits land where the user is looking.
        private func anchorSelectionAfterPaste(
            at id: VoiceElementID, firstElement: VoiceElement?,
        ) {
            switch firstElement {
            case let .chord(c) where !c.notes.isEmpty:
                selection = .single(.note(NoteID(
                    staff: id.staff,
                    measureIndex: id.measureIndex,
                    voiceIndex: id.voiceIndex,
                    elementIndex: id.elementIndex,
                    noteIndexInChord: 0,
                )))
            case .chord:
                // Empty chord = rest.
                selection = .single(.rest(RestID(
                    staff: id.staff,
                    measureIndex: id.measureIndex,
                    voiceIndex: id.voiceIndex,
                    elementIndex: id.elementIndex,
                )))
            default:
                break
            }
        }

        /// VoiceElementID derived from the current selection, or nil
        /// when the selection isn't a single chord/rest. Used by
        /// copy / cut / paste so they share the same selection model.
        private func selectedVoiceElementID() -> VoiceElementID? {
            switch selection {
            case let .single(.note(n)):
                return VoiceElementID(n)
            case let .single(.rest(r)):
                return VoiceElementID(r)
            default:
                return nil
            }
        }

        /// True when the accidental toolbar buttons should be enabled —
        /// a single note is selected and it does not live on a drum
        /// staff (where accidentals are meaningless).
        private var isAccidentalActionable: Bool {
            guard case let .single(.note(id)) = selection,
                  let controller = inputController
            else { return false }
            return !isDrumStaff(noteID: id, controller: controller)
        }

        /// Toolbar button for one accidental value. Emits a `SetAccidental`
        /// command when clicked and selects the resulting (respelled) note
        /// so the user can chain another edit. Disabled when no note is
        /// selected, or when the selected note sits on a drum staff.
        private func accidentalButton(
            _ accidental: Accidental, glyph: String, help: String,
        ) -> some View {
            Button {
                if case let .single(.note(id)) = selection {
                    applyAccidental(accidental, to: id)
                }
            } label: {
                // Use the SMuFL/Unicode accidental glyph directly so the
                // toolbar reads at a glance — system accidental symbols
                // exist but only as colour-rendered SF Symbols which
                // don't read in a small toolbar slot.
                Text(glyph)
                    .font(.system(size: 16))
                    .accessibilityLabel(help)
            }
            .disabled(!isAccidentalActionable)
            .help(help)
        }

        /// Apply `SetAccidental` to the given note, refresh the layout,
        /// and re-anchor the selection on the (possibly respelled) note
        /// at the same NoteID. Plays a preview at the new pitch so the
        /// user hears the respell.
        /// Tuplet toggle: ⌘+digit on a non-tuplet element creates a
        /// tuplet, on an existing tuplet member removes it. Returns
        /// `true` when the event was consumed (selection actionable)
        /// so the key monitor can stop AppKit from beeping. Errors
        /// (target's ticks don't divide evenly, target isn't a
        /// chord/rest, etc.) are surfaced through `errorMessage`.
        private func applyCreateTuplet(
            actualNotes: Int, normalNotes: Int,
        ) -> Bool {
            guard let id = selectedVoiceElementID(),
                  let controller = inputController
            else { return false }
            let voice: Voice? = {
                guard let staffVal = controller.score[id.staff],
                      staffVal.measures.indices.contains(id.measureIndex),
                      staffVal.measures[id.measureIndex].voices
                          .indices.contains(id.voiceIndex)
                else { return nil }
                return staffVal.measures[id.measureIndex]
                    .voices[id.voiceIndex]
            }()
            let alreadyInTuplet = voice?.tuplets.contains(where: {
                $0.startIndex <= id.elementIndex
                    && id.elementIndex <= $0.endIndex
            }) ?? false
            do {
                if alreadyInTuplet {
                    try controller.apply(
                        RemoveTuplet(at: id),
                        undoManager: undoManager,
                    )
                    errorMessage = "Tuplet removed"
                } else {
                    try controller.apply(
                        CreateTuplet(
                            at: id,
                            actualNotes: actualNotes,
                            normalNotes: normalNotes,
                        ),
                        undoManager: undoManager,
                    )
                    errorMessage = "Tuplet \(actualNotes):\(normalNotes)"
                }
                adoptEditedScore(controller.score)
                // Re-anchor on the element at the same path (first
                // member of the new tuplet, or the single replacement
                // after removal).
                let firstElement = controller.score[id]
                anchorSelectionAfterPaste(
                    at: id, firstElement: firstElement,
                )
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
            return true
        }

        private func applyAccidental(
            _ accidental: Accidental?, to noteID: NoteID,
        ) {
            guard let controller = inputController else { return }
            do {
                try controller.apply(
                    SetAccidental(at: noteID, accidental: accidental),
                    undoManager: undoManager,
                )
                adoptEditedScore(controller.score)
                // The note retained its NoteID — re-anchor selection so
                // the canvas keeps showing the highlight on the new
                // pitch / glyph.
                selection = .single(.note(noteID))
                playbackEngine.playPreview(
                    noteID: noteID, in: controller.score,
                )
                errorMessage = accidental.map {
                    "Set accidental: \($0)"
                } ?? "Cleared accidental"
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
        }

        /// Look up the raw clef type string ("G", "F", "G8vb", …) for
        /// the clef under `anchor`. Returns nil if the score is missing
        /// or the anchor no longer resolves (e.g. the explicit clef
        /// element was deleted before the popover opened).
        private func currentClefRawType(for anchor: ClefAnchor) -> String? {
            guard let score else { return nil }
            switch anchor {
            case let .explicit(veID):
                if case let .clef(c) = score[veID] {
                    return c.concertClefType
                }
                return nil
            case let .staffDefault(staff):
                return score[staff]?.defaultClefType
            }
        }

        /// Dispatch the popover's pick into an edit command — replace
        /// an explicit clef voice element, or set the staff's default
        /// clef when the user tapped the synthesized opening clef.
        /// Either path goes through `NoteInputController.apply` so the
        /// `undoManager` records a reverse command for ⌘Z.
        private func applyClefChoice(
            _ choice: ClefChoice, for anchor: ClefAnchor,
        ) {
            guard let controller = inputController else { return }
            do {
                switch anchor {
                case let .explicit(veID):
                    let newClef = Clef(concertClefType: choice.rawType)
                    try controller.apply(
                        ReplaceVoiceElement(
                            at: veID,
                            with: .clef(newClef),
                        ),
                        undoManager: undoManager,
                    )
                case let .staffDefault(staff):
                    try controller.apply(
                        SetStaffDefaultClef(
                            staff: staff,
                            newRawType: choice.rawType,
                        ),
                        undoManager: undoManager,
                    )
                }
                adoptEditedScore(controller.score)
            } catch {
                errorMessage = "Failed to change clef: " +
                    exampleErrorDescription(error)
            }
            clefPopover = nil
            selection = .none
        }

        /// Remove a single note from its chord via
        /// `RemoveNoteFromChord`. When the chord had only that one note,
        /// the library collapses the element to a rest of the same
        /// duration; selection moves to that new rest. Otherwise the
        /// chord shrinks by one note and we re-anchor the selection on a
        /// surviving note (the previous index, clamped) so the user can
        /// keep editing the same chord.
        private func removeNoteFromChord(
            noteID: NoteID,
            controller: NoteInputController,
        ) {
            let veID = VoiceElementID(noteID)
            let priorNoteCount: Int
            if case let .chord(c) = controller.score[veID] {
                priorNoteCount = c.notes.count
            } else {
                priorNoteCount = 0
            }
            do {
                try controller.apply(
                    RemoveNoteFromChord(at: noteID),
                    undoManager: undoManager,
                )
                adoptEditedScore(controller.score)
                if priorNoteCount <= 1 {
                    let newRest = RestID(
                        staff: veID.staff,
                        measureIndex: veID.measureIndex,
                        voiceIndex: veID.voiceIndex,
                        elementIndex: veID.elementIndex,
                    )
                    selection = .single(.rest(newRest))
                } else {
                    // Clamp to the new range — removing index N from a
                    // chord of size N+1 leaves indices 0...N-1.
                    let newIdx = max(
                        0,
                        min(
                            noteID.noteIndexInChord,
                            priorNoteCount - 2,
                        ),
                    )
                    let surviving = NoteID(
                        staff: noteID.staff,
                        measureIndex: noteID.measureIndex,
                        voiceIndex: noteID.voiceIndex,
                        elementIndex: noteID.elementIndex,
                        noteIndexInChord: newIdx,
                    )
                    selection = .single(.note(surviving))
                }
                errorMessage = "Removed note"
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
        }

        /// Replace the currently-selected chord/rest with a rest of the
        /// same duration via `DeleteVoiceElement`. Selection moves to
        /// the resulting rest so subsequent edits (transpose, retype)
        /// target the new element. No-op when nothing actionable is
        /// selected.
        private func deleteSelectedElement(
            controller: NoteInputController,
        ) {
            // Tuplet selection: collapse the tuplet to a rest of the
            // same total duration. RemoveTuplet alone keeps the first
            // member's pitch (used by the ⌘3 toggle); for Backspace
            // we want the "delete the whole thing" semantic, so chain
            // RemoveTuplet → DeleteVoiceElement under one Composite
            // so a single ⌘Z restores everything.
            if case let .single(.tuplet(tid)) = selection {
                let veID = VoiceElementID(
                    staff: tid.staff,
                    measureIndex: tid.measureIndex,
                    voiceIndex: tid.voiceIndex,
                    elementIndex: tid.startElementIndex,
                )
                do {
                    try controller.apply(
                        CompositeEditCommand(
                            commands: [
                                RemoveTuplet(at: veID),
                                DeleteVoiceElement(at: veID),
                            ],
                            location: veID,
                        ),
                        undoManager: undoManager,
                    )
                    adoptEditedScore(controller.score)
                    selection = .single(.rest(RestID(
                        staff: tid.staff,
                        measureIndex: tid.measureIndex,
                        voiceIndex: tid.voiceIndex,
                        elementIndex: tid.startElementIndex,
                    )))
                    errorMessage = "Tuplet deleted"
                } catch {
                    errorMessage = exampleErrorDescription(error)
                }
                return
            }
            let target: VoiceElementID
            switch selection {
            case let .single(.note(noteID)):
                target = VoiceElementID(noteID)
            case let .single(.rest(restID)):
                target = VoiceElementID(restID)
            default:
                errorMessage = "Select a note or rest to delete."
                return
            }
            do {
                try controller.apply(
                    DeleteVoiceElement(at: target),
                    undoManager: undoManager,
                )
                adoptEditedScore(controller.score)
                // Select the freshly-created rest so the user can keep
                // editing at the same beat.
                let newRest = RestID(
                    staff: target.staff,
                    measureIndex: target.measureIndex,
                    voiceIndex: target.voiceIndex,
                    elementIndex: target.elementIndex,
                )
                selection = .single(.rest(newRest))
                errorMessage = "Deleted"
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
        }

        /// Apply a ±semitone shift to the currently-selected note.
        /// Routed through `SetNotePitch` so undo / redo work the same
        /// way as letter-key insertion. The new TPC is computed by
        /// `PitchSpelling.shiftedTpc` using the active key signature
        /// at the note's location, matching MuseScore's
        /// `EditNote::upDownChromatic` behaviour.
        private func shiftSelectedNote(
            noteID: NoteID,
            by semitones: Int,
            controller: NoteInputController,
        ) {
            guard let original = controller.score[noteID] else {
                errorMessage = "Selected note not found in score"
                return
            }
            // Drum staves: shift by pitch but ignore the staff's key
            // signature for spelling, and never paint an accidental glyph.
            // Drum noteheads are positioned by the part's drum-line map,
            // not by chromatic spelling, and accidentals on a drum staff
            // are nonsensical even when the staff happens to carry a
            // KeySig element from the source file.
            let isDrumStaff = controller.score
                .part(at: noteID.staff)?.instrument.useDrumset ?? false
            let keySigForSpelling = isDrumStaff
                ? 0
                : controller.score.activeKey(at: noteID)
            guard let shifted = original.shifted(
                bySemitones: semitones, in: keySigForSpelling,
            )
            else {
                errorMessage = "Pitch out of MIDI range (0…127)"
                return
            }
            let accidentalToWrite = isDrumStaff ? nil : shifted.accidental
            do {
                try controller.apply(
                    SetNotePitch(
                        at: noteID,
                        pitch: shifted.pitch,
                        tpc: shifted.tpc,
                        accidental: accidentalToWrite,
                    ),
                    undoManager: undoManager,
                )
                adoptEditedScore(controller.score)
                playbackEngine.playPreview(
                    noteID: noteID, in: controller.score,
                )
                scrollToAffectedMeasure(measureIndex: noteID.measureIndex)
                errorMessage = "Shifted to MIDI \(shifted.pitch)"
            } catch {
                errorMessage = exampleErrorDescription(error)
            }
        }

        private func describeSelection(_ s: ScoreSelection) -> String {
            switch s {
            case .none: return "none"
            case .single(.rest): return "rest"
            case .single(.note): return "note"
            case .single(.tuplet): return "tuplet"
            case .single(.clef): return "clef"
            case .range: return "range"
            case .multi: return "multi"
            }
        }

        @ViewBuilder
        private func scoreContent(score: Score) -> some View {
            switch layoutMode {
            case .vertical:
                VerticalScoreContainer(
                    score: score,
                    verticalDoc: $verticalDoc,
                    options: verticalOptions,
                    scoreVersion: scoreVersion,
                    selection: selection,
                    voiceColors: exampleVoiceColors,
                    playbackCursor: playbackEngine.currentCursor,
                    isPlaying: playbackEngine.state == .playing,
                    isMarqueeMode: isMarqueeMode,
                    onTap: { loc, doc in
                        handleTap(at: loc, document: doc)
                    },
                    onMarqueeEnd: { rect, doc in
                        applyMarquee(rect: rect, document: doc)
                    },
                )
            case .horizontal:
                // Native NSScrollView handles pinch-zoom-around-cursor
                // reliably; a SwiftUI-only implementation fought
                // ScrollPosition's asynchronous updates.
                if let doc = horizontalDoc {
                    let screenScore = horizontalScreenScore ?? score
                    HorizontalScoreContainer(
                        score: screenScore,
                        document: doc,
                        measureContexts: horizontalContexts,
                        magnification: $magnification,
                        horizontalScrollX: $horizontalScrollX,
                        horizontalScrollY: $horizontalScrollY,
                        pendingHorizontalScroll: $pendingHorizontalScroll,
                        selection: selection,
                        voiceColors: exampleVoiceColors,
                        playbackCursor: playbackEngine.currentCursor,
                        isMarqueeMode: isMarqueeMode,
                        onTap: { loc in
                            handleTap(at: loc, document: doc)
                        },
                        onMarqueeEnd: { rect, doc in
                            applyMarquee(rect: rect, document: doc)
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
                                pendingScroll: $pendingHorizontalScroll,
                            )
                        },
                        contentVersion: AnyHashable(
                            horizontalContentVersion,
                        ),
                        inDocumentOverlay: {
                            guard lyricSession.isActive || textSession.isActive,
                                  let controller = inputController
                            else { return nil }
                            return AnyView(ScoreTextEntryOverlayHost(
                                document: doc,
                                lyricSession: lyricSession,
                                textSession: textSession,
                                controller: controller,
                                undoManager: undoManager,
                                focus: $textEntryFocused,
                                onApplied: { edited, affected in
                                    adoptEditedScore(edited)
                                    if let affected {
                                        scrollToAffectedMeasure(
                                            measureIndex: affected.measureIndex,
                                        )
                                    }
                                },
                                onError: { error in
                                    errorMessage = exampleErrorDescription(error)
                                },
                            ))
                        }(),
                        inDocumentOverlayKey: {
                            if let cursor = lyricSession.cursor {
                                return AnyHashable(
                                    ScoreTextEntryOverlayIdentity.lyric(cursor),
                                )
                            }
                            if let anchor = textSession.anchor {
                                return AnyHashable(
                                    ScoreTextEntryOverlayIdentity.text(
                                        kind: textSession.kind.overlayIdentity,
                                        anchor: anchor,
                                    ),
                                )
                            }
                            return nil
                        }(),
                        onViewportSizeChange: { size in
                            horizontalViewportSize = size
                        },
                    )
                }
            case .paged:
                PagedScoreContainer(
                    score: score,
                    options: ScoreViewOptions(
                        staffSize: 18, systemGap: 16,
                        wrapToViewWidth: true,
                        multiMeasureRest: collapseMultiMeasureRests
                            ? .collapse(minimumMeasures: 2)
                            : .disabled,
                        showsInvisibleElements: showsInvisibleElements,
                    ),
                    pageIndex: $pageIndex,
                    totalPages: $totalPages,
                )
            case .pdf:
                pdfPreview(score: score)
            case .originalPDF:
                originalPDFContent(score: score)
            }
        }

        @ViewBuilder
        private func originalPDFContent(score: Score) -> some View {
            if let pdf = originalPDF, let geometry = originalPDFGeometry {
                OriginalPDFView(
                    document: pdf,
                    geometry: geometry,
                    score: score,
                    cursor: playbackEngine.currentCursor,
                    followsCursor: true,
                    onTap: { item in handleOriginalPDFTap(item) },
                )
            } else {
                ContentUnavailableView(
                    "No PDF imported",
                    systemImage: "doc.richtext",
                    description: Text(
                        "Import a music PDF from the sidebar to play along on "
                            + "the original engraving.",
                    ),
                )
            }
        }

        /// Tap on the original PDF: while playing, seek; while paused, select
        /// the item and (for a note) preview its pitch. Mirrors `handleTap`.
        private func handleOriginalPDFTap(_ item: ScoreItemID?) {
            guard let item, let score else { return }
            if playbackEngine.state == .playing {
                playbackEngine.seek(to: .item(item))
                return
            }
            playbackEngine.clearCursor()
            switch item {
            case let .note(id):
                selection = .single(.note(id))
                playbackEngine.playPreview(noteID: id, in: score)
            case let .rest(id):
                selection = .single(.rest(id))
            case let .tuplet(id):
                selection = .single(.tuplet(id))
            case let .clef(anchor):
                selection = .single(.clef(anchor))
            }
        }

        private func pdfPreview(score: Score) -> some View {
            Group {
                if let layout = pdfLayout {
                    pdfPreviewContent(
                        doc: layout.doc, pages: layout.pages,
                        page: layout.page,
                    )
                } else {
                    ProgressView("Laying out…")
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity,
                        )
                        .background(Color(white: 0.92))
                }
            }
            .task(id: scoreVersion) {
                pdfLayout = PDFPreviewLayout.build(score: score)
            }
        }

        private func pdfPreviewContent(
            doc: LayoutDocument,
            pages: [PDFExporter.PageBatch],
            page: EngravingPage,
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
                page: page,
            )
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

            // Clef tap (when not playing) — open the popover instead
            // of falling through to the regular selection ladder.
            if case let .clef(anchor) = target {
                let raw = currentClefRawType(for: anchor) ?? "G"
                let rect = tester.clefHitRect(for: anchor)
                    ?? CGRect(
                        x: location.x - 12, y: location.y - 24,
                        width: 24, height: 48,
                    )
                clefPopover = ClefPopoverState(
                    anchor: anchor,
                    currentRawType: raw,
                    attachmentRect: rect,
                )
                selection = .single(.clef(anchor))
                return
            }

            let shift = NSEvent.modifierFlags.contains(.shift)

            // Beam without shift: range-select every note under the beam
            // run. This is our app-side policy — MuseScore would instead
            // let you edit the beam's length; we don't need that here.
            if case let .beam(notes) = target, !shift,
               let first = notes.first, let last = notes.last
            {
                selection = .range(
                    anchor: .note(first), target: .note(last),
                )
                return
            }

            // Everything else resolves to one "primary" ScoreItemID:
            //   - note/rest: themselves
            //   - stem/flag: the chord's first notehead
            //   - beam (with shift): the chord's first notehead
            let primary: ScoreItemID
            switch target {
            case let .note(id): primary = .note(id)
            case let .rest(id): primary = .rest(id)
            case let .tuplet(id): primary = .tuplet(id)
            case let .stem(notes), let .flag(notes), let .beam(notes):
                guard let first = notes.first else {
                    selection = .none
                    return
                }
                primary = .note(first)
            case let .clef(anchor):
                primary = .clef(anchor)
            }

            if shift {
                switch selection {
                case .none:
                    selection = .single(primary)
                case let .single(anchor):
                    selection = .range(anchor: anchor, target: primary)
                case let .range(anchor, _):
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
                if case let .note(id) = primary, let score {
                    playbackEngine.playPreview(
                        noteID: id, in: score,
                    )
                }
            }
        }

        /// Resolve a marquee drag's rect against the score's hit-test
        /// columns and reflect the result into `selection`. An empty
        /// rect (no events overlap) clears the selection — same
        /// behaviour as a tap on empty space.
        private func applyMarquee(
            rect: CGRect, document: LayoutDocument,
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

        private func loadBundled() {
            do {
                let loaded = try ScoreLoader.loadBundled()
                adoptLoadedScore(loaded, sourceName: "test.mscx")
            } catch {
                errorMessage = "Failed: \(exampleErrorDescription(error))"
            }
        }

        private func loadHarmonyBasic() {
            do {
                let loaded = try ScoreLoader.loadHarmonyBasic()
                adoptLoadedScore(
                    loaded, sourceName: "harmony-basic.mscx",
                )
            } catch {
                errorMessage = "Failed: \(exampleErrorDescription(error))"
            }
        }

        private func loadLyricsBasic() {
            do {
                let loaded = try ScoreLoader.loadLyricsBasic()
                adoptLoadedScore(
                    loaded, sourceName: "lyrics-basic.mscx",
                )
            } catch {
                errorMessage = "Failed: \(exampleErrorDescription(error))"
            }
        }

        /// User-triggered "Open…" via NSOpenPanel. Reads the file at
        /// `url` (any of the formats `ScoreFileType` recognises),
        /// adopts it as the active score.
        func openUserURL(_ url: URL) {
            do {
                let loaded = try ScoreLoader.load(from: url)
                adoptLoadedScore(
                    loaded, sourceName: url.lastPathComponent,
                )
            } catch {
                errorMessage =
                    "Could not load \(url.lastPathComponent): "
                        + exampleErrorDescription(error)
            }
        }

        /// Replace the active score with `loaded`, reset cached
        /// per-score view state, kick off background sampler prep.
        /// Mirrors iOS's `adoptLoadedScore` but also rebuilds the
        /// horizontal layout synchronously (macOS uses it in the
        /// horizontal-mode entry path).
        private func adoptLoadedScore(
            _ loaded: Score, sourceName name: String,
        ) {
            // Pre-build the horizontal layout synchronously. It
            // doesn't depend on the viewport (uses the score's
            // natural content width), so there's no reason to defer
            // it to a .task — and an if-let gated Group can fail
            // to trigger .task(id:) when it starts empty.
            // New score → drop the old cache; per-measure entries from
            // a previous score have no validity here.
            layoutCache = LayoutCache()
            lyricSession.end()
            textSession.end()
            horizontalDoc = nil
            horizontalScreenScore = nil
            rebuildHorizontalScreenLayout(for: loaded)
            horizontalContexts = LayoutEngine.measureContexts(
                for: laidOut(loaded),
            )
            // Vertical layout still needs the viewport width, so it's
            // built by a .task in the .vertical case.
            verticalDoc = nil
            pdfLayout = nil
            // Drop any prior imported-PDF state; importOriginalPDF re-sets
            // these (and the mode) right after calling this. Loading a
            // regular score while in .originalPDF mode falls back to a
            // layout mode that doesn't need a PDF.
            originalPDF = nil
            originalPDFGeometry = nil
            if layoutMode == .originalPDF { layoutMode = .horizontal }
            score = loaded
            if let inputController {
                inputController.reset(score: loaded)
            } else {
                let controller = NoteInputController(score: loaded)
                controller.onScoreEdited = handleControllerEdit
                inputController = controller
            }
            sourceName = name
            errorMessage = nil
            scoreVersion = UUID()
            selection = .none
            pendingHorizontalScroll = nil
            isRepeating = false
            playbackEngine.clearLoop()
            playbackEngine.prepareInBackground(score: loaded)
        }

        /// Wired into `NoteInputController.onScoreEdited`. Runs after
        /// every successful apply / undo / redo — including from inside
        /// the `UndoManager` closure (⌘Z), which executes outside
        /// SwiftUI's normal update cycle and so can't be picked up
        /// reliably by `.onChange(of:)`. Inline @State writes from this
        /// callback DO propagate, since `adoptEditedScore` mutates
        /// stored `@State` properties directly via the captured view
        /// struct's State backing storage.
        private func handleControllerEdit() {
            if let edited = inputController?.score {
                adoptEditedScore(edited)
            }
        }

        /// Adopt a score edited via `inputController`.
        ///
        /// Re-layout when a runtime `ScoreViewOptions` toggle
        /// (`collapseMultiMeasureRests` or `showsInvisibleElements`)
        /// changes without a score reload.
        /// The vertical doc rebuilds via its `.task(id:)` once `scoreVersion`
        /// advances; the horizontal doc must be rebuilt directly here,
        /// matching the logic in `adoptEditedScore`.
        private func rebuildLayoutsForOptionsChange() {
            guard let score else { return }
            // Drop the cache so the new policy (e.g. collapse toggle)
            // re-derives per-measure widths and placements from scratch.
            // Without this, cache hits return stale entries computed under
            // the previous policy.
            layoutCache = LayoutCache()
            rebuildHorizontalScreenLayout(for: score)
            scoreVersion = UUID()
        }

        /// Optimised vs `adoptLoadedScore` to keep keystrokes responsive
        /// on large scores (`test.mscx` is ~1356 measures):
        ///   * `horizontalContexts` is NOT recomputed — a single-note
        ///     edit can't change clef / key / time / part metadata.
        ///   * The horizontal layout's `availableWidth` reuses the
        ///     existing `horizontalDoc.contentWidth`. The width *might*
        ///     drift by a glyph's worth on note-vs-rest swaps, but the
        ///     layout engine renormalises within the system on its own
        ///     pass — saving the full-score `naturalContentWidth` walk.
        private func adoptEditedScore(_ edited: Score) {
            let t0 = Date()
            let layoutMs = rebuildHorizontalScreenLayout(for: edited)
            verticalDoc = nil
            pdfLayout = nil
            score = edited
            scoreVersion = UUID()
            reportEditTiming(startedAt: t0, layoutMs: layoutMs)
        }

        /// Rebuilds only the interactive horizontal document when pending
        /// text changes. This must stay separate from `laidOut(_:)`, which
        /// `scoreForPDFExport` also calls: preview text is screen-only and
        /// must never reach PDF or file export.
        private func rebuildHorizontalTextEntryPreview() {
            guard layoutMode == .horizontal,
                  let committed = inputController?.score,
                  textEntryPreviewIdentity != renderedTextEntryPreview
            else { return }
            let t0 = Date()
            let layoutMs = rebuildHorizontalScreenLayout(for: committed)
            reportEditTiming(startedAt: t0, layoutMs: layoutMs)
        }

        /// Applies the active session's pending command to a value copy and
        /// lays that copy out through the same cache used for committed edits.
        @discardableResult
        private func rebuildHorizontalScreenLayout(
            for committed: Score,
        ) -> Double {
            let preview = ScoreTextEntryPreview.compose(
                committed: committed,
                lyricSession: lyricSession,
                textSession: textSession,
            )
            let screenScore = laidOut(preview)
            let hOpts = horizontalOptions
            // Reuse the previously-laid-out total width. The cache rejects
            // the edited measure but retains every unchanged measure, which
            // keeps per-keystroke preview viable on large scores.
            let availableWidth = horizontalDoc?.size.width
                ?? LayoutEngine.naturalContentWidth(
                    score: screenScore, options: hOpts,
                )
            let tLayoutStart = Date()
            let document = LayoutEngine.layout(
                score: screenScore,
                options: hOpts,
                availableWidth: availableWidth,
                cache: layoutCache,
            )
            let layoutMs = Date().timeIntervalSince(tLayoutStart) * 1000
            horizontalScreenScore = screenScore
            horizontalDoc = document
            horizontalContentVersion = UUID()
            renderedTextEntryPreview = textEntryPreviewIdentity
            return layoutMs
        }

        /// Keep the existing edit timing probe for both committed edits and
        /// per-keystroke preview layouts.
        private func reportEditTiming(
            startedAt t0: Date,
            layoutMs: Double,
        ) {
            let stateDoneMs = Date().timeIntervalSince(t0) * 1000
            // Schedule probes at three milestones:
            //   - tick:  next runloop iteration (~SwiftUI commit done)
            //   - paint: after Core Animation flushes the next frame
            //            (closest proxy for "user sees it")
            DispatchQueue.main.async {
                let tickMs = Date().timeIntervalSince(t0) * 1000
                CATransaction.begin()
                CATransaction.setCompletionBlock {
                    let paintMs = Date().timeIntervalSince(t0) * 1000
                    print(String(
                        format: "edit: layout=%.1f state=%.1f tick=%.1f paint=%.1f ms (total %.1fms)",
                        layoutMs,
                        stateDoneMs - layoutMs,
                        tickMs - stateDoneMs,
                        paintMs - tickMs,
                        paintMs,
                    ))
                }
                CATransaction.commit()
            }
        }
    }
#endif
