import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension KeySignature {
    static func decode(_ node: XMLTreeNode) throws -> KeySignature {
        // Modern mscx uses <concertKey>; older forms use <accidental>.
        if let text = node.first("concertKey")?.text, let key = Int(text) {
            return KeySignature(concertKey: key)
        }
        if let text = node.first("accidental")?.text, let key = Int(text) {
            return KeySignature(concertKey: key)
        }
        throw SheetMusicError.malformedScore(reason: "KeySig missing <concertKey>/<accidental>")
    }
}
