import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Part {
    /// Every `<Part>` child this decoder reads. Anything else becomes
    /// preserved markup — see `PreservedXML`.
    private static let consumedPartChildren: Set = [
        "Instrument", "Staff", "hideStavesWhenIndividuallyEmpty", "hideWhenEmpty", "show", "trackName",
        EIDXML.childName,
    ]

    /// Decode the per-`<Part>` declaration. Top-level `<Staff>` measures
    /// are paired in afterwards by `assembleParts`.
    /// `fallbackIndex` (1-based) is the position of this `<Part>` in
    /// document order; it backstops missing/empty `id` attributes
    /// with a sequential integer so the decoded `Part.id` is always
    /// non-empty (matches the encoder's id-synthesis convention).
    /// `globalHideEmptyStaves` is the score's `ScoreStyle.hideEmptyStaves`, which turning a pre-4.60 file's staff
    /// hide modes into the part's settings consults (`HideWhenEmptyDecoding.resolveLegacy`).
    static func decodePairing(
        _ node: XMLTreeNode, fallbackIndex: Int, globalHideEmptyStaves: Bool = false,
    ) throws -> MSCXStaffPairing {
        let raw = node.attributes["id"] ?? ""
        let id = raw.isEmpty ? String(fallbackIndex) : raw
        let staffNodes = node.all("Staff")
        var declared = staffNodes.map { Staff.declared($0) }
        var hideWhenEmpty = AutoOnOff.auto
        var hideStavesWhenIndividuallyEmpty = false
        if HideWhenEmptyDecoding.isLegacy(formatRevision: MSCXParserContext.formatRevision) {
            // A pre-4.60 reader has no part-level tags (they would be unknown to it), only each staff's integer.
            let resolved = HideWhenEmptyDecoding.resolveLegacy(
                staffModes: staffNodes.map { HideWhenEmptyDecoding.legacyMode($0.first("hideWhenEmpty")?.text) },
                globalHideEmptyStaves: globalHideEmptyStaves,
            )
            hideWhenEmpty = resolved.part
            hideStavesWhenIndividuallyEmpty = resolved.individually
            for index in declared.indices {
                declared[index].staff.hideWhenEmpty = resolved.staves[index]
            }
        } else {
            // `rw/read460/tread.cpp:3611-3614`: the string form, and `readBool()` — a non-zero integer — for the flag.
            hideWhenEmpty = node.first("hideWhenEmpty").map { HideWhenEmptyDecoding.autoOnOff($0.text) } ?? .auto
            hideStavesWhenIndividuallyEmpty = node.first("hideStavesWhenIndividuallyEmpty")
                .map { (Int($0.text) ?? 0) != 0 } ?? false
        }
        guard let instrNode = node.first("Instrument") else {
            throw SheetMusicError.malformedScore(ScoreFault(
                code: "mscx.part.missingInstrument",
                message: "Part missing <Instrument>",
                location: id,
            ))
        }
        let instrument = try Instrument.decode(instrNode)
        // MuseScore `<Part><show>` — instrument visibility in the main score.
        // `<show>0</show>` hides every staff of this part; absent or any other
        // value (`1`) is visible. It sits as a direct child of `<Part>` in both
        // MS3 (id-less `<Part>`, `<Staff id="N">`) and MS4 (`<Part id="N">`,
        // id-less `<Staff>`), so this single read covers both shapes. `.text`
        // is already whitespace-trimmed by the XML parser.
        let isVisibleInScore = node.first("show")?.text != "0"
        return MSCXStaffPairing(
            partID: id,
            trackName: node.first("trackName")?.text,
            instrument: instrument,
            declared: declared,
            isVisibleInScore: isVisibleInScore,
            preservedMarkup: node.preservedMarkup(consuming: consumedPartChildren),
            eid: EIDXML.decode(from: node),
            hideWhenEmpty: hideWhenEmpty,
            hideStavesWhenIndividuallyEmpty: hideStavesWhenIndividuallyEmpty,
        )
    }
}
