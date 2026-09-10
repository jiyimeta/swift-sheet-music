import SheetMusicFoundation

/// Root of the parsed MuseScore document. C++: `mu::engraving::MasterScore`/`Score`.
public struct Score: Sendable, Equatable {
    public var division: Int
    public var parts: IdentifiedArray<Part>
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
    public var systemMeasures: IdentifiedArray<SystemMeasure>
    public var metaTags: [String: String]
    /// Score-level boxes in their document order among measures.
    public var blocks: [PositionedScoreBlock]
    /// Title block (`<VBox>` in MuseScore) above the first system,
    /// when present. This compatibility view reads and writes the
    /// first leading vertical frame in `blocks`.
    public var titleFrame: ScoreFrame? {
        get {
            for positioned in blocks where positioned.beforeMeasureIndex == 0 {
                if case let .verticalFrame(frame) = positioned.block {
                    return frame
                }
            }
            return nil
        }
        set {
            let existingIndex = blocks.firstIndex { positioned in
                guard positioned.beforeMeasureIndex == 0 else { return false }
                if case .verticalFrame = positioned.block { return true }
                return false
            }
            if let existingIndex {
                if let newValue {
                    blocks[existingIndex].block = .verticalFrame(newValue)
                } else {
                    blocks.remove(at: existingIndex)
                }
            } else if let newValue {
                let firstLeadingIndex = blocks.firstIndex {
                    $0.beforeMeasureIndex == 0
                } ?? 0
                blocks.insert(
                    PositionedScoreBlock(
                        beforeMeasureIndex: 0,
                        block: .verticalFrame(newValue),
                    ),
                    at: firstLeadingIndex,
                )
            }
        }
    }

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
        parts: IdentifiedArray<Part> = [],
        systemMeasures: IdentifiedArray<SystemMeasure> = [],
        metaTags: [String: String] = [:],
        titleFrame: ScoreFrame? = nil,
        blocks: [PositionedScoreBlock] = [],
        style: ScoreStyle = .museScoreDefaults,
        source: ScoreSource = .unknown,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.division = division
        self.parts = parts
        self.systemMeasures = systemMeasures
        self.metaTags = metaTags
        self.blocks = blocks
        // The compatibility argument is the title, so when both forms are
        // supplied it precedes every block already present in the stream.
        if let titleFrame {
            self.blocks.insert(
                PositionedScoreBlock(
                    beforeMeasureIndex: 0,
                    block: .verticalFrame(titleFrame),
                ),
                at: 0,
            )
        }
        self.style = style
        self.source = source
        self.preservedMarkup = preservedMarkup
    }

    /// Whether any currently identified collection contains an unassigned slot.
    /// Covers parts, staves, voice members and tuplets, unresolved endpoints, and systemMeasures.
    public var hasUnassignedIDs: Bool {
        parts.hasUnassignedIDs || systemMeasures.hasUnassignedIDs || parts.contains { part in
            part.staves.hasUnassignedIDs || part.staves.contains { staff in
                staff.measures.contains { $0.voices.contains { $0.hasUnassignedIDs } }
            }
        }
    }

    /// Fills only missing IDs on entry, preserving all assigned identifiers.
    /// Includes every voice slot; later phases extend this alongside hasUnassignedIDs
    /// when they identify nested collections.
    public mutating func assignMissingIDs(using ids: inout EIDAllocator) {
        parts.assignMissingIDs(using: &ids)
        for index in parts.indices {
            parts.updateValue(at: index) { part in
                part.staves.assignMissingIDs(using: &ids)
                for staffIndex in part.staves.indices {
                    part.staves.updateValue(at: staffIndex) { staff in
                        for measureIndex in staff.measures.indices {
                            for voiceIndex in staff.measures[measureIndex].voices.indices {
                                staff.measures[measureIndex].voices[voiceIndex].assignMissingIDs(using: &ids)
                            }
                        }
                    }
                }
            }
        }
        systemMeasures.assignMissingIDs(using: &ids)
    }

    /// Return a copy without source-only XML carried for MSCX
    /// fidelity. As more model layers gain preserved markup, their
    /// clearing passes are added here.
    public func strippingPreservedMarkup() -> Score {
        var stripped = self
        stripped.preservedMarkup = []
        stripped.style.preservedMarkup = []
        for blockIndex in stripped.blocks.indices {
            switch stripped.blocks[blockIndex].block {
            case var .verticalFrame(frame):
                frame.preservedMarkup = []
                for textIndex in frame.texts.indices {
                    frame.texts[textIndex].preservedTextMarkup = nil
                }
                stripped.blocks[blockIndex].block = .verticalFrame(frame)
            case var .opaqueFrame(frame):
                frame.preservedMarkup = []
                stripped.blocks[blockIndex].block = .opaqueFrame(frame)
            }
        }
        for measureIndex in stripped.systemMeasures.indices {
            stripped.systemMeasures.updateValue(at: measureIndex) { column in
                for elementIndex in column.elements.indices {
                    stripPreservedMarkup(
                        from: &column.elements[elementIndex].element,
                    )
                }
            }
        }
        for partIndex in stripped.parts.indices {
            stripped.parts.updateValue(at: partIndex) { partValue in
                partValue.preservedMarkup = []
            }
            stripped.parts.updateValue(at: partIndex) { partValue in
                stripPreservedMarkup(from: &partValue.instrument)
            }
            for staffIndex in stripped.parts[partIndex].staves.indices {
                stripped.parts.updateValue(at: partIndex) { partValue in
                    partValue.staves.updateValue(at: staffIndex) { staffValue in
                        staffValue.staffTypePreservedMarkup = []
                    }
                }
                stripped.parts.updateValue(at: partIndex) { partValue in
                    partValue.staves.updateValue(at: staffIndex) { staffValue in
                        staffValue.preservedMarkup = []
                    }
                }
                for measureIndex in stripped.parts[partIndex].staves[staffIndex].measures.indices {
                    stripped.parts.updateValue(at: partIndex) { partValue in
                        partValue.staves.updateValue(at: staffIndex) { staffValue in
                            stripPreservedMarkup(
                                from: &staffValue
                                    .measures[measureIndex],
                            )
                        }
                    }
                }
            }
        }
        return stripped
    }
}

