import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    /// A chord's or rest's `<staffMove>` — MuseScore 2 wrote it `<move>` (`rw/read206/read206.cpp:1762`) — read as
    /// `TRead::readProperties(ChordRest*)` reads it (`e.readInt()`, `rw/read460/tread.cpp:2610-2612`): an integer, 0
    /// when absent or not one. Kept as written; whether the staff it names can take the chord is the layout's question
    /// (`Part.effectiveStaffMove(_:fromStaff:)`).
    static func decodeStaffMove(in node: XMLTreeNode) -> Int {
        guard let text = (node.first("staffMove") ?? node.first("move"))?.text else { return 0 }
        return Int(text.filter { !$0.isWhitespace }) ?? 0
    }
}
