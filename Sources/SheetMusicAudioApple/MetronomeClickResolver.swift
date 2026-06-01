import Foundation
import SheetMusicAudioCore

/// Resolves a `MetronomeClickProvider`'s `MetronomeClickSource` into a
/// concrete SoundFont URL the metronome synth can load.
///
/// * `.clickSamples` — reads the WAV pair with `WavPcmReader`, builds an
///   SF2 with `ClickSoundFontBuilder`, writes it to the caches directory
///   once, and caches the generated URL keyed by the source so repeated
///   `prepare(score:)` / export calls reuse the same file.
/// * `.soundFont` — returns the host's SF2 URL verbatim.
/// * `.defaultGM` (or no provider) — falls back to the score's
///   `SoundfontResolver` drum-kit lookup, preserving the legacy behavior.
///
/// On any WAV-read / SF2-write failure for `.clickSamples`, falls back to
/// the `.defaultGM` URL so a bad click file degrades to the GM drum-kit
/// rather than failing score preparation (metronome load is non-fatal).
///
/// Used only from `PlaybackEngine` on the main actor, so it needs no
/// internal synchronization.
final class MetronomeClickResolver {
    private let provider: MetronomeClickProvider?
    private let soundfontResolver: SoundfontResolver
    private var generatedCache: [MetronomeClickSource: URL] = [:]

    init(provider: MetronomeClickProvider?, soundfontResolver: SoundfontResolver) {
        self.provider = provider
        self.soundfontResolver = soundfontResolver
    }

    /// The SoundFont URL the metronome should load, or `nil` when even the
    /// GM fallback is unavailable (host ships no SoundFont).
    func resolvedSoundFontURL() -> URL? {
        let source = provider?.metronomeClickSource() ?? .defaultGM
        switch source {
        case .defaultGM:
            return defaultGMURL()
        case let .soundFont(url):
            return url
        case let .clickSamples(strong, weak):
            if let cached = generatedCache[source] { return cached }
            guard let built = buildClickSoundFont(strong: strong, weak: weak) else {
                // Bad WAV / write failure: degrade to the GM drum-kit rather
                // than failing score prep (metronome load is non-fatal). The
                // host currently isn't told the custom click was dropped.
                return defaultGMURL()
            }
            generatedCache[source] = built
            return built
        }
    }

    private func defaultGMURL() -> URL? {
        soundfontResolver.soundfontURL(forBank: 0, program: 0, isDrums: true)
            ?? soundfontResolver.defaultGMSoundfontURL
    }

    private func buildClickSoundFont(strong: URL, weak: URL) -> URL? {
        guard
            let strongPCM = try? WavPcmReader.read(contentsOf: strong),
            let weakPCM = try? WavPcmReader.read(contentsOf: weak)
        else { return nil }
        let sf2 = ClickSoundFontBuilder.build(
            strong: strongPCM.samples, strongRate: strongPCM.sampleRate,
            weak: weakPCM.samples, weakRate: weakPCM.sampleRate,
        )
        guard let dir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SheetMusicMetronomeClicks", isDirectory: true)
        else { return nil }
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
        )
        // Content-addressed name: identical clicks map to the same file,
        // so generated SF2s don't accumulate across resolver instances /
        // app launches, and a changed click (new bytes) gets a new name.
        let file = dir.appendingPathComponent(
            String(format: "%016llx.sf2", Self.fnv1a(sf2)),
        )
        if !FileManager.default.fileExists(atPath: file.path) {
            guard (try? sf2.write(to: file)) != nil else { return nil }
        }
        return file
    }

    /// FNV-1a 64-bit hash, used to derive a stable, content-addressed
    /// filename for the generated SF2 (Swift's `Hasher` is seeded per
    /// process, so it can't produce a stable on-disk name).
    private static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
