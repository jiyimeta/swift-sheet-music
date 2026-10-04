import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Clef {
    private static let consumedClefChildren: Set = [
        "color", "concertClefType", "offset", "autoplace", "placement", "transposingClefType", "visible",
    ]

    /// A `<transposingClefType>` equal to the concert type says no more than an absent one, and the model keeps `nil`
    /// for "the same in both views": MuseScore names both on every clef and the encoder now does too, so without
    /// this a clef folino created (`nil`) would come back from its own file as a different value.
    static func decode(_ node: XMLTreeNode) throws -> Clef {
        let concert = node.first("concertClefType")?.text ?? "G"
        let transposing = (node.first("transposingClefType")?.text).flatMap { $0 == concert ? nil : $0 }
        var clef = Clef(
            concertClefType: concert,
            transposingClefType: transposing,
            preservedMarkup: node.preservedMarkup(consuming: consumedClefChildren),
        )
        clef.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return clef
    }
}
