import Foundation
import SheetMusicAudioCore
@_spi(PlaybackProbe) import SheetMusicAudioWindows

extension Probe {
    /// The audio export with the real SoundFont (folino spec 2026-10-05-windows-phase4-import-export-pdf-design §8.2).
    /// The probe's engine plays to the device, so every export here renders through the offline twin and leaves the
    /// engine alone.
    func export() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("windows-playback-probe-export")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        engine.stop()
        let mix = exportMix(into: folder)
        exportVariants(of: mix.file, into: folder)
        exportAAC(lasting: mix.seconds, into: folder)
        report.note("export", "files in \(folder.path)")
    }

    private static let wav = AudioFileFormat.wav(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo))

    /// The mix: not silent, the live engine left as it was, and the same bytes twice.
    private func exportMix(into folder: URL) -> (file: (bytes: Data, rms: Double), seconds: Double) {
        let wav = Self.wav
        let mixerBefore = engine.mixerChannels
        let started = clock.now
        let mix = render(folder.appendingPathComponent("mix.wav"), wav)
        let elapsed = seconds(clock.now - started)
        // The file's own length — the unrolled score, which repeats make longer than the notated one.
        let mixSeconds = Double(max(0, mix.bytes.count - 44)) / 4 / 44100
        report.note("export", "mix: \(formatted(elapsed, 1)) s to render \(formatted(mixSeconds, 1)) s of audio")
        report.check(
            "export", "the mix is not silent", mix.rms > 0.001, value: formatted(mix.rms, 4), limit: "> 0.001",
        )
        report.check(
            "export", "the live mixer is untouched", engine.mixerChannels == mixerBefore,
            value: "\(engine.mixerChannels == mixerBefore)", limit: "true",
        )
        report.check(
            "export", "the live engine stays stopped", engine.state == .stopped, value: "\(engine.state)",
            limit: "stopped",
        )

        let again = render(folder.appendingPathComponent("mix-again.wav"), wav)
        report.check(
            "export", "two exports are byte-identical", again.bytes == mix.bytes,
            value: "\(again.bytes == mix.bytes)", limit: "true",
        )
        return (mix, mixSeconds)
    }

    /// A soloed strip and a flipped click, each against the mix.
    private func exportVariants(of mix: (bytes: Data, rms: Double), into folder: URL) {
        let wav = Self.wav
        let strips = engine.mixerChannels.filter { $0.id != .metronome }
        if strips.count > 1, let first = strips.first {
            engine.setSoloed(forChannel: first.id, to: true)
            let solo = render(folder.appendingPathComponent("solo.wav"), wav)
            engine.setSoloed(forChannel: first.id, to: false)
            report.check(
                "export", "a soloed strip is quieter than the mix", solo.rms < mix.rms,
                value: "\(formatted(solo.rms, 4)) < \(formatted(mix.rms, 4))", limit: "solo < mix",
            )
        } else {
            report.note("export", "one strip only: no solo check")
        }

        let clickWasMuted = engine.mixerChannels.first { $0.id == .metronome }?.isMuted ?? true
        engine.setMuted(forChannel: .metronome, to: !clickWasMuted)
        let flipped = render(folder.appendingPathComponent("click.wav"), wav)
        engine.setMuted(forChannel: .metronome, to: clickWasMuted)
        report.check(
            "export", "the click's mute changes the file", flipped.bytes != mix.bytes,
            value: "\(flipped.bytes != mix.bytes)", limit: "true",
        )
    }

    /// The AAC file, sized against the WAV mix's own length.
    private func exportAAC(lasting mixSeconds: Double, into folder: URL) {
        let m4a = AudioFileFormat.m4a(CompressedOptions(sampleRate: 44100, bitRate: 128_000, channels: .stereo))
        let canWriteAAC = WindowsPlaybackEngine.canExport(m4a)
        report.check("export", "AAC available", canWriteAAC, value: "\(canWriteAAC)", limit: "true")
        if canWriteAAC {
            let aac = render(folder.appendingPathComponent("mix.m4a"), m4a)
            // 128 kbit/s is 16 000 bytes a second; the container and the encoder's priming add a little.
            let expected = mixSeconds * 16000
            let size = Double(aac.bytes.count)
            report.check(
                "export", "the M4A is about 128 kbit/s", size > expected * 0.8 && size < expected * 1.3,
                value: "\(aac.bytes.count) bytes", limit: "\(Int(expected * 0.8))…\(Int(expected * 1.3))",
            )
        }
    }

    /// Exports through the live engine (so through its twin) and reads the file back: its bytes, and for a 16-bit WAV
    /// its RMS.
    private func render(_ url: URL, _ format: AudioFileFormat) -> (bytes: Data, rms: Double) {
        let done = DispatchSemaphore(value: 0)
        let failure = FailureBox()
        let engine = engine
        let score = score
        Task.detached {
            do {
                try await engine.exportAudioFile(to: url, score: score, format: format)
            } catch {
                failure.set("\(error)")
            }
            done.signal()
        }
        done.wait()
        if let message = failure.value {
            report.check("export", "\(url.lastPathComponent) written", false, value: message, limit: "no error")
            return (Data(), 0)
        }
        let bytes = (try? Data(contentsOf: url)) ?? Data()
        guard case .wav = format, bytes.count > 44 else { return (bytes, 0) }
        var sum = 0.0
        var count = 0
        bytes[44...].withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                let value = Double(sample) / 32768
                sum += value * value
                count += 1
            }
        }
        return (bytes, count > 0 ? (sum / Double(count)).squareRoot() : 0)
    }
}

/// An export's failure, written on its task and read by the probe's thread.
private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func set(_ text: String) {
        lock.lock()
        message = text
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }
}
