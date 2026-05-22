#if os(macOS)
    import AppKit
    import SheetMusic
    import SheetMusicAudio
    import SwiftUI

    /// macOS sidebar: file picker, playback transport, mixer, layout
    /// mode picker, paged-mode page nav, zoom reset, and a status panel
    /// for the loaded score / last error. Lives outside `ContentViewMac`
    /// so the host body is just a `NavigationSplitView` skeleton.
    @available(macOS 15.0, *)
    struct ContentSidebar: View {
        let playbackEngine: PlaybackEngine
        let sourceName: String
        let score: Score?
        let errorMessage: String?
        @Binding var layoutMode: MacLayoutMode
        @Binding var pageIndex: Int
        let totalPages: Int
        @Binding var magnification: CGFloat
        @Binding var isMarqueeMode: Bool
        @Binding var collapseMultiMeasureRests: Bool

        let onLoadBundled: () -> Void
        let onLoadHarmonyBasic: () -> Void
        let onOpenFile: () -> Void
        let onTogglePlayback: () -> Void
        let onExportPDF: () -> Void
        let onExportMSCX: () -> Void
        let onExportMSCXv3: () -> Void
        let onExportMSCZv3: () -> Void
        let onExportMIDI: () -> Void
        let onExportAudio: () -> Void

        var body: some View {
            List {
                Section("Bundled") {
                    Button("Load test.mscx", action: onLoadBundled)
                    Button(
                        "Load harmony-basic.mscx",
                        action: onLoadHarmonyBasic,
                    )
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
                            Image(
                                systemName: playbackEngine.state == .playing
                                    ? "pause.fill" : "play.fill",
                            )
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
                    Button("Save as MSCX (MS4)…", action: onExportMSCX)
                        .disabled(score == nil)
                    Button("Save as MSCX (MS3)…", action: onExportMSCXv3)
                        .disabled(score == nil)
                    Button("Save as MSCZ (MS3)…", action: onExportMSCZv3)
                        .disabled(score == nil)
                    Button("Save as MIDI…", action: onExportMIDI)
                        .disabled(score == nil)
                    Button("Export Audio…", action: onExportAudio)
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
                    .disabled(
                        score == nil
                            || (
                                layoutMode != .vertical
                                    && layoutMode != .horizontal
                            ),
                    )
                }
                Section("Display") {
                    Toggle(isOn: $collapseMultiMeasureRests) {
                        Label(
                            "Collapse rest measures",
                            systemImage: "rectangle.compress.vertical",
                        )
                    }
                    .disabled(score == nil)
                    Text(
                        "Folds runs of ≥2 consecutive whole rests into a single H-bar with a count.",
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(message, forType: .string)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        }

        private var playbackStateLabel: String {
            switch playbackEngine.state {
            case .stopped: "stopped"
            case .playing: "playing"
            case .paused: "paused"
            case .exporting: "exporting"
            }
        }
    }
#endif
