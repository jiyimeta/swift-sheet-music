import Foundation
import SheetMusicCore
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
    }

    static func decode(
        partNode: XMLTreeNode,
        drumTable: MusicXMLDrumTable = MusicXMLDrumTable(),
    ) throws -> PartResult {
        let staffCount = detectStaffCount(partNode: partNode)
        var divisions = DivisionsContext(perQuarter: 1)
        var previousAttributes = MusicXMLAttributesSnapshot()
        var perStaffMeasures: [[Measure]] = Array(repeating: [], count: staffCount)
        var perStaffSystemElements: [[[PositionedSystemElement]]] = Array(
            repeating: [],
            count: staffCount,
        )
        // Glissando / slide events span notes (and possibly measures)
        // within a part; the tracker accumulates pending starts and
        // resolved attachments across the full per-part walk, then
        // attachments are applied after measures are built. Scope is
        // strictly per-part — no cross-part state leaks because the
        // tracker is a fresh local here.
        var glideTracker = MusicXMLGlideTracker()
        for (index, measureNode) in partNode.all("measure").enumerated() {
            let isFirstMeasure = (index == 0)
            let built = try decodeOne(
                measureNode: measureNode,
                divisions: &divisions,
                previousAttributes: &previousAttributes,
                isFirstMeasure: isFirstMeasure,
                staffCount: staffCount,
                drumTable: drumTable,
                measureIndex: index,
                glideTracker: &glideTracker,
            )
            for (staffIdx, item) in built.enumerated() {
                perStaffMeasures[staffIdx].append(item.measure)
                perStaffSystemElements[staffIdx].append(item.systemElements)
            }
        }
        let withGlides = applyGlides(
            attachments: glideTracker.attachments,
            measures: perStaffMeasures,
        )
        let dropped = dropUnmatchedTies(withGlides)
        return PartResult(
            staffCount: staffCount,
            measuresByStaff: dropped,
            systemElementsByStaffMeasure: perStaffSystemElements,
            lineCountByStaff: previousAttributes.lineCountByStaff,
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
            chord.notes[0].glissando = attach.glissando
            voice.elements[attach.elementIndex] = .chord(chord)
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
    private static func detectStaffCount(partNode: XMLTreeNode) -> Int {
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
    private static func decodeOne( // swiftlint:disable:this function_body_length
        measureNode: XMLTreeNode,
        divisions: inout DivisionsContext,
        previousAttributes: inout MusicXMLAttributesSnapshot,
        isFirstMeasure: Bool,
        staffCount: Int,
        drumTable: MusicXMLDrumTable,
        measureIndex: Int,
        glideTracker: inout MusicXMLGlideTracker,
    ) throws -> [StaffMeasureBuilder.Built] {
        var perStaff: [StaffMeasureBuilder] = (0 ..< staffCount).map { _ in
            StaffMeasureBuilder()
        }

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
                        perStaff[idx].appendAttribute(emission.element)
                    } else {
                        for builder in perStaff.indices {
                            perStaff[builder].appendAttribute(emission.element)
                        }
                    }
                }

            case "note":
                let staffIdx = noteStaffIndex(child, staffCount: staffCount)
                let voice = child.first("voice")?.text ?? "1"
                perStaff[staffIdx].setDefaultVoice(voice)
                let existing = perStaff[staffIdx].elements(forVoice: voice)
                let decoded = try MusicXMLNoteDecoder.decodeNote(
                    node: child,
                    divisions: divisions,
                    existingVoiceElements: existing,
                    drumTable: drumTable,
                )
                switch decoded {
                case let .foldIntoLastChord(note, duration, trailingBreaths):
                    perStaff[staffIdx].foldIntoLastChord(
                        voice: voice,
                        note: note,
                        duration: duration,
                    )
                    // Breath marks / caesuras on a chord-folded note still
                    // belong after the host chord, which is the same chord
                    // we just merged into.
                    for breath in trailingBreaths {
                        perStaff[staffIdx].append(.breath(breath), toVoice: voice)
                    }
                case let .new(elements):
                    for element in elements {
                        perStaff[staffIdx].append(element, toVoice: voice)
                    }
                }
                // Glissando / slide events on this note: record the
                // chord's voice + index now (after append) so the
                // post-walk pass can mutate the start chord in place.
                // For fold-into-chord notes, the chord index didn't
                // change — `count - 1` still points at the same chord.
                if let voiceIdx = perStaff[staffIdx].voicePositionIndex(forVoice: voice) {
                    let elements = perStaff[staffIdx].elements(forVoice: voice)
                    let chordIdx = elements.count - 1
                    if chordIdx >= 0 {
                        glideTracker.consume(
                            noteNode: child,
                            staffIndex: staffIdx,
                            measureIndex: measureIndex,
                            voiceIndex: voiceIdx,
                            chordElementIndex: chordIdx,
                        )
                    }
                }

            case "direction":
                // MuseScore attaches measure-level jumps/markers to the
                // first staff only, matching the .mscx layout where they
                // live on `<Staff id="1">`'s `<Measure>`.
                let navigation = MusicXMLJumpDecoder.decode(child)
                if !perStaff.isEmpty {
                    perStaff[0].addMarkers(navigation.markers)
                    perStaff[0].addJumps(navigation.jumps)
                }
                // Rehearsal marks ride on the same `<direction>` element
                // as a `<direction-type><rehearsal>` child. Attach to
                // staff 0 so they match the MSCX `RehearsalMark` shape
                // (system-flagged, drawn once above the top staff).
                let rehearsals = MusicXMLRehearsalDecoder.decode(child)
                if !perStaff.isEmpty {
                    for mark in rehearsals {
                        perStaff[0].addRehearsalMark(mark)
                    }
                }

            case "backup", "forward":
                // For Phase 0 we rely on document order + <voice>/<staff> tags
                // rather than tick arithmetic. MuseScore's pass2 maintains a
                // per-voice cursor for more complex layouts — deferred until
                // a fixture requires it.
                continue

            case "barline":
                let decoded = MusicXMLBarlineDecoder.decode(child)
                for builder in perStaff.indices {
                    perStaff[builder].apply(barline: decoded)
                }

            default:
                // <print>, <direction>, <sound>, ... — out of Phase 0 scope.
                continue
            }
        }

        return perStaff.map { $0.build() }
    }

    /// Read `<note><staff>N</staff>` and convert to a 0-based staff index.
    /// Defaults to 0 when absent or out of range.
    private static func noteStaffIndex(_ note: XMLTreeNode, staffCount: Int) -> Int {
        guard let text = note.first("staff")?.text, let n = Int(text), n >= 1 else {
            return 0
        }
        return min(n - 1, staffCount - 1)
    }
}

// `StaffMeasureBuilder` lives in `StaffMeasureBuilder.swift` next to this
// file.
