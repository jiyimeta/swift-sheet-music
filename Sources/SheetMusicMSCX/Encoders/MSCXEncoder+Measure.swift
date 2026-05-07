import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Measure {
    /// Build the `<Measure>` element. Phase 1 emits voices only.
    /// startRepeat / endRepeatCount / markers / jumps / layout breaks
    /// land in follow-up specs (none present in midi01).
    func encode() -> XMLTreeNode {
        let voiceNodes = voices.map { $0.encode() }
        return XMLTreeNode(name: "Measure", children: voiceNodes)
    }
}
