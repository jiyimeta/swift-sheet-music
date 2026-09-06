import SheetMusicFoundation

/// An instrument definition attached to a part. C++: `mu::engraving::Instrument`.
public struct Instrument: Sendable, Equatable {
    public var id: String
    public var longName: String?
    public var shortName: String?
    public var trackName: String?
    public var minPitchPlayable: Int? // C++: minPitchP
    public var maxPitchPlayable: Int? // C++: maxPitchP
    public var minPitchAmateur: Int? // C++: minPitchA
    public var maxPitchAmateur: Int? // C++: maxPitchA
    public var articulations: [InstrumentArticulation]
    /// All `<Channel>` blocks defined for this instrument: usually one ("normal")
    /// for simple instruments, multiple for instruments with playback flavours
    /// (e.g. violin = "normal", "pizzicato", "tremolo").
    public var channels: [InstrumentChannel]
    /// `<useDrumset>1</useDrumset>` — true for drum kits and percussion. Causes
    /// the renderer to route the part through GM channel 10 (0-indexed: 9), which
    /// DAWs like Logic Pro auto-detect as percussion and dress with a drum kit
    /// patch. C++: `mu::engraving::Instrument::useDrumset()`.
    public var useDrumset: Bool
    /// The part's drum kit: MIDI pitch → how that drum is engraved (staff line, notehead, voice, stem, name).
    /// MuseScore's `<Drum>` elements, one to one. Empty for a pitched instrument.
    ///
    /// The layout engine reads only the lines, through `drumLineMap`; the heads and voices are what the MSCX
    /// encoder needs and what drum note entry writes.
    public var drumset: [Int: DrumsetEntry]
    /// `<StringData>` — the fretted-instrument tuning. `nil` when the
    /// instrument declares none, which is every non-TAB instrument.
    public var stringData: StringData?
    /// Source markup under this element that the model does not
    /// represent, kept so that read → write does not delete it.
    public var preservedMarkup: [PreservedXML] = []

    /// Per-pitch staff-line mapping for drum instruments. Key = MIDI pitch
    /// (35 = bass drum, 42 = hi-hat, etc.), value = MuseScore line number
    /// (0 = top staff line, 4 = middle, 8 = bottom, negative = above staff).
    /// Used by the UI to position drum noteheads instead of the pitched
    /// diatonic formula.
    ///
    /// The lines-only view of `drumset`, which is where they are actually stored. Assigning REPLACES the kit: a
    /// pitch the new map does not name is dropped, exactly as it was when this was the stored property. A pitch
    /// it names that the kit already has keeps its head, voice, stem and name and only moves line; a pitch that
    /// is new gets `GMDrumset`'s defaults.
    public var drumLineMap: [Int: Int] {
        get { drumset.mapValues(\.line) }
        set {
            var next: [Int: DrumsetEntry] = [:]
            next.reserveCapacity(newValue.count)
            for (pitch, line) in newValue {
                if var existing = drumset[pitch] {
                    existing.line = line
                    next[pitch] = existing
                } else {
                    next[pitch] = GMDrumset.entry(forPitch: pitch, line: line)
                }
            }
            drumset = next
        }
    }

    /// mscx `<transposeDiatonic>` — diatonic steps from written to sounding pitch (negative = sounds lower).
    public var transposeDiatonic: Int
    /// mscx `<transposeChromatic>` — semitones from written to sounding pitch (negative = sounds lower).
    public var transposeChromatic: Int

    /// Convenience accessor for the primary (= first) channel.
    public var channel: InstrumentChannel {
        channels.first ?? InstrumentChannel()
    }

    /// Semitones to ADD to a concert (sounding) pitch to get the written pitch.
    public var writtenPitchOffset: Int {
        -transposeChromatic
    }

    /// Line-of-fifths shift to ADD to a concert tpc (or key) to get the written one.
    public var writtenFifthsOffset: Int {
        12 * transposeDiatonic - 7 * transposeChromatic
    }

    public var isTransposing: Bool {
        transposeDiatonic != 0 || transposeChromatic != 0
    }

    public init(
        id: String,
        longName: String? = nil,
        shortName: String? = nil,
        trackName: String? = nil,
        minPitchPlayable: Int? = nil,
        maxPitchPlayable: Int? = nil,
        minPitchAmateur: Int? = nil,
        maxPitchAmateur: Int? = nil,
        articulations: [InstrumentArticulation] = [],
        channels: [InstrumentChannel] = [InstrumentChannel()],
        useDrumset: Bool = false,
        drumLineMap: [Int: Int] = [:],
        drumset: [Int: DrumsetEntry] = [:],
        stringData: StringData? = nil,
        transposeDiatonic: Int = 0,
        transposeChromatic: Int = 0,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.id = id
        self.longName = longName
        self.shortName = shortName
        self.trackName = trackName
        self.minPitchPlayable = minPitchPlayable
        self.maxPitchPlayable = maxPitchPlayable
        self.minPitchAmateur = minPitchAmateur
        self.maxPitchAmateur = maxPitchAmateur
        self.articulations = articulations
        self.channels = channels.isEmpty ? [InstrumentChannel()] : channels
        self.useDrumset = useDrumset
        // Two spellings of one kit, so the many existing callers that build one from lines alone keep working.
        // An explicit `drumset` is the richer of the two and wins; `drumLineMap` is filled out from `GMDrumset`.
        if !drumset.isEmpty {
            self.drumset = drumset
        } else {
            self.drumset = drumLineMap.reduce(into: [:]) { result, pair in
                result[pair.key] = GMDrumset.entry(forPitch: pair.key, line: pair.value)
            }
        }
        self.stringData = stringData
        self.transposeDiatonic = transposeDiatonic
        self.transposeChromatic = transposeChromatic
        self.preservedMarkup = preservedMarkup
    }
}