/// Clear the bags reachable from one system element.
///
/// `.instrumentChange` reaches the `Instrument` it swaps in, and below
/// that its `StringData` and its channels. A mid-score change to a TAB
/// instrument really does write
/// `<InstrumentChange><Instrument><StringData>`, so this is a reachable
/// path and not a theoretical one. Every case but `.tempo` also carries
/// inline `<text>` markup; `Tempo` does not, because its `<text>` is
/// regenerated from the modeled tempo rather than round-tripped.
///
/// The switch is written over every case rather than as a single
/// `if case` so that a new `SystemElement` case that does carry a
/// bag fails to compile here instead of silently keeping its markup.
private func stripPreservedMarkup(from element: inout SystemElement) {
    switch element {
    case var .instrumentChange(change):
        if var instrument = change.instrument {
            stripPreservedMarkup(from: &instrument)
            change.instrument = instrument
        }
        change.preservedTextMarkup = nil
        element = .instrumentChange(change)
    case var .staffText(text):
        text.preservedTextMarkup = nil
        element = .staffText(text)
    case var .rehearsalMark(mark):
        mark.preservedTextMarkup = nil
        element = .rehearsalMark(mark)
    case var .swing(swing):
        swing.preservedTextMarkup = nil
        element = .swing(swing)
    case .tempo:
        break
    }
}

/// Clear the bags on one instrument and everything nested in it.
private func stripPreservedMarkup(from instrument: inout Instrument) {
    instrument.preservedMarkup = []
    instrument.stringData?.preservedMarkup = []
    for channelIndex in instrument.channels.indices {
        instrument.channels[channelIndex].preservedMarkup = []
    }
}

