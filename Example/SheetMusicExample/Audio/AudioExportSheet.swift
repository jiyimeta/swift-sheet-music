import SheetMusicAudio
import SheetMusicCore
import SwiftUI

#if canImport(UniformTypeIdentifiers)
    import UniformTypeIdentifiers
#endif

enum FormatTag: String, CaseIterable, Identifiable {
    case wav, aiff, m4a, mp3
    var id: Self {
        self
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct AudioExportSheet: View {
    let engine: PlaybackEngine
    let score: Score
    @Environment(\.dismiss) private var dismiss

    @State private var tag: FormatTag = .wav
    @State private var pcm = PCMOptions()
    @State private var comp = CompressedOptions()
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Error>?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Format") {
                Picker("Container", selection: $tag) {
                    ForEach(FormatTag.allCases) {
                        Text($0.rawValue.uppercased()).tag($0)
                    }
                }
            }
            if isPCM {
                Section("PCM options") {
                    Stepper(
                        "Sample rate: \(Int(pcm.sampleRate)) Hz",
                        value: $pcm.sampleRate,
                        in: 8000 ... 192_000,
                        step: 100,
                    )
                    Picker("Bit depth", selection: $pcm.bitDepth) {
                        Text("16-bit int").tag(PCMBitDepth.int16)
                        Text("24-bit int").tag(PCMBitDepth.int24)
                        Text("32-bit int").tag(PCMBitDepth.int32)
                        Text("32-bit float").tag(PCMBitDepth.float32)
                    }
                    Picker("Channels", selection: $pcm.channels) {
                        Text("Mono").tag(AudioChannelCount.mono)
                        Text("Stereo").tag(AudioChannelCount.stereo)
                    }
                }
            } else {
                Section("Compressed options") {
                    Stepper(
                        "Sample rate: \(Int(comp.sampleRate)) Hz",
                        value: $comp.sampleRate,
                        in: 8000 ... 96000,
                        step: 100,
                    )
                    Stepper(
                        "Bit rate: \(comp.bitRate / 1000) kbps",
                        value: $comp.bitRate,
                        in: 64000 ... 320_000,
                        step: 16000,
                    )
                    Picker("Channels", selection: $comp.channels) {
                        Text("Mono").tag(AudioChannelCount.mono)
                        Text("Stereo").tag(AudioChannelCount.stereo)
                    }
                }
            }
            if exportTask != nil {
                Section {
                    ProgressView(value: progress)
                    Button("Cancel", role: .cancel) { exportTask?.cancel() }
                }
            } else {
                Section {
                    Button("Export…") { Task { await startExport() } }
                }
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Export audio")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private var isPCM: Bool {
        tag == .wav || tag == .aiff
    }

    private var resolvedFormat: AudioFileFormat {
        switch tag {
        case .wav: return .wav(pcm)
        case .aiff: return .aiff(pcm)
        case .m4a: return .m4a(comp)
        case .mp3: return .mp3(comp)
        }
    }

    private func startExport() async {
        let suggested = "score.\(tag.rawValue)"
        guard let url = await pickSaveURL(suggestedName: suggested) else {
            return
        }
        errorText = nil
        progress = 0
        exportTask = Task { @MainActor in
            do {
                try await engine.exportAudioFile(
                    to: url, score: score,
                    format: resolvedFormat,
                    progress: { p in progress = p },
                )
                exportTask = nil
                dismiss()
            } catch {
                exportTask = nil
                if !(error is CancellationError) {
                    errorText = String(describing: error)
                }
            }
        }
    }

    /// Platform-specific save dialog. iOS uses the temporary
    /// directory for the example app; macOS shows an NSSavePanel.
    @MainActor
    private func pickSaveURL(suggestedName: String) async -> URL? {
        #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedName
            return panel.runModal() == .OK ? panel.url : nil
        #else
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(suggestedName)
        #endif
    }
}
