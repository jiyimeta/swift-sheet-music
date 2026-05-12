import Foundation

/// Per-part playback overrides stored in MuseScore 4's
/// `audiosettings.json`. When the user picks a different SoundFont
/// preset in the Mixer / Instruments panel, MuseScore writes the new
/// bank+program here but keeps the original template program in the
/// `.mscx`'s `<Channel><program>`. To match the sounds MuseScore
/// actually plays, the reader merges these presets into each part's
/// primary `InstrumentChannel`.
///
/// Only the fields we currently consume are decoded — bank, program,
/// and name. The SoundFont identity, aux-send levels, and FX chain
/// configurations in the JSON are ignored.
struct AudioSettings: Equatable {
    struct Preset: Equatable {
        var bank: Int?
        var program: Int?
        var name: String?
    }

    /// Keyed by `<Part id="…">` (matches the `partId` field in the
    /// JSON). Parts without a corresponding entry — or entries
    /// without `presetProgram` (e.g. drumset rows, the metronome
    /// row id "999") — are absent so callers can skip them.
    var presets: [String: Preset]

    static func parse(_ data: Data) throws -> AudioSettings {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let dict = root as? [String: Any] else {
            return AudioSettings(presets: [:])
        }
        let tracks = dict["tracks"] as? [[String: Any]] ?? []
        var presets: [String: Preset] = [:]
        for track in tracks {
            guard let partId = track["partId"] as? String else { continue }
            let inDict = track["in"] as? [String: Any] ?? [:]
            let meta = inDict["resourceMeta"] as? [String: Any] ?? [:]
            let attrs = meta["attributes"] as? [String: Any] ?? [:]
            let program = (attrs["presetProgram"] as? String).flatMap(Int.init)
            let bank = (attrs["presetBank"] as? String).flatMap(Int.init)
            let name = attrs["presetName"] as? String
            // Ignore entries that don't nominate a program override —
            // they exist only to carry SoundFont identity / aux-send
            // state for drumset rows and the metronome (partId
            // "999"), and a nil here keeps the InstrumentChannel
            // untouched.
            guard program != nil else { continue }
            presets[partId] = Preset(
                bank: bank, program: program, name: name,
            )
        }
        return AudioSettings(presets: presets)
    }
}
