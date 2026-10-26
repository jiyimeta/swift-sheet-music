import SheetMusicCore
import SheetMusicFoundation

extension Score {
    /// The parts with each measure's repeats on the canonical staff only. A repeat is the whole measure column's in
    /// MuseScore — any part's bar line sets it (`setRepeatStart` / `setRepeatEnd`, `P2:5812-5817`), and a save writes
    /// it on the first staff alone (`MeasureWrite::writeMeasure` under `writeSystemElements`) — which is where the
    /// model keeps it too (`SetRepeatBarLines`). An end repeat's count is the last part's that ends one there.
    static func gatheringRepeats(_ parts: [Part]) -> [Part] {
        guard let first = parts.first?.staves.first else { return parts }
        var gathered = parts
        for index in first.measures.indices {
            let columns = parts.compactMap { part in
                part.staves.first.flatMap { $0.measures.indices.contains(index) ? $0.measures[index] : nil }
            }
            let startRepeat = columns.contains(where: \.startRepeat)
            let endRepeatCount = columns.last { $0.endRepeatCount != nil }?.endRepeatCount
            for partIndex in gathered.indices {
                gathered[partIndex].staves.mapValues { staff in
                    guard staff.measures.indices.contains(index) else { return staff }
                    var cleared = staff
                    cleared.measures[index].startRepeat = false
                    cleared.measures[index].endRepeatCount = nil
                    return cleared
                }
            }
            gathered[0].staves.updateValue(at: 0) { staff in
                staff.measures[index].startRepeat = startRepeat
                staff.measures[index].endRepeatCount = endRepeatCount
            }
        }
        return gathered
    }
}
