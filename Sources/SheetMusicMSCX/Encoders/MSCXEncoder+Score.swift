import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Score {
    /// Build the `<museScore><Score>…</Score></museScore>` root.
    func encode(options: MSCXEncoderOptions = .init()) throws -> XMLTreeNode {
        var scoreChildren: [XMLTreeNode] = Self.layerHeader(options: options)
        scoreChildren.append(XMLTreeNode(
            name: "Division", text: String(division),
        ))
        scoreChildren.append(style.encode(options: options))
        scoreChildren.append(contentsOf: Self.showFlags(options: options))
        scoreChildren.append(contentsOf: encodedMetaTags(options: options))

        // Synthesize sequential 1-based integer IDs for parts and
        // staves. MuseScore Studio's loader expects numeric IDs and
        // refuses (or crashes on) tokens like "P0" / "P0-0" that
        // hand-built `Score` values often carry. The decoder pairs
        // declarations with bodies by string equality, so any
        // consistent scheme round-trips; sequential integers also
        // match MuseScore's own writer output.
        var allStaffIDs: [(part: Part, partID: String, ids: [String])] = []
        var nextStaffID = 1
        for (partIndex, part) in parts.enumerated() {
            let partID = String(partIndex + 1)
            let ids = part.staves.indices.map { _ -> String in
                let id = String(nextStaffID)
                nextStaffID += 1
                return id
            }
            allStaffIDs.append((part, partID, ids))
        }
        for (part, partID, ids) in allStaffIDs {
            scoreChildren.append(
                part.encodeDeclaration(partID: partID, staffIDs: ids, options: options),
            )
        }
        try appendStaffBodies(
            allStaffIDs: allStaffIDs,
            into: &scoreChildren,
            options: options,
        )
        appendPreservedMarkup(preservedMarkup, to: &scoreChildren, options: options)

        let museScoreVersion: String
        // `.v2` is detection-only; MSCXEncoderOptions normalizes it to
        // `.v3` at init/assignment, but the switch still needs the
        // case to be exhaustive.
        switch options.targetVersion {
        case .v2, .v3: museScoreVersion = "3.02"
        case .v4: museScoreVersion = "4.60"
        }
        var rootChildren: [XMLTreeNode] = []
        if options.targetVersion == .v3 {
            rootChildren.append(XMLTreeNode(
                name: "programVersion", text: "3.6.2",
            ))
            rootChildren.append(XMLTreeNode(
                name: "programRevision", text: "3224f34",
            ))
        }
        rootChildren.append(XMLTreeNode(name: "Score", children: scoreChildren))
        return XMLTreeNode(
            name: "museScore",
            attributes: ["version": museScoreVersion],
            children: rootChildren,
        )
    }

    /// Per-measure system elements destined for a given staff,
    /// computed by filtering `systemMeasures` for entries whose
    /// `originalStaff` matches the address (with `nil` routed to
    /// the canonical staff 0, voice 0 per MuseScore convention).
    /// Returned shape: outer array has one entry per measure index;
    /// inner array is the elements for that measure of this staff.
    private func perMeasureSystemElements(
        for address: StaffAddress,
    ) -> [[PositionedSystemElement]] {
        let canonical = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        return systemMeasures.map { systemMeasure in
            systemMeasure.elements.filter { element in
                let original = element.originalStaff ?? canonical
                return original == address
            }
        }
    }

    /// Leading `<LayerTag>` / `<currentLayer>` pair MuseScore 3 expects
    /// before `<Division>`. Empty for v4.
    private static func layerHeader(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        guard options.targetVersion == .v3 else { return [] }
        return [
            XMLTreeNode(
                name: "LayerTag",
                attributes: ["id": "0", "tag": "default"],
            ),
            XMLTreeNode(name: "currentLayer", text: "0"),
        ]
    }

    /// Emit per-staff `<Staff id="N">` measure bodies. The first
    /// staff of the first part also receives the title `<VBox>`. Each
    /// staff also receives its per-measure effective durations so
    /// `.measure` rests can resolve against the prevailing
    /// TimeSignature × actualLength for that bar.
    private func appendStaffBodies(
        allStaffIDs: [(part: Part, partID: String, ids: [String])],
        into scoreChildren: inout [XMLTreeNode],
        options: MSCXEncoderOptions,
    ) throws {
        var titleFrameSlot = titleFrame
        for (partIndex, entry) in allStaffIDs.enumerated() {
            // The written notation is a per-part property, and everything below this point
            // (notes' `<tpc2>`, key signatures' `<accidental>`) needs it. Hand the measure
            // encoders a copy of the options carrying this part's offset; parts that don't
            // transpose keep the incoming 0 and so keep their existing output byte-for-byte.
            //
            // A drumset part is exempt. Its `<pitch>` is a kit slot, not a pitch on a line of fifths, and every
            // other stage already treats it that way — the renderer and the note-input path both skip drumset
            // parts. A hand-authored transposition on such a part would otherwise have the encoder emit `<tpc2>`
            // and shifted key accidentals for notation nothing displays that way. Defensive: the catalog gives no
            // drum kit a transposition, so this only fires on a file that arrived with one.
            var partOptions = options
            partOptions.writtenFifthsOffset = entry.part.instrument.useDrumset
                ? 0
                : entry.part.instrument.writtenFifthsOffset
            for (staffIndexInPart, pair) in zip(entry.part.staves, entry.ids).enumerated() {
                let staff = pair.0
                let id = pair.1
                let frame = titleFrameSlot
                titleFrameSlot = nil
                let address = StaffAddress(
                    partIndex: partIndex,
                    staffIndexInPart: staffIndexInPart,
                )
                let perMeasure = perMeasureSystemElements(for: address)
                try scoreChildren.append(
                    staff.encodeTopLevel(
                        staffID: id,
                        titleFrame: frame,
                        systemElementsByMeasure: perMeasure,
                        effectiveMeasureDurations: staff.measures.effectiveMeasureDurations(),
                        options: partOptions,
                    ),
                )
            }
        }
    }

    /// `<show*>` visibility flags MuseScore 3 emits after `<Style>`.
    /// Empty for v4.
    private static func showFlags(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        guard options.targetVersion == .v3 else { return [] }
        return [
            XMLTreeNode(name: "showInvisible", text: "1"),
            XMLTreeNode(name: "showUnprintable", text: "1"),
            XMLTreeNode(name: "showFrames", text: "1"),
            XMLTreeNode(name: "showMargins", text: "0"),
        ]
    }
}

