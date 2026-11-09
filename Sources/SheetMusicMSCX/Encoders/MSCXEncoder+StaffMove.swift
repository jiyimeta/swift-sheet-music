import SheetMusicCore
import SheetMusicXMLTools

extension Chord {
    /// `<staffMove>`, written where `TWrite::writeProperties(const ChordRest*)` writes it — after `<dots>`, before
    /// `<durationType>` (`rw/write/twrite.cpp:1109`) — and only when it is not 0, `Pid::STAFF_MOVE`'s default. The
    /// value is the one the file had, honored or not (`Chord.staffMove`), as MuseScore writes back the move it
    /// remembers. `start` is where the duration block begins in `children`, so the tag lands after its `<dots>`.
    func insertStaffMove(into children: inout [XMLTreeNode], from start: Int) {
        guard staffMove != 0 else { return }
        let node = XMLTreeNode(name: "staffMove", text: String(staffMove))
        if let index = children[start...].firstIndex(where: { $0.name == "durationType" }) {
            children.insert(node, at: index)
        } else {
            children.append(node)
        }
    }
}
