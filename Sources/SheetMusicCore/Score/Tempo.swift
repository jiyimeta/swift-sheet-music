import SheetMusicFoundation

/// What a tempo marking's text claims — MuseScore's `TempoTextType` (`engraving/dom/tempotext.h:30-35`), written as
/// `<type>aTempo</type>` / `<type>tempoPrimo</type>` and absent for an ordinary marking.
public enum TempoTextType: String, Sendable {
    /// States a tempo: the marking's own number is the tempo from here on.
    case normal
    /// "a tempo": while it follows its text, it brings back the tempo in force before it, undoing a gradual change
    /// (`Score::rebuildTempoAndTimeSigMaps`, `engraving/dom/score.cpp:593-596`).
    case aTempo
    /// "tempo primo": while it follows its text, it brings back the score's first ordinary marking, or 120 BPM when
    /// there is none (`score.cpp:597-598`).
    case tempoPrimo
}

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
    /// Sugar over `elementProperties.offset`.
    public var offsetX: Double {
        get { elementProperties.offset?.x ?? 0 }
        set {
            let y = elementProperties.offset?.y ?? 0
            elementProperties.offset = ScoreOffset(x: newValue, y: y)
        }
    }

    /// Author-supplied Y offset relative to the default placement,
    /// in spatium units (positive = down). Sugar over
    /// `elementProperties.offset`.
    public var offsetY: Double {
        get { elementProperties.offset?.y ?? 0 }
        set {
            let x = elementProperties.offset?.x ?? 0
            elementProperties.offset = ScoreOffset(x: x, y: newValue)
        }
    }

    /// Per-element font overrides on the displayed tempo text.
    /// `nil`-fields inherit from `TextStyleType.tempo`
    /// (Edwin 12 pt bold by default). Has no effect on MIDI output.
    public var properties: TextProperties
    /// Base element properties shared with every engravable element.
    /// Carries `<visible>`, `<color>`, and `<offset>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. When false the tempo
    /// label is hidden — layout drops it (no glyph, no reserved
    /// space) but the tempo change still applies to playback / MIDI.
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// The marking as written, as plain text — the projection of `<text>` every text carrier stores
    /// (`RichText.plainText`). `nil` while the text is derived: a marking built in code, or one whose `<text>` is
    /// exactly the marking `metronomeMarking` prints for its beat and number, which then draws and saves as that.
    public var text: String?
    /// The `<text>` markup as read, written back verbatim while it still describes `text` (`richText`).
    public var preservedTextMarkup: PreservedTextMarkup?
    /// MuseScore `<followText>`: the number written in the text is the tempo. A marking built in code follows its
    /// derived text; a decoded one follows only when the file says so, as MuseScore reads it.
    public var followText: Bool
    /// MuseScore `<type>`.
    public var textType: TempoTextType
    /// MuseScore `<play>`: `false` keeps the marking on the page and out of the tempo map (`score.cpp:582-584`).
    public var playsBack: Bool
    /// Source children the model does not represent (`<musicSymbolSize>`, `<style>`, `<align>`, …), written back as
    /// they were read.
    public var preservedMarkup: [PreservedXML]

    public init(
        beatsPerSecond: Double,
        offsetX: Double = 0,
        offsetY: Double = 0,
        properties: TextProperties = TextProperties(),
        visible: Bool = true,
        beatNote: NoteDuration = .quarter,
        beatDots: Int = 0,
        text: String? = nil,
        preservedTextMarkup: PreservedTextMarkup? = nil,
        followText: Bool = true,
        textType: TempoTextType = .normal,
        playsBack: Bool = true,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.beatsPerSecond = beatsPerSecond
        self.properties = properties
        self.beatNote = beatNote
        self.beatDots = beatDots
        self.text = text
        self.preservedTextMarkup = preservedTextMarkup
        self.followText = followText
        self.textType = textType
        self.playsBack = playsBack
        self.preservedMarkup = preservedMarkup
        let offset: ScoreOffset? = if offsetX == 0 && offsetY == 0 {
            nil
        } else {
            ScoreOffset(x: offsetX, y: offsetY)
        }
        elementProperties = ElementProperties(visible: visible, offset: offset)
    }

    /// Microseconds per quarter note for SMF tempo meta event.
    public var microsecondsPerQuarter: Int {
        Self.microsecondsPerQuarter(beatsPerSecond: beatsPerSecond)
    }

    /// `beatNote`'s length as a multiple of a quarter note (quarter = 1, eighth = 0.5, dotted quarter = 1.5). Bridges
    /// the quarter-normalized `beatsPerSecond` and the beat the marking is drawn in.
    public var beatLengthInQuarters: Double {
        Self.lengthInQuarters(of: beatNote, dots: beatDots)
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
        Self.beatGlyph(note: beatNote, dots: beatDots)
    }
}

extension Tempo {
    /// The SMF tempo of a quarter-normalized tempo: microseconds per quarter (`microsecondsPerQuarter`'s body).
    static func microsecondsPerQuarter(beatsPerSecond: Double) -> Int {
        Int((1.0 / beatsPerSecond * 1_000_000.0).rounded())
    }

    /// A beat's length in quarter notes — quarter 1, eighth 0.5, dotted quarter 1.5 (`beatLengthInQuarters`' body).
    static func lengthInQuarters(of note: NoteDuration, dots: Int) -> Double {
        let beat = note.dotted(dots).asFraction
        // A quarter note is 1/4 of a whole note, so dividing the beat's whole-note fraction by 1/4 gives its length in
        // quarters.
        return (Double(beat.numerator) / Double(beat.denominator)) / 0.25
    }

    /// A beat as Bravura "Individual notes" glyphs (`beatGlyph`'s body): a non-standard note falls back to a quarter.
    static func beatGlyph(note: NoteDuration, dots: Int) -> String {
        let head = switch note {
        case .whole: "\u{E1D2}" // noteWhole
        case .half: "\u{E1D3}" // noteHalfUp
        case .quarter: "\u{E1D5}" // noteQuarterUp
        case .eighth: "\u{E1D7}" // note8thUp
        case .sixteenth: "\u{E1D9}" // note16thUp
        case .thirtySecond: "\u{E1DB}" // note32ndUp
        default: "\u{E1D5}" // noteQuarterUp (fallback)
        }
        // augmentationDot (U+E1E7), one per dot.
        return head + String(repeating: "\u{E1E7}", count: max(0, dots))
    }
}
