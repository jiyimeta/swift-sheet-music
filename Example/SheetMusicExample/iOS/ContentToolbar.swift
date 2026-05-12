#if !os(macOS)
    import SheetMusic
    import SheetMusicAudio
    import SwiftUI

    /// iOS toolbar: leading playback transport, trailing layout-mode
    /// picker, and an explicit overflow menu (mixer / export / open /
    /// marquee / zoom).
    ///
    /// We do NOT rely on `ToolbarItemGroup`'s auto-overflow (the
    /// system-managed `…` indicator). On iPhone-width toolbars iOS 18
    /// SwiftUI quietly drops tap routing for the auto-overflow button
    /// when its candidate items mix `.disabled()` states; the indicator
    /// appears but tapping it does nothing. Authoring an explicit
    /// `Menu` sidesteps that path entirely.
    @available(iOS 16.0, *)
    struct ContentToolbar: ToolbarContent {
        @ObservedObject var playbackEngine: PlaybackEngine
        let score: Score?
        @Binding var layoutMode: IOSLayoutMode
        @Binding var staffSize: CGFloat
        @Binding var isMixerPresented: Bool
        @Binding var isImportingFile: Bool
        @Binding var isMarqueeMode: Bool
        @Binding var isExportAudioPresented: Bool

        let onTogglePlayback: () -> Void
        let onExportPDF: () -> Void

        var body: some ToolbarContent {
            // Leading — playback controls. Two buttons fit
            // unconditionally even on the narrowest iPhone, so
            // they never get pushed into auto-overflow.
            ToolbarItemGroup(placement: .topBarLeading) {
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
            }

            ToolbarItem(placement: .topBarTrailing) {
                Picker("Layout", selection: $layoutMode) {
                    Image(systemName: "arrow.up.and.down")
                        .tag(IOSLayoutMode.vertical)
                    Image(systemName: "arrow.left.and.right")
                        .tag(IOSLayoutMode.horizontal)
                    Image(systemName: "book.pages")
                        .tag(IOSLayoutMode.paged)
                    Image(systemName: "doc.text")
                        .tag(IOSLayoutMode.pdf)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Section("Source: \(score?.source.displayName ?? "No Score")") {
                        EmptyView()
                    }

                    Button {
                        isMixerPresented = true
                    } label: {
                        Label("Mixer", systemImage: "slider.horizontal.3")
                    }
                    .disabled(playbackEngine.mixerChannels.isEmpty)

                    Button(action: onExportPDF) {
                        Label(
                            "Export PDF",
                            systemImage: "square.and.arrow.up",
                        )
                    }
                    .disabled(score == nil)

                    Button {
                        isExportAudioPresented = true
                    } label: {
                        Label("Export Audio", systemImage: "waveform")
                    }
                    .disabled(score == nil)

                    Button {
                        isImportingFile = true
                    } label: {
                        Label("Open File", systemImage: "folder")
                    }

                    Toggle(isOn: $isMarqueeMode) {
                        Label(
                            "Marquee Select",
                            systemImage: "rectangle.dashed",
                        )
                    }
                    .disabled(
                        score == nil
                            || (
                                layoutMode != .vertical
                                    && layoutMode != .horizontal
                            ),
                    )

                    Divider()

                    Button {
                        staffSize = max(8, staffSize - 2)
                    } label: {
                        Label(
                            "Zoom Out",
                            systemImage: "minus.magnifyingglass",
                        )
                    }
                    .disabled(staffSize <= 8)

                    Button {
                        staffSize = min(32, staffSize + 2)
                    } label: {
                        Label(
                            "Zoom In",
                            systemImage: "plus.magnifyingglass",
                        )
                    }
                    .disabled(staffSize >= 32)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
#endif
