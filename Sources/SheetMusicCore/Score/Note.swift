import Foundation

/// A pitched note inside a `Chord`. C++: `mu::engraving::Note` (subset).
public struct Note: Sendable, Equatable {
    public var pitch: Int // MIDI 0..127
    public var tpc: Int // tonal pitch class
    public var accidental: Accidental?
    /// Visual bracket drawn around the accidental (parenthesis or square bracket).
    /// MuseScore stores `<bracket>1</bracket>` (parenthesis) or `<bracket>2</bracket>`
    /// (bracket) inside the `<Accidental>` element. Absent means `.none`.
    public var accidentalBracket: AccidentalBracket
    /// Whether this note's accidental was placed automatically by the
    /// engraver (`.auto`) or forced explicitly by the user (`.user`).
    /// MuseScore writes `<Accidental><role>1</role>` only for USER
    /// accidentals; absent means `.auto`. Drives redundant-accidental
    /// suppression (`Score.suppressingRedundantAccidentals()`): a USER
    /// accidental is never hidden even when redundant.
    public var accidentalRole: AccidentalRole
    /// Tie continuing forward from this note. `nil` means no tie;
    /// `.some(n)` means a tie numbered `n` (MusicXML `<tie number="N">`;
    /// MSCX ties are positional and default to 1).
    public var tieForward: Int?
    /// Tie ending on this note. See `tieForward`.
    public var tieBack: Int?
    /// Glissando starting on this note and sweeping to the next chord's note.
    /// C++: `<Spanner type="Glissando">` attached to a `<Note>`.
    public var glissando: Glissando?
    /// Notehead shape override (e.g. "cross" for hi-hat, "diamond" for
    /// percussion rim, "triangle-down" for cowbell). When nil, the
    /// standard notehead for the duration is used.
    public var headType: String?
    /// Round parentheses drawn around this notehead. MuseScore stores
    /// `<parentheses>both</parentheses>` on the note (4.6), a `<Symbol>`
    /// pair (≤4.5), or a chord-level `<NoteParenGroup>` (4.7+). Absent
    /// means `.none`. Display-only; MIDI is unaffected.
    public var parentheses: NoteParentheses
    /// Whether this note is displayed at a reduced size. MuseScore stores
    /// `<small>1</small>` on the note element when true; absent means false.
    /// Chord-level smallness (`<Chord><small>`) is propagated separately
    /// in layout (Task 2.2) and does not set this flag.
    /// C++: `Note::isSmall()` / `Note::setSmall()`.
    public var isSmall: Bool
    /// Whether this note sounds during playback. MuseScore stores a
    /// per-note "play" flag (`<play>0</play>` when false); a muted
    /// note is still engraved but emits no MIDI. C++: `Note::play()`,
    /// which gates `CompatMidiRender::collectNote`.
    public var play: Bool
    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public init(
        pitch: Int,
        tpc: Int,
        accidental: Accidental? = nil,
        accidentalBracket: AccidentalBracket = .none,
        accidentalRole: AccidentalRole = .auto,
        tieForward: Int? = nil,
        tieBack: Int? = nil,
        glissando: Glissando? = nil,
        headType: String? = nil,
        parentheses: NoteParentheses = .none,
        isSmall: Bool = false,
        play: Bool = true,
        visible: Bool = true,
    ) {
        self.pitch = pitch
        self.tpc = tpc
        self.accidental = accidental
        self.accidentalBracket = accidentalBracket
        self.accidentalRole = accidentalRole
        self.tieForward = tieForward
        self.tieBack = tieBack
        self.glissando = glissando
        self.headType = headType
        self.parentheses = parentheses
        self.isSmall = isSmall
        self.play = play
        elementProperties = ElementProperties(visible: visible)
    }
}
