import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Part {
    static func decode(_ node: XMLTreeNode) throws -> Part {
        // mscx files often omit the Part id attribute; fall back to "" rather than failing.
        let id = node.attributes["id"] ?? ""
        let staffDecls = try node.all("Staff").map { try StaffDeclaration.decode($0) }
        guard let instrNode = node.first("Instrument") else {
            throw SheetMusicError.malformedScore(reason: "Part missing <Instrument>")
        }
        let instrument = try Instrument.decode(instrNode)
        return Part(
            id: id,
            trackName: node.first("trackName")?.text,
            instrument: instrument,
            staffDeclarations: staffDecls
        )
    }
}
