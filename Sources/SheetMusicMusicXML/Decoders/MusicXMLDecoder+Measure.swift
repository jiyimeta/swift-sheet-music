import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Walks the `<measure>` children of a single MusicXML `<part>` and produces
/// one `[Measure]` array per staff in the part. MusicXML interleaves notes
/// for all staves in a single `<measure>` block; `<note><staff>N</staff></note>`
/// selects the target staff, and `<attributes><staves>` declares the count.
/// Reference implementation: `MusicXmlParserPass2::measure`.
enum MusicXMLMeasureWalker {
    /// Return value grouping the decoded measures per staff (`[staff1, staff2, …]`)
    /// and the detected staff count.
    struct PartResult {
        let staffCount: Int
        /// `measuresByStaff[staffIndex][measureIndex]` — outer array has
        /// `staffCount` entries; inner array holds one `Measure` per
        /// `<measure>` block.
        let measuresByStaff: [[Measure]]
        /// `systemElementsByStaffMeasure[staffIndex][measureIndex]` —
        /// the system-level elements (currently just rehearsal marks)
        /// that were lifted out during decode, ready to be merged into
        /// the score-level `[SystemMeasure]` once the staff address is
        /// known.
        let systemElementsByStaffMeasure: [[[PositionedSystemElement]]]
        /// `<attributes><staff-details><staff-lines>` per 0-based staff
        /// index, already clamped to `1...16`. Staff-level rather than
        /// measure-level, so it is collected during the walk and handed
        /// to the `Staff` construction sites instead of being emitted
        /// into the measure stream. Staves absent from the map keep
        /// `Staff.lineCount`'s default of 5.
        let lineCountByStaff: [Int: Int]
        /// `tempoElementsByMeasure[measureIndex]` — the part's tempo markings, which belong to the score's top staff
        /// whatever part wrote them.
        let tempoElementsByMeasure: [[PositionedSystemElement]]
    }

    static func decode(
        partNode: XMLTreeNode,
        drumTable: MusicXMLDrumTable = MusicXMLDrumTable(),
        options: MusicXMLImportOptions = .default,
        partIndex: Int = 0,
        registry: MusicXMLTempoRegistryBox = MusicXMLTempoRegistryBox(),
    ) throws -> PartResult {
        let staffCount = detectStaffCount(partNode: partNode)
        var divisions = DivisionsContext(perQuarter: 1)
        var previousAttributes = MusicXMLAttributesSnapshot()
        var perStaffMeasures: [[Measure]] = Array(repeating: [], count: staffCount)
        var perStaffSystemElements: [[[PositionedSystemElement]]] = Array(repeating: [], count: staffCount)
        // Glissando / slide events span notes (and possibly measures)
        // within a part; the tracker accumulates pending starts and
        // resolved attachments across the full per-part walk, then
        // attachments are applied after measures are built. Scope is
        // strictly per-part — no cross-part state leaks because the
        // tracker is a fresh local here.
        var glideTracker = MusicXMLGlideTracker()
        // Direction elements wait for the part to be walked, then go into their voices at their ticks, placed by the
        // chord anchors (`anchors[staff][measure]`, positional voice 0).
        var directionEvents: [MusicXMLDirectionEvent] = []
        var anchors: [[[MusicXMLChordAnchor]]] = Array(repeating: [], count: staffCount)
        var tempoElements: [[PositionedSystemElement]] = []
        var measureLengths: [Fraction] = []
        // The lines inferred from words live across measures; their limit is measured from the part's start.
        var inferredLines = MusicXMLInferredLineLog()
        var partTick = Fraction.zeroTick
        // The octave shifts are read before the notes, as MuseScore's pass 1 reads them (`P2:7264`).
        let octaveShifts = MusicXMLOctaveShiftScan.scan(partNode: partNode)
        for (index, measureNode) in partNode.all("measure").enumerated() {
            let isFirstMeasure = (index == 0)
            var state = MusicXMLMeasureState(
                measureIndex: index, staffCount: staffCount, options: options, partIndex: partIndex,
                registry: registry,
            )
            state.octaveShifts = octaveShifts.table
            state.measureStart = octaveShifts.measureStarts.indices.contains(index)
                ? octaveShifts.measureStarts[index] : .zeroTick
            state.inferredLines = inferredLines
            state.partTick = partTick
            let built = try decodeOne(
                measureNode: measureNode,
                state: &state,
                divisions: &divisions,
                previousAttributes: &previousAttributes,
                isFirstMeasure: isFirstMeasure,
                drumTable: drumTable,
                glideTracker: &glideTracker,
                directionEvents: &directionEvents,
            )
            tempoElements.append(state.tempoElements)
            let length = measureLength(state, attributes: previousAttributes)
            measureLengths.append(length)
            inferredLines = state.inferredLines
            partTick += length
            for (staffIdx, item) in built.enumerated() {
                perStaffMeasures[staffIdx].append(item.measure)
                perStaffSystemElements[staffIdx].append(item.systemElements)
                anchors[staffIdx].append(item.anchors)
            }
        }
        var withGlides = applyGlides(attachments: glideTracker.attachments, measures: perStaffMeasures)
        // Spanner starts and stops pair part-wide once the part is walked, and the inferred lines close at their ends
        // (`P2:2307-2314`); their begin sides and end markers join the queue after the direction's other voice
        // elements, in the pairing's order.
        let spanners = spannerEvents(directionEvents, inferredLines: inferredLines, measureLengths: measureLengths)
        MusicXMLDirectionSplicer.apply(directionEvents + spanners, anchors: anchors, to: &withGlides)
        let dropped = dropUnmatchedTies(withGlides)
        return PartResult(
            staffCount: staffCount,
            measuresByStaff: dropped,
            systemElementsByStaffMeasure: perStaffSystemElements,
            lineCountByStaff: previousAttributes.lineCountByStaff,
            tempoElementsByMeasure: tempoElements,
        )
    }

