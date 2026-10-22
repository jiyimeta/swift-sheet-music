import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Score {
    /// Decode a parsed MusicXML root node into a `Score`.
    /// Rejects `<score-timewise>` with an explicit error; the rest of the
    /// library assumes the partwise layout.
    static func decodeMusicXML(_ root: XMLTreeNode, options: MusicXMLImportOptions = .default) throws -> Score {
        switch root.name {
        case "score-partwise":
            break
        case "score-timewise":
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "musicxml.root.unsupportedTimewise",
                    message: "MusicXML: unsupported <score-timewise> variant",
                    location: "score-timewise",
                ),
            )
        default:
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "musicxml.root.missingScorePartwise",
                    message: "MusicXML: <score-partwise> root element not found",
                ),
            )
        }

        let metaTags = decodeMetaTags(root)

        guard let partList = root.first("part-list") else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "musicxml.partList.missing",
                    message: "MusicXML: <part-list> is required",
                    location: "part-list",
                ),
            )
        }
        // The exporter, which a few readings bend for (`MusicXMLExporterSoftware`).
        let software = MusicXMLExporterSoftware.detect(root: root)
        let (parts, systemMeasures) = try decodeParts(
            root: root, partList: partList, options: options, software: software,
        )

        // Hard-code division = 480 ticks per quarter, matching MuseScore's default
        // and the `*_ref.mscx` fixtures we semantic-compare against. MusicXML's
        // own `<divisions>` is part-local and would vary per fixture.
        var score = Score(
            division: 480,
            parts: IdentifiedArray(parts),
            systemMeasures: IdentifiedArray(systemMeasures),
            metaTags: metaTags,
            source: .musicXML,
        )
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        return score
    }

    /// MusicXML carries metadata in `<work>`, `<identification>`, and `<credit>`.
    /// We surface the stable fields that map directly to MuseScore's `metaTag`
    /// names: `workTitle`, `workNumber`, `movementTitle`, `movementNumber`,
    /// `composer`, `lyricist`, `arranger`, `copyright`, `source`, `translator`.
    /// Credit-geometry inference is explicitly out of scope.
    private static func decodeMetaTags(_ root: XMLTreeNode) -> [String: String] {
        var tags: [String: String] = [:]
        if let work = root.first("work") {
            if let title = work.first("work-title")?.text, !title.isEmpty {
                tags["workTitle"] = title
            }
            if let number = work.first("work-number")?.text, !number.isEmpty {
                tags["workNumber"] = number
            }
        }
        if let title = root.first("movement-title")?.text, !title.isEmpty {
            tags["movementTitle"] = title
        }
        if let number = root.first("movement-number")?.text, !number.isEmpty {
            tags["movementNumber"] = number
        }
        if let id = root.first("identification") {
            for creator in id.all("creator") {
                let type = creator.attributes["type"] ?? "composer"
                let value = creator.text
                guard !value.isEmpty else { continue }
                switch type {
                case "composer", "lyricist", "arranger":
                    tags[type] = value
                default:
                    // Unknown creator types (e.g. "editor") are out of seed scope.
                    continue
                }
            }
            let rights = id.all("rights")
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !rights.isEmpty {
                tags["copyright"] = rights
            }
            // `<encoding><encoder>` is MuseScore's `encoder` meta tag, the last one winning (`P1:1526-1530`).
            for encoder in id.all("encoding").flatMap({ $0.all("encoder") }) where !encoder.text.isEmpty {
                tags["encoder"] = encoder.text
            }
            if let source = id.first("source")?.text, !source.isEmpty {
                tags["source"] = source
            }
            if let misc = id.first("miscellaneous") {
                for field in misc.all("miscellaneous-field") {
                    guard let key = field.attributes["name"], !key.isEmpty else { continue }
                    let value = field.text
                    guard !value.isEmpty else { continue }
                    tags[key] = value
                }
            }
        }
        return tags
    }

    /// Walk the top-level `<part>` elements, detect per-part staff count from
    /// the first `<attributes><staves>`, and build `Part` with its `Staff`
    /// measures populated inline. One `Part` per `<part>`; one `Staff` per
    /// staff (so a piano part produces a `Part` with 2 `Staff`s).
    private static func decodeParts(
        root: XMLTreeNode,
        partList: XMLTreeNode,
        options: MusicXMLImportOptions,
        software: MusicXMLExporterSoftware,
    ) throws -> (parts: [Part], systemMeasures: [SystemMeasure]) {
        let scoreParts = partList.all("score-part")
        var parts: [Part] = []
        // Per-staff per-measure system elements paired with the
        // resolved StaffAddress, merged into score.systemMeasures at
        // the end so every staff's contribution lands at the right
        // measure index with originalStaff stamped.
        var perStaffSystemElements: [(address: StaffAddress, perMeasure: [[PositionedSystemElement]])] = []
        // One tempo registry for the whole score, as MuseScore reads the score's segments: a tempo any part placed
        // blocks the next on that tick.
        let tempoRegistry = MusicXMLTempoRegistryBox()
        let partGroups = MusicXMLPartGroups(partList: partList)
        for (index, partNode) in root.all("part").enumerated() {
            let (part, staffElements) = try decodeOnePart(
                partNode: partNode,
                scoreParts: scoreParts,
                partGroups: partGroups,
                index: index,
                partIndex: parts.count,
                options: options,
                software: software,
                tempoRegistry: tempoRegistry,
            )
            parts.append(part)
            perStaffSystemElements.append(contentsOf: staffElements)
        }
        let measureCount = perStaffSystemElements
            .map(\.perMeasure.count)
            .max() ?? 0
        var laneElements = Array(
            repeating: [PositionedSystemElement](),
            count: measureCount,
        )
        for entry in perStaffSystemElements {
            for (measureIndex, elements) in entry.perMeasure.enumerated() {
                guard measureIndex < laneElements.count else { continue }
                for var element in elements {
                    element.originalStaff = entry.address
                    laneElements[measureIndex].append(element)
                }
            }
        }
        let lanes = laneElements.map { SystemMeasure(elements: laneOrdered($0)) }
        // MuseScore numbers an implicit brace's column `bracketLevels + 1`, which leaves column 0 empty; it draws an
        // empty column at no width, where ssm's gutter gives every column up to the highest one a spatium.
        let compacted = Score.canonicalizingBracketColumns(addingFinalBarLines(parts))
        return (parts: compacted, systemMeasures: lanes)
    }

    /// A measure's lane in the order the MSCX reader builds it from a MuseScore file (`MSCXDecoder+Staff`'s assembly:
    /// staff by staff, then a stable sort by position): by position, then by staff (`originalStaff`, top first; none
    /// counts as the top staff), and within one staff and position its own texts before the system elements — a
    /// rehearsal mark, a tempo, a system text — which MuseScore holds back and adds once the whole score is read
    /// (`addElemOffset` → `addSystemElement`, `P2:1040-1072`; added at `P2:2122`). Otherwise as decoded.
    static func laneOrdered(_ elements: [PositionedSystemElement]) -> [PositionedSystemElement] {
        func isSystem(_ entry: PositionedSystemElement) -> Bool {
            switch entry.element {
            case .rehearsalMark, .tempo: true
            case let .staffText(text): text.isSystemText
            default: false
            }
        }
        func staff(_ entry: PositionedSystemElement) -> (Int, Int) {
            (entry.originalStaff?.partIndex ?? 0, entry.originalStaff?.staffIndexInPart ?? 0)
        }
        return elements.enumerated().sorted { lhs, rhs in
            if lhs.element.position != rhs.element.position { return lhs.element.position < rhs.element.position }
            let (leftStaff, rightStaff) = (staff(lhs.element), staff(rhs.element))
            if leftStaff != rightStaff { return leftStaff < rightStaff }
            let (left, right) = (isSystem(lhs.element), isSystem(rhs.element))
            return left == right ? lhs.offset < rhs.offset : right
        }.map(\.element)
    }

    /// MuseScore sets the last measure's bar line to normal "or MuseScore will generate light-heavy EndBarline"
    /// (`P2:2109-2118`): when the score's first staff ends its last measure with a normal bar line — no styled bar
    /// line, no end repeat — every staff's last measure gets an explicit untyped `BarLine` at its end, in voice 0. A
    /// `bar-style` of `none` is not told apart from no bar line here.
    static func addingFinalBarLines(_ parts: [Part]) -> [Part] {
        guard let first = parts.first?.staves.first?.measures.last, endsWithImplicitBarLine(first) else { return parts }
        return parts.map { part in
            var copy = part
            copy.staves.mapValues { staff in
                var changed = staff
                guard let last = changed.measures.indices.last, !changed.measures[last].voices.isEmpty
                else { return staff }
                // The slots are not identified yet (`assignMissingIDs` runs after), so rebuilding loses nothing.
                let elements = changed.measures[last].voices[0].elements.values + [.barLine(BarLine())]
                changed.measures[last].voices[0].elements = IdentifiedArray(elements)
                return changed
            }
            return copy
        }
    }

    /// No end repeat, and no voice holds a bar line after its last chord or rest (an end marker may follow one).
    private static func endsWithImplicitBarLine(_ measure: Measure) -> Bool {
        guard measure.endRepeatCount == nil else { return false }
        return !measure.voices.contains { voice in
            let elements = voice.elements.values
            let lastChord = elements.lastIndex { if case .chord = $0 { true } else { false } } ?? -1
            return elements[(lastChord + 1)...].contains { if case .barLine = $0 { true } else { false } }
        }
    }

    /// Decode a single top-level `<part>` into its `Part` plus the
    /// per-staff system elements it contributes (rehearsal marks and the
    /// like, one entry per real staff, and mid-score instrument changes
    /// lifted onto staff 0 — see `MusicXMLInstrumentChangeDecoder`).
    /// Split out of `decodeParts` to keep that function's loop body short.
    private static func decodeOnePart(
        partNode: XMLTreeNode,
        scoreParts: [XMLTreeNode],
        partGroups: MusicXMLPartGroups,
        index: Int,
        partIndex: Int,
        options: MusicXMLImportOptions,
        software: MusicXMLExporterSoftware,
        tempoRegistry: MusicXMLTempoRegistryBox,
    ) throws -> (part: Part, staffElements: [(address: StaffAddress, perMeasure: [[PositionedSystemElement]])]) {
        let id = partNode.attributes["id"] ?? ""
        guard let scorePart = scoreParts.first(where: { $0.attributes["id"] == id })
            ?? (index < scoreParts.count ? scoreParts[index] : nil)
        else {
            throw SheetMusicError.malformedScore(
                ScoreFault(
                    code: "musicxml.part.missingScorePart",
                    message: "MusicXML: <part id='\(id)'> has no matching <score-part>",
                    location: id,
                ),
            )
        }
        // Build the percussion table from the score-part header BEFORE
        // walking measures — the walker must hand it to the note decoder
        // so <unpitched> notes resolve to GM drum pitches.
        let prelimDrumTable = MusicXMLDrumTable.build(scorePart: scorePart)
        let walker = try MusicXMLMeasureWalker.decode(
            partNode: partNode,
            drumTable: prelimDrumTable,
            options: options,
            partIndex: partIndex,
            registry: tempoRegistry,
            software: software,
            isVocalStaff: MusicXMLVocalStaff.isVocal(scorePart: scorePart),
        )
        let (partTemplate, _, instrumentByID) = try Part.decodeMusicXML(
            scorePart: scorePart,
            partId: id,
            staffCount: walker.staffCount,
        )
        let listIndex = scoreParts.firstIndex { $0.attributes["id"] == id } ?? index
        var instrument = partTemplate.instrument
        if instrument.useDrumset {
            instrument.drumset = walker.drumKit.drumset(table: prelimDrumTable)
        }
        let populatedStaves = staves(
            of: walker, braceColumn: partGroups.impliedBraceColumn(
                partIndex: listIndex, staffCount: walker.measuresByStaff.count,
            ),
            isDrumset: instrument.useDrumset,
        )
        let part = Part(
            id: partTemplate.id,
            trackName: partTemplate.trackName,
            instrument: instrument,
            staves: IdentifiedArray(populatedStaves),
        )
        var staffElements: [(address: StaffAddress, perMeasure: [[PositionedSystemElement]])] = []
        for (staffIndex, perMeasure) in walker.systemElementsByStaffMeasure.enumerated() {
            let address = StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex)
            staffElements.append((address, perMeasure))
        }
        // Mid-score instrument changes have no per-staff home in
        // MusicXML (they're a part-wide playback concept) — lift them
        // onto staff 0.
        let instrumentChangesByMeasure = MusicXMLInstrumentChangeDecoder.decode(
            partNode: partNode,
            instrumentByID: instrumentByID,
            seedInstrumentID: scorePart.first("score-instrument")?.attributes["id"],
        )
        staffElements.append((
            StaffAddress(partIndex: partIndex, staffIndexInPart: 0),
            instrumentChangesByMeasure,
        ))
        // Tempo markings belong to the score's top staff whatever part wrote them (`addElemOffset`, "TempoText must
        // be in track 0").
        staffElements.append((StaffAddress(partIndex: 0, staffIndexInPart: 0), walker.tempoElementsByMeasure))
        return (part, staffElements)
    }

    /// The part's staves, replacing the placeholder empty-measure ones. This is the ONLY place `lineCount` is decided
    /// for a MusicXML part: `partTemplate.staves` is discarded wholesale, so the walker's per-staff table is read here
    /// and nowhere else. A multi-staff part's first staff carries MuseScore's implicit brace (`MusicXMLPartGroups`).
    /// A drum part's five-line staves are percussion staves, as `setStaffTypePercussion` makes them: a saved drum staff
    /// left `stdNormal` makes MuseScore ignore the kit's lines.
    private static func staves(
        of walker: MusicXMLMeasureWalker.PartResult, braceColumn: Int?, isDrumset: Bool,
    ) -> [Staff] {
        var staves = walker.measuresByStaff
            .enumerated()
            .map { staffIndex, staffMeasures in
                let lineCount = walker.lineCountByStaff[staffIndex] ?? 5
                let isPercussion = isDrumset && lineCount == 5
                return Staff(
                    staffType: isPercussion ? GMPercussion.staffTypeName : "stdNormal",
                    group: isPercussion ? GMPercussion.staffGroup : "pitched",
                    lineCount: lineCount,
                    defaultClefType: nil, measures: staffMeasures,
                )
            }
        if let braceColumn, !staves.isEmpty {
            staves[0].brackets = [BracketItem(type: .brace, span: staves.count, column: braceColumn)]
        }
        return staves
    }
}
