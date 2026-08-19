import SheetMusicFoundation

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
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch let error as DecodingError {
            // The `JSONSerialization` path this replaced cast the root with
            // `as? [String: Any]` and returned no presets when that failed.
            // MuseScore has never written a non-object root, but treating
            // one as fatal would fail the whole score load over a file that
            // only carries optional overrides.
            guard case .typeMismatch = error else { throw error }
            return AudioSettings(presets: [:])
        }
        var presets: [String: Preset] = [:]
        for track in document.tracks ?? [] {
            guard let partId = track.partId else { continue }
            let attributes = track.input?.resourceMeta?.attributes
            let program = attributes?.presetProgram.flatMap(Int.init)
            // Ignore entries that don't nominate a program override —
            // they exist only to carry SoundFont identity / aux-send
            // state for drumset rows and the metronome (partId
            // "999"), and a nil here keeps the InstrumentChannel
            // untouched.
            guard program != nil else { continue }
            presets[partId] = Preset(
                bank: attributes?.presetBank.flatMap(Int.init),
                program: program,
                name: attributes?.presetName,
            )
        }
        return AudioSettings(presets: presets)
    }
}

/// `JSONSerialization` is umbrella-only, so the shape MuseScore writes is
/// spelled out for `JSONDecoder` instead. Everything is optional: the file
/// carries overrides, and a field that is absent or unexpected has to leave
/// the corresponding `InstrumentChannel` alone rather than fail the load —
/// which is what the chain of `as?` casts used to do implicitly.
extension AudioSettings {
    fileprivate struct Document: Decodable {
        var tracks: [Track]?
    }

    fileprivate struct Track: Decodable {
        var partId: String?
        var input: Input?

        private enum CodingKeys: String, CodingKey {
            case partId
            case input = "in"
        }
    }

    fileprivate struct Input: Decodable {
        var resourceMeta: ResourceMeta?
    }

    fileprivate struct ResourceMeta: Decodable {
        var attributes: Attributes?
    }

    fileprivate struct Attributes: Decodable {
        var presetProgram: String?
        var presetBank: String?
        var presetName: String?

        /// Field by field through `try?` so a value of an unexpected type
        /// drops that one field instead of the file, the way `as? String`
        /// did before.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            presetProgram = try? container.decodeIfPresent(String.self, forKey: .presetProgram)
            presetBank = try? container.decodeIfPresent(String.self, forKey: .presetBank)
            presetName = try? container.decodeIfPresent(String.self, forKey: .presetName)
        }

        private enum CodingKeys: String, CodingKey {
            case presetProgram, presetBank, presetName
        }
    }
}