    /// The part's spanners, paired and closed, as begin sides and end markers in the pairing's order.
    private static func spannerEvents(
        _ events: [MusicXMLDirectionEvent], inferredLines: MusicXMLInferredLineLog, measureLengths: [Fraction],
    ) -> [MusicXMLDirectionEvent] {
        MusicXMLSpannerPairing.ordered(
            MusicXMLSpannerPairing.pairClosed(events, measureLengths: measureLengths)
                + inferredLines.finished(measureLengths: measureLengths),
        )
    }

    /// Mutate the start chord's first note for each resolved glissando /
    /// slide attachment. Unmatched stops never produce an attachment, so
    /// the loop here only sees fully-paired events. Indices are validated
    /// defensively — out-of-range entries (impossible under well-formed
    /// input, but cheap insurance) silently drop.
    private static func applyGlides(
        attachments: [MusicXMLGlideTracker.StartLocation],
        measures: [[Measure]],
    ) -> [[Measure]] {
        var result = measures
        for attach in attachments {
            guard attach.staffIndex < result.count else { continue }
            guard attach.measureIndex < result[attach.staffIndex].count else { continue }
            var measure = result[attach.staffIndex][attach.measureIndex]
            guard attach.voiceIndex < measure.voices.count else { continue }
            var voice = measure.voices[attach.voiceIndex]
            guard attach.elementIndex < voice.elements.count else { continue }
            guard case var .chord(chord) = voice.elements[attach.elementIndex] else {
                continue
            }
            guard !chord.notes.isEmpty else { continue }
            chord.notes.updateNote(at: 0) { $0.glissando = attach.glissando }
            voice.elements.updateValue(at: attach.elementIndex) { $0 = .chord(chord) }
            measure.voices[attach.voiceIndex] = voice
            result[attach.staffIndex][attach.measureIndex] = measure
        }
        return result
    }

    /// Remove ties that don't connect to the **immediately following** chord
    /// of the same voice and pitch. MuseScore's MusicXML importer requires
    /// the successor note to be both the next chord in the voice and carry
    /// a matching `tieBack`; ties that jump over intervening notes (e.g.
    /// `testUnterminatedTies`'s stray starts) are silently dropped.
    private static func dropUnmatchedTies(_ perStaff: [[Measure]]) -> [[Measure]] {
        perStaff.map { TieValidator.process($0) }
    }

    /// Scan the part for the first `<attributes><staves>N</staves>` and return
    /// `N`. Defaults to 1. Most piano parts declare `<staves>2</staves>` in the
    /// first measure's attributes.
    static func detectStaffCount(partNode: XMLTreeNode) -> Int {
        for measure in partNode.all("measure") {
            for attrs in measure.all("attributes") {
                if let stavesText = attrs.first("staves")?.text,
                   let staves = Int(stavesText), staves >= 1
                {
                    return staves
                }
            }
        }
        return 1
    }

    /// Decode a single `<measure>`. Returns `staffCount` `Measure` values —
    /// one per staff. Attributes and barlines broadcast to every staff;
    /// `<note>` elements go to the staff selected by `<staff>N</staff>`
    /// (default 1).
    private static func decodeOne(
        measureNode: XMLTreeNode,
        state: inout MusicXMLMeasureState,
        divisions: inout DivisionsContext,
        previousAttributes: inout MusicXMLAttributesSnapshot,
        isFirstMeasure: Bool,
        drumTable: MusicXMLDrumTable,
        glideTracker: inout MusicXMLGlideTracker,
        directionEvents: inout [MusicXMLDirectionEvent],
    ) throws -> [StaffMeasureBuilder.Built] {
        let staffCount = state.staffCount
        for child in measureNode.children {
            switch child.name {
            case "attributes":
                let emitted = AttributesDecoder.decode(
                    node: child,
                    divisions: &divisions,
                    previous: &previousAttributes,
                    isFirstMeasure: isFirstMeasure,
                    staffCount: staffCount,
                )
                for emission in emitted {
                    if let idx = emission.staffIndex {
                        state.builders[idx].appendAttribute(emission.element)
                    } else {
                        for builder in state.builders.indices {
                            state.builders[builder].appendAttribute(emission.element)
                        }
                    }
                }

            case "note":
                placePendingSoundTempo(state: &state)
                try decodeNoteChild(
                    child, state: &state, divisions: divisions, drumTable: drumTable, glideTracker: &glideTracker,
                )

            case "direction":
                decodeDirectionChild(child, state: &state, divisions: divisions)

            case "backup", "forward":
                moveClock(child, state: &state, divisions: divisions)

            case "barline":
                decodeBarlineChild(child, state: &state)

            case "sound":
                decodeSoundChild(child, state: &state)

            default:
                // <print>, ... — out of Phase 0 scope.
                continue
            }
        }

        // The measure's delayed directions join the score now (`P2:2984-2990`).
        state.registry.registry.endMeasure()
        directionEvents += state.directionEvents
        return state.builders.map { $0.build() }
    }
}

// `StaffMeasureBuilder` lives in `StaffMeasureBuilder.swift` next to this
// file.
