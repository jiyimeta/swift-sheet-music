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

    static func decode(partNode: XMLTreeNode) throws -> PartResult {
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
                staffCount: staffCount
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
                   let staves = Int(stavesText), staves >= 1 {
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
        staffCount: Int
    ) throws -> [Measure] {
        var perStaff: [StaffMeasureBuilder] = (0..<staffCount).map { _ in
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
                    existingVoiceElements: existing
                )
                switch decoded {
                case let .foldIntoLastChord(note, duration):
                    perStaff[staffIdx].foldIntoLastChord(
                        voice: voice,
                        note: note,
                        duration: duration
                    )
                case let .new(voiceElement):
                    perStaff[staffIdx].append(voiceElement, toVoice: voice)
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

/// Accumulator for one staff's measure. Collects per-voice element buckets
/// where the "voice" key is an MSCX-style index derived from first-seen
/// MusicXML voice ids. MusicXML assigns global voice ids within a part
/// (e.g. 1 for right hand, 5 for left hand); MSCX uses positional voices
/// per `<voice>` block inside a measure. When a staff has only one
/// MusicXML voice id, everything — including attributes and barlines —
/// ends up in a single MSCX voice. Attributes always land in the first
/// voice index.
private struct StaffMeasureBuilder {
    /// Index of each MusicXML voice id (first-seen order).
    private var voiceIndex: [String: Int] = [:]
    private var voices: [[VoiceElement]] = []
    private var defaultVoiceId: String?
    private var startRepeat = false
    private var endRepeatCount: Int?
    private var trailingBarline: BarLine?

    /// Append to the first voice index (MSCX attributes convention). Lazily
    /// creates the voice 0 bucket if no notes have been seen yet.
    mutating func appendAttribute(_ element: VoiceElement) {
        ensureFirstVoice()
        voices[0].append(element)
    }

    mutating func setDefaultVoice(_ voiceId: String) {
        defaultVoiceId = voiceId
    }

    /// Append a note-sourced element under the MSCX index corresponding to
    /// this MusicXML voice id.
    mutating func append(_ element: VoiceElement, toVoice voiceId: String) {
        let idx = internVoice(voiceId)
        voices[idx].append(element)
    }

    func elements(forVoice voiceId: String) -> [VoiceElement] {
        guard let idx = voiceIndex[voiceId] else { return [] }
        return voices[idx]
    }

    mutating func foldIntoLastChord(voice voiceId: String, note: Note, duration: NoteDuration) {
        let idx = internVoice(voiceId)
        var elements = voices[idx]
        if let last = elements.last, case .chord(var chord) = last {
            chord.notes.append(note)
            elements[elements.count - 1] = .chord(chord)
        } else {
            elements.append(.chord(Chord(duration: duration, notes: [note])))
        }
        voices[idx] = elements
    }

    mutating func apply(barline: MusicXMLBarlineDecoder.Decoded) {
        switch barline.placement {
        case .start:
            if barline.startRepeat { startRepeat = true }
            if let line = barline.inline {
                appendToDefaultVoice(.barLine(line))
            }
        case .middle:
            if let line = barline.inline {
                appendToDefaultVoice(.barLine(line))
            }
        case .end:
            if let count = barline.endRepeatCount { endRepeatCount = count }
            if let line = barline.inline { trailingBarline = line }
        }
    }

    func build() -> Measure {
        var final = voices
        if let trailing = trailingBarline {
            if final.isEmpty {
                final.append([])
            }
            let targetIdx: Int
            if let id = defaultVoiceId, let idx = voiceIndex[id] {
                targetIdx = idx
            } else {
                targetIdx = 0
            }
            final[targetIdx].append(.barLine(trailing))
        }
        let builtVoices = final.isEmpty ? [Voice(elements: [])] : final.map(Voice.init)
        return Measure(
            voices: builtVoices,
            startRepeat: startRepeat,
            endRepeatCount: endRepeatCount
        )
    }

    // MARK: - private helpers

    private mutating func ensureFirstVoice() {
        if voices.isEmpty {
            voices.append([])
            voiceIndex["__implicit__"] = 0
        }
    }

    private mutating func internVoice(_ voiceId: String) -> Int {
        if let idx = voiceIndex[voiceId] { return idx }
        // If we seeded voice 0 with attributes only and this is the first real
        // voice, adopt that slot instead of creating a new one.
        if voices.count == 1, voiceIndex.values.first == 0,
           voiceIndex["__implicit__"] != nil, voiceIndex.count == 1 {
            voiceIndex.removeValue(forKey: "__implicit__")
            voiceIndex[voiceId] = 0
            return 0
        }
        let idx = voices.count
        voices.append([])
        voiceIndex[voiceId] = idx
        return idx
    }

    private mutating func appendToDefaultVoice(_ element: VoiceElement) {
        if let id = defaultVoiceId {
            append(element, toVoice: id)
        } else {
            appendAttribute(element)
        }
    }
}
