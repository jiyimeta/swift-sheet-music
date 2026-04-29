#if os(macOS)
import SheetMusic
import SheetMusicAudio
import SwiftUI

/// macOS sidebar: file picker, playback transport, mixer, layout
/// mode picker, paged-mode page nav, zoom reset, and a status panel
/// for the loaded score / last error. Lives outside `ContentViewMac`
/// so the host body is just a `NavigationSplitView` skeleton.
@available(macOS 15.0, *)
struct ContentSidebar: View {
    @ObservedObject var playbackEngine: PlaybackEngine
    let sourceName: String
    let score: Score?
    let errorMessage: String?
    @Binding var layoutMode: MacLayoutMode
    @Binding var pageIndex: Int
    let totalPages: Int
    @Binding var magnification: CGFloat
    @Binding var isMarqueeMode: Bool

    let onLoadBundled: () -> Void
    let onOpenFile: () -> Void
    let onTogglePlayback: () -> Void
    let onExportPDF: () -> Void

    var body: some View {
        List {
            Section("Bundled") {
                Button("Load test.mscx", action: onLoadBundled)
            }
            Section("Open") {
                Button("Open File…", action: onOpenFile)
                Text(sourceName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Section("Playback") {
                HStack {
                    Button(action: onTogglePlayback) {
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
                Button("Save as PDF…", action: onExportPDF)
                    .disabled(score == nil)
            }
            if !playbackEngine.mixerChannels.isEmpty {
                Section("Mixer") {
                    MixerView(engine: playbackEngine)
                }
            }
            Section("Layout") {
                Picker("Mode", selection: $layoutMode) {
                    Label("Horizontal", systemImage: "arrow.left.and.right")
                        .tag(MacLayoutMode.horizontal)
                    Label("Vertical", systemImage: "arrow.up.and.down")
                        .tag(MacLayoutMode.vertical)
                    Label("Page", systemImage: "book.pages")
                        .tag(MacLayoutMode.paged)
                    Label("PDF", systemImage: "doc.text")
                        .tag(MacLayoutMode.pdf)
                }
                .pickerStyle(.inline)
            }
            Section("Selection") {
                Toggle(isOn: $isMarqueeMode) {
                    Label("Marquee Drag", systemImage: "rectangle.dashed")
                }
                .disabled(score == nil
                    || (layoutMode != .vertical
                        && layoutMode != .horizontal))
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
    }

    private var playbackStateLabel: String {
        switch playbackEngine.state {
        case .stopped: return "stopped"
        case .playing: return "playing"
        case .paused: return "paused"
        }
    }
}
#endif
