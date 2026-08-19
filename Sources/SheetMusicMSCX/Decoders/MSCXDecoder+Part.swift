import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Part {
    /// Decode the per-`<Part>` declaration. Top-level `<Staff>` measures
    /// are paired in afterwards by `assembleParts`.
    /// `fallbackIndex` (1-based) is the position of this `<Part>` in
    /// document order; it backstops missing/empty `id` attributes
    /// with a sequential integer so the decoded `Part.id` is always
    /// non-empty (matches the encoder's id-synthesis convention).
    static func decodePairing(
        _ node: XMLTreeNode, fallbackIndex: Int,
    ) throws -> MSCXStaffPairing {
        let raw = node.attributes["id"] ?? ""
        let id = raw.isEmpty ? String(fallbackIndex) : raw
        let declared = node.all("Staff").map { Staff.declared($0) }
        guard let instrNode = node.first("Instrument") else {
            throw SheetMusicError.malformedScore(reason: "Part missing <Instrument>")
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
        )
    }
}
