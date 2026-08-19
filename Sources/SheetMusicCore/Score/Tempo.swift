import SheetMusicFoundation

/// Tempo change. mscx `<tempo>` is in beats per second (a float).
/// C++: `mu::engraving::TempoText` / `mu::engraving::Tempo`.
public struct Tempo: Sendable, Equatable {
    /// Beats per second as encoded in mscx. 2.0 = 120 BPM (since mscx tempo is per quarter).
    public var beatsPerSecond: Double
    /// The note value the engraved marking counts in — the "beat" of "♩ = 120" (a plain quarter) or "♩. = 80" (a
    /// dotted quarter, as 6/8 markings usually are). MuseScore normalizes `beatsPerSecond` to a quarter note, which
    /// loses this, so the decoder recovers it from the printed marking. Defaults to a plain quarter: the value used for
    /// programmatically-built tempos and when the source's beat can't be recovered.
    public var beatNote: NoteDuration
    /// Augmentation-dot count on `beatNote` (0 = none, 1 = dotted, 2 = double-dotted).
    public var beatDots: Int
    /// Author-supplied X offset relative to the default placement,
    /// in spatium units. Applied AFTER autoplace-style stacking.
    public var offsetX: Double
    /// Author-supplied Y offset relative to the default placement,
    /// in spatium units (positive = down).
    public var offsetY: Double
    /// Per-element font overrides on the displayed tempo text.
    /// `nil`-fields inherit from `TextStyleType.tempo`
    /// (Edwin 12 pt bold by default). Has no effect on MIDI output.
    public var properties: TextProperties
    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. When false the tempo
    /// label is hidden — layout drops it (no glyph, no reserved
    /// space) but the tempo change still applies to playback / MIDI.
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(
        beatsPerSecond: Double,
        offsetX: Double = 0,
        offsetY: Double = 0,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
        beatNote: NoteDuration = .quarter,
        beatDots: Int = 0,
    ) {
        self.beatsPerSecond = beatsPerSecond
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.properties = properties
        self.beatNote = beatNote
        self.beatDots = beatDots
        elementProperties = ElementProperties(visible: visible)
    }

    /// Microseconds per quarter note for SMF tempo meta event.
    public var microsecondsPerQuarter: Int {
        Int((1.0 / beatsPerSecond * 1_000_000.0).rounded())
    }

    /// `beatNote`'s length as a multiple of a quarter note (quarter = 1, eighth = 0.5, dotted quarter = 1.5). Bridges
    /// the quarter-normalized `beatsPerSecond` and the beat the marking is drawn in.
    public var beatLengthInQuarters: Double {
        let beat = beatNote.dotted(beatDots).asFraction
        // A quarter note is 1/4 of a whole note, so dividing the beat's whole-note fraction by 1/4 gives its length in
        // quarters.
        return (Double(beat.numerator) / Double(beat.denominator)) / 0.25
    }

    /// Tempo expressed in `beatNote` units — the number the marking prints (the 80 of "♩. = 80"). Inverse of
    /// MuseScore's followText math: `beatsPerSecond * 60` is quarter-BPM, divided by the beat's length in quarters.
    public var beatsPerMinute: Double {
        beatsPerSecond * 60 / beatLengthInQuarters
    }

    /// The beat note as a SMuFL glyph string from Bravura's "Individual notes" range (U+E1D0–U+E1EF) — e.g. a quarter
    /// `"\u{E1D5}"` or a dotted quarter `"\u{E1D5}\u{E1E7}"`. Render with the `Bravura` font (see `BravuraFont`) to
    /// draw the engraved "♩. = …" beat token. Non-standard beat notes (a raw `.fraction` / `.measure`) fall back to a
    /// quarter.
    public var beatGlyph: String {
        let note = switch beatNote {
        case .whole: "\u{E1D2}" // noteWhole
        case .half: "\u{E1D3}" // noteHalfUp
        case .quarter: "\u{E1D5}" // noteQuarterUp
        case .eighth: "\u{E1D7}" // note8thUp
        case .sixteenth: "\u{E1D9}" // note16thUp
        case .thirtySecond: "\u{E1DB}" // note32ndUp
        default: "\u{E1D5}" // noteQuarterUp (fallback)
        }
        // augmentationDot (U+E1E7), one per dot.
        return note + String(repeating: "\u{E1E7}", count: max(0, beatDots))
    }
}
