import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Part {
    /// Decode the per-`<Part>` declaration. Top-level `<Staff>` measures
    /// are paired in afterwards by `assembleParts`.
    static func decodePairing(_ node: XMLTreeNode) throws -> MSCXStaffPairing {
        let id = node.attributes["id"] ?? ""
        let declared = node.all("Staff").map { Staff.declared($0) }
        guard let instrNode = node.first("Instrument") else {
            throw SheetMusicError.malformedScore(reason: "Part missing <Instrument>")
        }
        let instrument = try Instrument.decode(instrNode)
        return MSCXStaffPairing(
            partID: id,
            trackName: node.first("trackName")?.text,
            instrument: instrument,
            declared: declared
        )
    }
}
