#if !os(macOS)
import SheetMusic
import SheetMusicAudio
import SheetMusicUI
import SwiftUI

private enum LayoutMode: Int {
    case vertical, horizontal, paged
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
    @State private var scoreVersion = UUID()
    /// Audio engine for single-note preview + full-score playback.
    /// Stays silent until the user drops a SoundFont into `Sounds/`
    /// (see `BundledSoundfontResolver`). Held as a `@StateObject` so
    /// SwiftUI re-renders the play/pause button label and the
    /// playback cursor whenever the engine's `@Published` `state` /
    /// `currentCursor` changes.
    @StateObject private var playbackEngine = PlaybackEngine(
        soundfontResolver: BundledSoundfontResolver())

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
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
            }
        }
        .onAppear(perform: loadBundled)
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
            wrapToViewWidth: layoutMode != .horizontal)
        switch layoutMode {
        case .vertical:
            GeometryReader { geo in
                let width = geo.size.width - 16
                ScrollView(.vertical) {
                    if let doc = verticalDoc {
                        ScoreView(
                            document: doc, score: score,
                            selection: selection,
                            voiceColors: voiceColors,
                            playbackCursor: playbackEngine.currentCursor)
                            .onTapGesture { loc in
                                handleTap(at: loc, document: doc)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 16)
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
                ScrollView(.horizontal) {
                    ScoreView(
                        score: score, options: opts,
                        playbackCursor: playbackEngine.currentCursor)
                        .frame(minHeight: geo.size.height)
                        .padding(16)
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
        }
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
#endif
