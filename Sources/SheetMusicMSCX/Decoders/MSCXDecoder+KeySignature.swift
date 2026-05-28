import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension KeySignature {
    static func decode(_ node: XMLTreeNode) throws -> KeySignature {
        // Modern mscx uses <concertKey>; older forms use <accidental>.
        let concertKey: Int
        if let text = node.first("concertKey")?.text, let key = Int(text) {
            concertKey = key
        } else if let text = node.first("accidental")?.text, let key = Int(text) {
            concertKey = key
        } else if node.children.contains(where: { $0.name == "custom" || $0.name == "mode" }) {
            // Custom key signatures (<custom>1</custom>, often with <mode>none</mode>)
            // describe their accidentals via <KeySym> children rather than a fifths
            // count. Our model only stores fifths, so treat them as no sharps/flats.
            concertKey = 0
        } else {
            throw SheetMusicError.malformedScore(reason: "KeySig missing <concertKey>/<accidental>")
        }
        var key = KeySignature(concertKey: concertKey)
        key.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return key
    }
}
