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
    }

    static func decode(
        partNode: XMLTreeNode,
        drumTable: MusicXMLDrumTable = MusicXMLDrumTable()
    ) throws -> PartResult {
        let staffCount = detectStaffCount(partNode: partNode)
        var divisions = DivisionsContext(perQuarter: 1)
        var previousAttributes = MusicXMLAttributesSnapshot()
        var perStaffMeasures: [[Measure]] = Array(repeating: [], count: staffCount)
        for (index, measureNode) in partNode.all("measure").enumerated() {
            let isFirstMeasure = (index == 0)
            let measures = try decodeOne(
                measureNode: measureNode,
                divisions: &divisions,
                previousAttributes: &previousAttributes,
                isFirstMeasure: isFirstMeasure,
                staffCount: staffCount,
                drumTable: drumTable
            )
            for (staffIdx, measure) in measures.enumerated() {
                perStaffMeasures[staffIdx].append(measure)
            }
        }
        let dropped = dropUnmatchedTies(perStaffMeasures)
        return PartResult(staffCount: staffCount, measuresByStaff: dropped)
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

    // Decode a single `<measure>`. Returns `staffCount` `Measure` values —
    // one per staff. Attributes and barlines broadcast to every staff;
    // `<note>` elements go to the staff selected by `<staff>N</staff>`
    // (default 1).
    // swiftlint:disable function_body_length
    private static func decodeOne(
        measureNode: XMLTreeNode,
        divisions: inout DivisionsContext,
        previousAttributes: inout MusicXMLAttributesSnapshot,
        isFirstMeasure: Bool,
        staffCount: Int,
        drumTable: MusicXMLDrumTable
    ) throws -> [Measure] {
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
                    staffCount: staffCount
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
                    drumTable: drumTable
                )
                switch decoded {
                case let .foldIntoLastChord(note, duration):
                    perStaff[staffIdx].foldIntoLastChord(
                        voice: voice,
                        note: note,
                        duration: duration
                    )
                case let .new(elements):
                    for element in elements {
                        perStaff[staffIdx].append(element, toVoice: voice)
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

    // swiftlint:enable function_body_length

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