extension Score {
    /// Emit `<metaTag>` children. v4 keeps the existing sorted-by-key
    /// emission; v3 emits the fixed 13-element canonical set MuseScore
    /// Studio expects, falling back to defaults for missing keys.
    private func encodedMetaTags(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        switch options.targetVersion {
        case .v4:
            metaTags.keys.sorted().map { key in
                XMLTreeNode(
                    name: "metaTag",
                    attributes: ["name": key],
                    text: metaTags[key] ?? "",
                )
            }
        case .v2, .v3:
            Self.canonicalMS3MetaTagNames.map { name in
                XMLTreeNode(
                    name: "metaTag",
                    attributes: ["name": name],
                    text: ms3MetaValue(for: name),
                )
            }
        }
    }

    private func ms3MetaValue(for name: String) -> String {
        if let supplied = metaTags[name], !supplied.isEmpty { return supplied }
        switch name {
        case "creationDate": return Self.todayISODate
        case "platform": return "Apple Macintosh"
        default: return ""
        }
    }

    fileprivate static let canonicalMS3MetaTagNames: [String] = [
        "arranger", "composer", "copyright", "creationDate",
        "lyricist", "movementNumber", "movementTitle", "platform",
        "poet", "source", "translator", "workNumber", "workTitle",
    ]

    fileprivate static var todayISODate: String {
        ISODate.fullDate(secondsSince1970: Date().timeIntervalSince1970)
    }
}
