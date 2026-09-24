import Foundation
import SwiftySynth

/// Parsed SoundFonts shared by every `SwiftySynthBackend` that loads the same file.
///
/// A parsed General-MIDI font is its whole sample pool in memory — the high-quality one is ~200 MB — and every backend
/// used to parse its own. That was already two copies while an export rendered beside live playback, and it is what
/// made rendering several parts in parallel cost a font per render. A `SoundFont` is immutable once loaded (every
/// stored property is a `let`, and a `Synthesizer` only reads it), so one instance serves any number of synths on any
/// number of threads.
///
/// **Held weakly.** The cache never keeps a font alive on its own: it lives exactly as long as some synth still uses
/// it, and the next load after the last one lets go parses the file again.
///
/// **Keyed by the file's identity, not just its path.** A host that downloads a better font to the same path must not
/// be handed the old parse, so the size and modification date are part of the key.
///
/// **Concurrent requests share one parse.** A second caller asking while the first is still parsing awaits that same
/// parse rather than starting another — which is the case parallel part renders hit, all starting at once. The parse
/// runs in a detached task, so the actor itself is never held for the seconds it takes.
actor SoundFontCache {
    static let shared = SoundFontCache()

    /// `SoundFont` is immutable but not declared `Sendable`; this is the one place it crosses isolation.
    struct Loaded: @unchecked Sendable {
        let font: SoundFont
    }

    private struct Key: Hashable {
        let path: String
        let size: Int
        let modified: Date
    }

    private final class WeakFont {
        weak var font: SoundFont?

        init(_ font: SoundFont) {
            self.font = font
        }
    }

    private var entries: [Key: WeakFont] = [:]
    private var inFlight: [Key: Task<Loaded?, Never>] = [:]

    /// The parsed font at `url`, shared with every other caller that has it loaded, or nil when the file is missing or
    /// does not parse.
    func soundFont(at url: URL) async -> Loaded? {
        let path = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let key = Key(
            path: path,
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modified: attributes[.modificationDate] as? Date ?? .distantPast,
        )
        if let font = entries[key]?.font {
            return Loaded(font: font)
        }
        if let pending = inFlight[key] {
            return await pending.value
        }
        let parse = Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let font = try? SoundFont(data: data)
            else { return nil }
            return Loaded(font: font)
        }
        inFlight[key] = parse
        let loaded = await parse.value
        inFlight[key] = nil
        entries = entries.filter { $0.value.font != nil }
        if let loaded {
            entries[key] = WeakFont(loaded.font)
        }
        return loaded
    }
}
