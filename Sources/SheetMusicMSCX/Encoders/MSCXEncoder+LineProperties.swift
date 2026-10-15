import SheetMusicCore
import SheetMusicXMLTools

extension Spanner {
    /// The `TextLineBase` children of a begin side's payload, in the pedal's own order
    /// (`TWrite::write(const Pedal*)`, `rw/write/twrite.cpp:2570-2604`; MuseScore's generic order differs and the file
    /// is not claimed byte-identical to MuseScore's). Only the properties the model holds are written; `<play>` only
    /// when the spanner does not play back.
    func lineChildren() -> [XMLTreeNode] {
        guard let line = lineProperties else { return [] }
        var children: [XMLTreeNode] = []
        func add(_ name: String, _ text: String?) {
            if let text { children.append(XMLTreeNode(name: name, text: text)) }
        }
        add("endHookType", line.endHook.map { String($0.code) })
        add("lineVisible", line.lineVisible.map { $0 ? "1" : "0" })
        add("beginHookType", line.beginHook.map { String($0.code) })
        add("lineStyle", line.lineType.map { String($0.rawValue) })
        add("dashLineLength", line.dashLength.map(formatDouble))
        add("dashGapLength", line.dashGap.map(formatDouble))
        add("lineWidth", line.lineWidth.map(formatDouble))
        add("beginHookHeight", line.beginHookHeight.map(formatDouble))
        add("endHookHeight", line.endHookHeight.map(formatDouble))
        if !line.playsBack { add("play", "0") }
        return children
    }
}
