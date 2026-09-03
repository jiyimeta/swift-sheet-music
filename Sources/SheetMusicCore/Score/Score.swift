import SheetMusicFoundation

/// Root of the parsed MuseScore document. C++: `mu::engraving::MasterScore`/`Score`.
public struct Score: Sendable, Equatable {
    public var division: Int
    public var parts: [Part]
    /// System-level content for each measure, indexed positionally:
    /// `systemMeasures[i]` corresponds to measure index `i` across
    /// every part/staff. Holds tempo / rehearsal mark / system text
    /// / swing entries with explicit `MeasurePosition`s so they
    /// survive staff visibility filtering — they don't belong to a
    /// particular staff and shouldn't disappear when one is hidden.
    ///
    /// Invariant: `systemMeasures.count` matches the per-staff
    /// `measures.count` for any part/staff with non-empty content.
    /// Parsers (MSCX, MusicXML, MIDI import) and edit commands that
    /// add/remove measures must maintain this alignment.
    public var systemMeasures: [SystemMeasure]
    public var metaTags: [String: String]
    /// Title block (`<VBox>` in MuseScore) above the first system,
    /// when present.
    public var titleFrame: ScoreFrame?
    /// Subset of MuseScore's `<Style>` block.
    public var style: ScoreStyle
    /// Records the format this score was loaded from. Defaults to
    /// `.unknown` for programmatic construction.
    public var source: ScoreSource
    /// Source markup under this element that the model does not
    /// represent, kept so that read → write does not delete it. See
    /// `PreservedXML`.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        division: Int,
        parts: [Part] = [],
        systemMeasures: [SystemMeasure] = [],
        metaTags: [String: String] = [:],
        titleFrame: ScoreFrame? = nil,
        style: ScoreStyle = .museScoreDefaults,
        source: ScoreSource = .unknown,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.division = division
        self.parts = parts
        self.systemMeasures = systemMeasures
        self.metaTags = metaTags
        self.titleFrame = titleFrame
        self.style = style
        self.source = source
        self.preservedMarkup = preservedMarkup
    }

    /// Return a copy without source-only XML carried for MSCX
    /// fidelity. As more model layers gain preserved markup, their
    /// clearing passes are added here.
    public func strippingPreservedMarkup() -> Score {
        var stripped = self
        stripped.preservedMarkup = []
        stripped.style.preservedMarkup = []
        return stripped
    }
}
