#if os(macOS)
    import AppKit
    import CryptoKit
    import Observation
    import SheetMusic
    import SheetMusicAudio
    import SwiftUI
    import UniformTypeIdentifiers

    /// One recording strip of the panel: the host's description of a track plus the mix the user is setting.
    struct AudioTrackStrip: Identifiable, Equatable {
        let id: String
        let name: String
        let pcmFile: URL
        /// Length of the decoded file, for the unaligned (identity) segment.
        let durationSeconds: Double
        var volume: Float = 1
        var isMuted = false
        var isSoloed = false
        var transposeSemitones = 0
        var offsetSeconds: Double = 0
    }

    /// State and engine wiring behind `AudioTrackPanel`. Held by `ContentViewMac` so the strips and the grid survive
    /// the inspector being closed.
    ///
    /// The grid-to-alignment mapping lives here, not in the package: a steady grid (BPM and the recording time of the
    /// first measure's start) gives every click beat of `PlayedMeasures.make(score:)` a duration on the warped clock,
    /// one `PlaybackTimeWarp.Span` per beat and a single `RecordingSegment` for the whole continuous run.
    @MainActor
    @Observable
    final class AudioTrackModel {
        var strips: [AudioTrackStrip] = []
        var isPreparing = false
        var message: String?

        /// Grid
        var usesGrid = true
        /// Whether the engine currently follows the grid (false: recordings play unaligned from 0:00).
        private(set) var isAligned = false
        var bpm: Double = 120
        /// Recording seconds of the first FULL measure's downbeat. A pickup before it is end-anchored: it ends there.
        var firstDownbeatSeconds: Double = 0
        /// Playback-order position (1-based; position 0 has nothing before it to lengthen) of the measure nudged.
        var nudgeIndex = 1
        /// Seconds each played measure's downbeat is moved from the steady grid, by playback-order position.
        var nudgesSeconds: [Int: Double] = [:]
        private(set) var playedMeasures: [PlayedMeasure] = []

        // Export
        var includesCountIn = true
        var exportProgress: Double?

        @ObservationIgnored private weak var engine: PlaybackEngine?
        @ObservationIgnored private var score: Score?
        /// Click beats in a full first measure: the numerator of the time signature active there (the click step is
        /// the denominator's unit, as in `PlaybackTimeline.metronomeGrid`).
        @ObservationIgnored private var nominalFirstMeasureBeats = 4.0
        @ObservationIgnored private var pushed: [String: AudioTrackStrip] = [:]

        static let nudgeLimit = 0.3
        /// The SwiftySynth backend's default rate; the PCM caches are decoded at it.
        private static let sampleRate = 44100.0

        func attach(_ engine: PlaybackEngine) {
            self.engine = engine
        }

        func scoreChanged(_ score: Score?) {
            self.score = score
            nominalFirstMeasureBeats = score.map(Self.nominalBeatsOfFirstMeasure) ?? 4
            playedMeasures = score.map { PlayedMeasures.make(score: $0) } ?? []
            nudgesSeconds = nudgesSeconds.filter { $0.key < playedMeasures.count }
            nudgeIndex = min(max(1, nudgeIndex), max(1, playedMeasures.count - 1))
            applyAlignment()
        }

        // MARK: Tracks

        func addAudio(_ urls: [URL]) {
            guard !urls.isEmpty else { return }
            isPreparing = true
            message = nil
            Task {
                defer { isPreparing = false }
                for url in urls {
                    do {
                        let key = Self.cacheKey(for: url)
                        let pcm = try await RecordingPCMCache.prepare(
                            source: url, cacheKey: key, sampleRate: Self.sampleRate, directory: Self.cacheDirectory,
                        )
                        let id = "\(key)-\(UUID().uuidString.prefix(6))"
                        let duration = try MappedRecording(pcmFile: pcm).durationSeconds
                        strips.append(AudioTrackStrip(
                            id: id, name: url.lastPathComponent, pcmFile: pcm, durationSeconds: duration,
                        ))
                    } catch {
                        message = "Could not add \(url.lastPathComponent): \(error)"
                    }
                }
                pushTracks()
                applyAlignment()
            }
        }

        func remove(_ id: String) {
            strips.removeAll { $0.id == id }
            pushTracks()
            applyAlignment()
        }

        /// Called when a strip's binding changed. A mix change is a mixer call; a transposition or offset change hands
        /// the track list over again (a track whose id was already playing carries on from where it is).
        func stripChanged(_ strip: AudioTrackStrip) {
            guard let old = pushed[strip.id] else { return }
            if old.transposeSemitones != strip.transposeSemitones || old.offsetSeconds != strip.offsetSeconds {
                pushTracks()
            } else if old != strip {
                engine?.setRecordingMix(
                    id: strip.id, volume: strip.volume, isMuted: strip.isMuted, isSoloed: strip.isSoloed,
                )
                pushed[strip.id] = strip
            }
        }

        private func pushTracks() {
            guard let engine else { return }
            let tracks = strips.map {
                RecordingTrack(
                    id: $0.id, pcmFile: $0.pcmFile, offsetSeconds: $0.offsetSeconds,
                    transposeSemitones: $0.transposeSemitones, volume: $0.volume, isMuted: $0.isMuted,
                    isSoloed: $0.isSoloed,
                )
            }
            do {
                try engine.setRecordingTracks(tracks)
                pushed = Dictionary(uniqueKeysWithValues: strips.map { ($0.id, $0) })
            } catch {
                message = "Could not load the tracks: \(error)"
            }
        }

        // MARK: Grid -> alignment

        /// A first measure shorter than its time signature is a pickup, whole-beat or fractional; one equal to it is
        /// not, even when that is a fractional number of click beats.
        nonisolated static func isPickup(lengthInBeats: Double, nominalBeats: Double) -> Bool {
            lengthInBeats < nominalBeats - 1e-6
        }

        /// The time signature's numerator at measure 0, found as the metronome grid does: the first time signature
        /// ahead of the first chord in measure 0 of any staff, else 4/4.
        nonisolated static func nominalBeatsOfFirstMeasure(of score: Score) -> Double {
            for entry in score.allStaves {
                guard let measure = entry.staff.measures.first else { continue }
                for element in measure.voices.first?.elements ?? [] {
                    switch element {
                    case let .timeSignature(signature): return Double(signature.numerator)
                    case .chord: break
                    default: continue
                    }
                    break
                }
            }
            return 4
        }

        /// Hands the engine the warp and the segment the grid describes. With the grid off (or an invalid BPM, or no
        /// score) there is no warp and one identity segment, so the recordings play from their start at the notated
        /// tempo instead of going silent. Callable while playing (a table swap on the backend).
        func applyAlignment() {
            guard let engine else { return }
            guard !strips.isEmpty else {
                isAligned = false
                engine.setAlignment(warp: nil, segments: [])
                return
            }
            if usesGrid, bpm > 0, let result = Self.alignment(
                for: playedMeasures, nominalFirstMeasureBeats: nominalFirstMeasureBeats, bpm: bpm,
                firstDownbeat: firstDownbeatSeconds, nudges: nudgesSeconds,
            ) {
                isAligned = true
                engine.setAlignment(warp: result.warp, segments: result.segments)
            } else {
                isAligned = false
                let longest = strips.map(\.durationSeconds).max() ?? 0
                engine.setAlignment(
                    warp: nil, segments: [RecordingSegment(sourceStart: 0, sourceEnd: longest, outputStart: 0)],
                )
            }
        }

        /// Pure mapping, so it reads top to bottom: one span per click beat lasting that beat's duration on the
        /// grid. A beat's duration is the grid beat scaled by how much of a full click step the span covers, which
        /// makes a pickup end-anchored (it plays the last part of its first beat) without a special case. A nudge
        /// moves a measure's downbeat: the previous measure's last beat gets longer and this one's first shorter.
        nonisolated static func alignment(
            for measures: [PlayedMeasure], nominalFirstMeasureBeats: Double, bpm: Double, firstDownbeat: Double,
            nudges: [Int: Double],
        ) -> (warp: PlaybackTimeWarp, segments: [RecordingSegment])? {
            let beatSeconds = 60 / bpm
            var raw: [(start: Double, end: Double)] = []
            var durations: [Double] = []
            var firstSpan: [Int: Int] = [:]
            var lastSpan: [Int: Int] = [:]
            for (position, measure) in measures.enumerated() {
                let length = measure.endSeconds - measure.startSeconds
                guard measure.lengthInBeats > 0, length > 0 else { continue }
                let step = length / measure.lengthInBeats
                let starts = measure.beatSeconds.isEmpty ? [measure.startSeconds] : measure.beatSeconds
                for (i, beatStart) in starts.enumerated() {
                    let start = i == 0 ? measure.startSeconds : beatStart
                    let end = i + 1 < starts.count ? starts[i + 1] : measure.endSeconds
                    guard end > start else { continue }
                    if firstSpan[position] == nil { firstSpan[position] = raw.count }
                    lastSpan[position] = raw.count
                    raw.append((start, end))
                    durations.append(beatSeconds * (end - start) / step)
                }
            }
            guard !raw.isEmpty else { return nil }

            // A pickup (a first measure shorter than its time signature) is end-anchored: it ends at the first full
            // measure's downbeat, so the recording starts that much earlier. Measured before any nudge, so a nudge
            // moves the downbeat rather than the anchor.
            var pickupSeconds = 0.0
            if measures.count > 1, let first = firstSpan[0], let last = lastSpan[0],
               isPickup(lengthInBeats: measures[0].lengthInBeats, nominalBeats: nominalFirstMeasureBeats)
            {
                pickupSeconds = durations[first ... last].reduce(0, +)
            }

            let minimum = 0.05
            for position in nudges.keys.sorted() where position >= 1 {
                guard let previous = lastSpan[position - 1], let first = firstSpan[position] else { continue }
                var delta = nudges[position] ?? 0
                delta = min(delta, durations[first] - minimum)
                delta = max(delta, minimum - durations[previous])
                durations[previous] += delta
                durations[first] -= delta
            }

            let spans = raw.indices.map {
                PlaybackTimeWarp.Span(start: raw[$0].start, end: raw[$0].end, duration: durations[$0])
            }
            guard let warp = try? PlaybackTimeWarp(spans: spans) else { return nil }
            // The recording cannot start before 0:00: shift the output start by what would go negative.
            let rawStart = firstDownbeat - pickupSeconds
            let sourceStart = max(0, rawStart)
            let outputStart = max(0, -rawStart)
            let segment = RecordingSegment(
                sourceStart: sourceStart, sourceEnd: sourceStart + durations.reduce(0, +) - outputStart,
                outputStart: outputStart,
            )
            return (warp, [segment])
        }

        // MARK: Export

        func export() {
            guard let engine, let score, exportProgress == nil else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Audio]
            panel.nameFieldStringValue = "score-with-tracks.m4a"
            panel.title = "Export Audio"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            exportProgress = 0
            message = nil
            let countIn = includesCountIn
            Task {
                defer { exportProgress = nil }
                do {
                    // The export reads the score the engine prepared.
                    if engine.state == .stopped { try engine.prepare(score: score) }
                    try await engine.exportAudioFile(
                        to: url, score: score, format: .m4a(), includesCountIn: countIn,
                        progress: { fraction in Task { @MainActor in self.exportProgress = fraction } },
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    message = "Export failed: \(error)"
                }
            }
        }

        // MARK: Helpers

        private static var cacheDirectory: URL {
            (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory).appendingPathComponent("AudioTracks", isDirectory: true)
        }

        /// File name plus a digest of the absolute path, size and modification date, so two different files that share
        /// a name and size (or a file edited in place) never share a cache file.
        private static func cacheKey(for url: URL) -> String {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let identity = "\(url.standardizedFileURL.path)|\(size)|\(modified)"
            let digest = SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            let name = url.deletingPathExtension().lastPathComponent
            let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            return "\(String(safe))-\(digest)"
        }
    }

    /// The audio-track inspector: recordings mixed with the score, a steady grid that aligns the score to them, and an
    /// export. Tempo and transposition are the sidebar's Speed and Transpose, which drive the recordings too.
    @available(macOS 15.0, *)
    struct AudioTrackPanel: View {
        @Bindable var model: AudioTrackModel
        let hasScore: Bool
        /// Exporting while playing or paused tears down live playback, so Export is offered only when stopped.
        let isStopped: Bool

        var body: some View {
            Form {
                tracksSection
                gridSection
                exportSection
                if let message = model.message {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityLabel("Audio track message")
                    }
                }
            }
            .formStyle(.grouped)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audio tracks")
        }

        private var tracksSection: some View {
            Section("Tracks") {
                HStack {
                    Button("Add Audio…", action: showAddPanel)
                        .accessibilityLabel("Add Audio")
                    if model.isPreparing {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Decoding audio")
                    }
                }
                ForEach($model.strips) { $strip in
                    AudioTrackStripView(strip: $strip) { model.remove(strip.id) }
                        .onChange(of: strip) { _, new in model.stripChanged(new) }
                }
                Text("Tempo and Transpose follow the sidebar's Speed and Transpose controls.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        private var gridSection: some View {
            Section("Grid") {
                Toggle("Align score to grid", isOn: $model.usesGrid)
                    .accessibilityLabel("Align score to grid")
                    .onChange(of: model.usesGrid) { _, _ in model.applyAlignment() }
                if !model.strips.isEmpty, !model.isAligned {
                    Text("Not aligned — recordings play from 0:00")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Not aligned, recordings play from zero")
                }
                HStack {
                    Text("BPM")
                    Spacer()
                    TextField("BPM", value: $model.bpm, format: .number.precision(.fractionLength(0 ... 2)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .accessibilityLabel("Grid BPM")
                        .onSubmit { model.applyAlignment() }
                }
                HStack {
                    Text("First full-measure downbeat (s)")
                    Spacer()
                    TextField(
                        "First downbeat", value: $model.firstDownbeatSeconds,
                        format: .number.precision(.fractionLength(0 ... 3)),
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .accessibilityLabel("First full measure downbeat seconds")
                    .onSubmit { model.applyAlignment() }
                }
                if model.playedMeasures.count > 1 {
                    nudgeControls
                }
                Button("Apply") { model.applyAlignment() }
                    .accessibilityLabel("Apply grid")
            }
            .disabled(!hasScore)
        }

        private var nudgeControls: some View {
            VStack(alignment: .leading, spacing: 4) {
                Stepper(
                    "Measure \(nudgeTitle) starts at",
                    value: $model.nudgeIndex, in: 1 ... max(1, model.playedMeasures.count - 1),
                )
                .accessibilityLabel("Measure to nudge")
                .accessibilityValue(nudgeTitle)
                HStack {
                    Slider(value: nudgeBinding, in: -AudioTrackModel.nudgeLimit ... AudioTrackModel.nudgeLimit)
                        .accessibilityLabel("Measure start nudge")
                        .accessibilityValue("\(Int((nudgeBinding.wrappedValue * 1000).rounded())) milliseconds")
                    Text("\(Int((nudgeBinding.wrappedValue * 1000).rounded())) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                    Button("0") { nudgeBinding.wrappedValue = 0 }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Reset nudge")
                }
            }
        }

        /// "N" for the notated measure the nudge sits on, with the repeat pass when there is more than one.
        private var nudgeTitle: String {
            guard model.playedMeasures.indices.contains(model.nudgeIndex) else { return "-" }
            let measure = model.playedMeasures[model.nudgeIndex]
            let number = measure.measureIndex + 1
            return measure.pass > 1 ? "\(number) (pass \(measure.pass))" : "\(number)"
        }

        private var nudgeBinding: Binding<Double> {
            Binding(
                get: { model.nudgesSeconds[model.nudgeIndex] ?? 0 },
                set: { newValue in
                    model.nudgesSeconds[model.nudgeIndex] = newValue == 0 ? nil : newValue
                    model.applyAlignment()
                },
            )
        }

        private var exportSection: some View {
            Section("Export") {
                Toggle("Include count-in", isOn: $model.includesCountIn)
                    .accessibilityLabel("Include count-in")
                HStack {
                    Button("Export…") { model.export() }
                        .disabled(!hasScore || !isStopped || model.exportProgress != nil)
                        .accessibilityLabel("Export audio")
                    if let progress = model.exportProgress {
                        ProgressView(value: progress)
                            .accessibilityLabel("Export progress")
                    }
                }
            }
        }

        private func showAddPanel() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.audio]
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.title = "Add Audio"
            guard panel.runModal() == .OK else { return }
            model.addAudio(panel.urls)
        }
    }

    /// One recording's strip: volume, mute, solo, transpose, offset.
    @available(macOS 15.0, *)
    private struct AudioTrackStripView: View {
        @Binding var strip: AudioTrackStrip
        let onRemove: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(strip.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(strip.name)")
                }
                HStack {
                    Slider(value: $strip.volume, in: 0 ... 1)
                        .accessibilityLabel("\(strip.name) volume")
                    Toggle("M", isOn: $strip.isMuted)
                        .toggleStyle(.button)
                        .accessibilityLabel("Mute \(strip.name)")
                    Toggle("S", isOn: $strip.isSoloed)
                        .toggleStyle(.button)
                        .accessibilityLabel("Solo \(strip.name)")
                }
                Stepper(
                    "Transpose: \(strip.transposeSemitones > 0 ? "+" : "")\(strip.transposeSemitones)",
                    value: $strip.transposeSemitones, in: -12 ... 12,
                )
                .accessibilityLabel("\(strip.name) transpose")
                .accessibilityValue("\(strip.transposeSemitones) semitones")
                HStack {
                    Text("Offset (s)")
                    Spacer()
                    TextField(
                        "Offset", value: $strip.offsetSeconds, format: .number.precision(.fractionLength(0 ... 3)),
                    )
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .accessibilityLabel("\(strip.name) offset seconds")
                }
            }
            .padding(.vertical, 2)
        }
    }
#endif
