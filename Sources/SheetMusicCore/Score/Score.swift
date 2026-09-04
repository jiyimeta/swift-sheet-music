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
        for partIndex in stripped.parts.indices {
            stripped.parts[partIndex].preservedMarkup = []
            stripped.parts[partIndex].instrument.preservedMarkup = []
            for channelIndex in stripped.parts[partIndex].instrument.channels.indices {
                stripped.parts[partIndex].instrument.channels[channelIndex].preservedMarkup = []
            }
            for staffIndex in stripped.parts[partIndex].staves.indices {
                stripped.parts[partIndex].staves[staffIndex].staffTypePreservedMarkup = []
                stripped.parts[partIndex].staves[staffIndex].preservedMarkup = []
                for measureIndex in stripped.parts[partIndex].staves[staffIndex].measures.indices {
                    stripPreservedMarkup(
                        from: &stripped.parts[partIndex].staves[staffIndex]
                            .measures[measureIndex],
                    )
                }
            }
        }
        return stripped
    }
}

/// Clear container bags and ordered preserved elements inside one measure.
private func stripPreservedMarkup(from measure: inout Measure) {
    measure.preservedMarkup = []
    for markerIndex in measure.markers.indices {
        measure.markers[markerIndex].preservedMarkup = []
    }
    for jumpIndex in measure.jumps.indices {
        measure.jumps[jumpIndex].preservedMarkup = []
    }
    for voiceIndex in measure.voices.indices {
        MeasureStructure.removeElements(in: &measure.voices[voiceIndex]) { element in
            if case .preserved = element { return true }
            return false
        }
        for elementIndex in measure.voices[voiceIndex].elements.indices {
            measure.voices[voiceIndex].elements[elementIndex] = strippingPreservedMarkup(
                from: measure.voices[voiceIndex].elements[elementIndex],
            )
        }
    }
}

/// Return one modeled voice element with its preserved-markup bag cleared.
private func strippingPreservedMarkup(from element: VoiceElement) -> VoiceElement {
    if case let .chord(value) = element { return .chord(strippingPreservedMarkup(from: value)) }
    if case var .keySignature(value) = element {
        value.preservedMarkup = []; return .keySignature(value)
    }
    if case var .timeSignature(value) = element {
        value.preservedMarkup = []; return .timeSignature(value)
    }
    if case var .clef(value) = element { value.preservedMarkup = []; return .clef(value) }
    if case var .barLine(value) = element { value.preservedMarkup = []; return .barLine(value) }
    if case var .dynamic(value) = element { value.preservedMarkup = []; return .dynamic(value) }
    if case var .spanner(value) = element { value.preservedMarkup = []; return .spanner(value) }
    if case var .harmony(value) = element { value.preservedMarkup = []; return .harmony(value) }
    return element
}

/// Clear a chord/rest bag and every preserved-markup bag nested inside it.
private func strippingPreservedMarkup(from source: Chord) -> Chord {
    var chord = source
    chord.preservedMarkup = []
    for noteIndex in chord.notes.indices {
        chord.notes[noteIndex].preservedMarkup = []
    }
    for lyricIndex in chord.lyrics.indices {
        chord.lyrics[lyricIndex].preservedMarkup = []
    }
    for spannerIndex in chord.spanners.indices {
        chord.spanners[spannerIndex].preservedMarkup = []
    }
    for ornamentIndex in chord.ornaments.indices {
        chord.ornaments[ornamentIndex].preservedMarkup = []
    }
    stripPreservedMarkup(from: &chord.graceNotesBefore)
    stripPreservedMarkup(from: &chord.graceNotesAfter)
    return chord
}

/// Clear grace-chord bags and the note bags they contain.
private func stripPreservedMarkup(from graces: inout [GraceChord]) {
    for graceIndex in graces.indices {
        graces[graceIndex].preservedMarkup = []
        for noteIndex in graces[graceIndex].notes.indices {
            graces[graceIndex].notes[noteIndex].preservedMarkup = []
        }
    }
}