/// Clear container bags and ordered preserved elements inside one measure.
private func stripPreservedMarkup(from measure: inout Measure) {
    measure.preservedMarkup = []
    for markerIndex in measure.markers.indices {
        measure.markers[markerIndex].preservedMarkup = []
        measure.markers[markerIndex].preservedTextMarkup = nil
    }
    for jumpIndex in measure.jumps.indices {
        measure.jumps[jumpIndex].preservedMarkup = []
        measure.jumps[jumpIndex].preservedTextMarkup = nil
    }
    for voiceIndex in measure.voices.indices {
        MeasureStructure.removeElements(in: &measure.voices[voiceIndex]) { element in
            if case .preserved = element { return true }
            return false
        }
        for elementIndex in measure.voices[voiceIndex].elements.indices {
            measure.voices[voiceIndex].elements.updateValue(at: elementIndex) {
                $0 = strippingPreservedMarkup(from: $0)
            }
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
    if case var .sticking(value) = element {
        value.preservedMarkup = []; value.preservedTextMarkup = nil; return .sticking(value)
    }
    if case var .expression(value) = element {
        value.preservedMarkup = []; value.preservedTextMarkup = nil; return .expression(value)
    }
    if case var .capo(value) = element {
        value.preservedMarkup = []; value.preservedTextMarkup = nil; return .capo(value)
    }
    if case var .stringTunings(value) = element {
        value.preservedMarkup = []
        value.preservedTextMarkup = nil
        value.stringData?.preservedMarkup = []
        return .stringTunings(value)
    }
    if case var .ambitus(value) = element { value.preservedMarkup = []; return .ambitus(value) }
    if case var .figuredBass(value) = element {
        value.preservedMarkup = []
        for itemIndex in value.items.indices {
            value.items[itemIndex].preservedMarkup = []
        }
        return .figuredBass(value)
    }
    if case var .symbol(value) = element { value.preservedMarkup = []; return .symbol(value) }
    if case var .fretDiagram(value) = element {
        value.preservedMarkup = []
        value.harmony?.preservedMarkup = []
        return .fretDiagram(value)
    }
    return element
}

/// Clear a chord/rest bag and every preserved-markup bag nested inside it.
private func strippingPreservedMarkup(from source: Chord) -> Chord {
    var chord = source
    chord.preservedMarkup = []
    for noteIndex in chord.notes.indices {
        stripPreservedMarkup(from: &chord.notes[noteIndex])
    }
    for lyricIndex in chord.lyrics.indices {
        chord.lyrics[lyricIndex].preservedMarkup = []
        chord.lyrics[lyricIndex].preservedTextMarkup = nil
    }
    for spannerIndex in chord.spanners.indices {
        chord.spanners[spannerIndex].preservedMarkup = []
    }
    for ornamentIndex in chord.ornaments.indices {
        chord.ornaments[ornamentIndex].preservedMarkup = []
    }
    chord.bracket?.preservedMarkup = []
    stripPreservedMarkup(from: &chord.graceNotesBefore)
    stripPreservedMarkup(from: &chord.graceNotesAfter)
    return chord
}

/// Clear grace-chord bags and the note bags they contain.
private func stripPreservedMarkup(from graces: inout [GraceChord]) {
    for graceIndex in graces.indices {
        graces[graceIndex].preservedMarkup = []
        for noteIndex in graces[graceIndex].notes.indices {
            stripPreservedMarkup(from: &graces[graceIndex].notes[noteIndex])
        }
    }
}

/// Clear one note's bag and the bags on everything attached to it.
///
/// Shared by the chord and grace-chord walks. It used to be written
/// out at both call sites and they had drifted: the grace path cleared
/// `symbols` but not `fingerings`, so a fingering on a grace note kept
/// its markup. Attaching a new child to `Note` should mean editing this
/// one function, not remembering that there are two places.
private func stripPreservedMarkup(from note: inout Note) {
    note.preservedMarkup = []
    note.glissando?.preservedTextMarkup = nil
    for fingeringIndex in note.fingerings.indices {
        note.fingerings[fingeringIndex].preservedMarkup = []
        note.fingerings[fingeringIndex].preservedTextMarkup = nil
    }
    for symbolIndex in note.symbols.indices {
        note.symbols[symbolIndex].preservedMarkup = []
    }
}
