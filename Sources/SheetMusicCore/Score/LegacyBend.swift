/// A pre-4.2 MuseScore guitar bend: a pitch curve attached to one note.
/// C++: `mu::engraving::Bend` (`dom/bend.h` — "OBSOLETE CLASS … replaced
/// by the GuitarBend class", but still fully read, written, laid out,
/// drawn, and played by MuseScore 4). MuseScore 3 and 4 serialize it
/// identically as a `<Bend>` child of `<Note>`; no conversion to
/// `GuitarBend` exists outside the Guitar Pro importer.
public struct LegacyBend: Sendable, Equatable {
    /// One curve point. C++: `mu::engraving::PitchValue`
    /// (`types/pitchvalue.h`).
    public struct Point: Sendable, Equatable {
        /// 0…60 (`PitchValue::MAX_TIME`), fraction of the play span.
        public var time: Int
        /// 50 units = one semitone; 100 = "full" bend (whole tone).
        /// (`PITCH_FOR_SEMITONE = 100` is misleading — `collectBend`'s
        /// scale folds an extra ×2 in, and the label table maps
        /// 25→"1/4", 50→"1/2", 100→"full".)
        public var pitch: Int
        /// Stored for round-trip; MuseScore 4 ignores it in both layout
        /// and playback, and so does this package.
        public var vibrato: Int

        public init(time: Int, pitch: Int, vibrato: Int = 0) {
            self.time = time
            self.pitch = pitch
            self.vibrato = vibrato
        }
    }

    public var points: [Point]
    /// `<play>` — false silences the curve (the note still sounds).
    public var play: Bool
    /// Styled overrides, present only when the user restyled the bend.
    /// Defaults live in the style table (`Sid::bendLineWidth` 0.15 sp,
    /// `Sid::bendFontFace` "Edwin" 8 pt normal) and are NOT duplicated
    /// here. `lineWidth` is in spatium units.
    ///
    /// Round-trip only: these four fields are decoded and re-encoded so a
    /// restyled bend survives a load/save byte-identically, but nothing
    /// reads them afterwards. Layout and all three drawing paths (Canvas,
    /// CALayer, and the layout bridge) use the `LegacyBendGeometry`
    /// constants and the `TextStyleType.bend` defaults unconditionally,
    /// so a restyled bend draws exactly like an unstyled one. Threading
    /// the overrides through `LegacyBendShape` is a recorded follow-up.
    public var lineWidth: Double?
    public var fontFace: String?
    public var fontSize: Double?
    public var fontStyle: Int?

    public init(
        points: [Point],
        play: Bool = true,
        lineWidth: Double? = nil,
        fontFace: String? = nil,
        fontSize: Double? = nil,
        fontStyle: Int? = nil,
    ) {
        self.points = points
        self.play = play
        self.lineWidth = lineWidth
        self.fontFace = fontFace
        self.fontSize = fontSize
        self.fontStyle = fontStyle
    }
}
