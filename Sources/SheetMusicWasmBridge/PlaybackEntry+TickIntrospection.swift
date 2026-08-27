import JavaScriptKit
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation

private let itemScalarWidth = 7

/// `[pitch, flatStaffIndex]`, or empty when the note path does not resolve.
@JS public func pitchAndStaffOfNote(
    handle: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
) -> [Double] {
    guard let score = scoreTable.value(for: Int64(handle)),
          allNonnegative([
              partIndex, staffIndexInPart, measureIndex, voiceIndex, elementIndex, noteIndexInChord,
          ]),
          let resolved = AudioMidiBridge.pitchAndStaff(
              score: score,
              noteID: scalarNoteID(
                  partIndex: partIndex,
                  staffIndexInPart: staffIndexInPart,
                  measureIndex: measureIndex,
                  voiceIndex: voiceIndex,
                  elementIndex: elementIndex,
                  noteIndexInChord: noteIndexInChord,
              ),
          )
    else { return [] }
    return [Double(resolved.pitch), Double(resolved.staffIndex)]
}

/// The item's notated end tick, or `-1` when it does not resolve.
@JS public func itemEndTick(
    handle: Int,
    kind: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
) -> Double {
    guard let score = scoreTable.value(for: Int64(handle)),
          let item = timelineItem(
              kind: kind,
              partIndex: partIndex,
              staffIndexInPart: staffIndexInPart,
              measureIndex: measureIndex,
              voiceIndex: voiceIndex,
              elementIndex: elementIndex,
              noteIndexInChord: noteIndexInChord,
          )
    else { return -1 }
    return Double(AudioMidiBridge.itemEndTick(score: score, id: item))
}

/// The earliest resolvable item from flattened seven-scalar records.
@JS public func earliestOf(handle: Int, itemScalars: [Double]) -> [Double] {
    guard let score = scoreTable.value(for: Int64(handle)),
          !itemScalars.isEmpty,
          itemScalars.count.isMultiple(of: itemScalarWidth)
    else { return [] }
    var items: [ScoreItemID] = []
    var scalarsByItem: [ScoreItemID: [Double]] = [:]
    for offset in stride(from: 0, to: itemScalars.count, by: itemScalarWidth) {
        let record = Array(itemScalars[offset ..< offset + itemScalarWidth])
        guard record.allSatisfy({ $0.isFinite && $0.rounded() == $0 }) else { return [] }
        let values = record.compactMap { Int(exactly: $0) }
        guard values.count == itemScalarWidth else { return [] }
        guard let item = timelineItem(
            kind: values[0],
            partIndex: values[1],
            staffIndexInPart: values[2],
            measureIndex: values[3],
            voiceIndex: values[4],
            elementIndex: values[5],
            noteIndexInChord: values[6],
        ) else { return [] }
        items.append(item)
        if scalarsByItem[item] == nil {
            scalarsByItem[item] = record
        }
    }
    guard let earliest = AudioMidiBridge.earliestItem(score: score, ids: items) else { return [] }
    return scalarsByItem[earliest] ?? []
}

private func timelineItem(
    kind: Int,
    partIndex: Int,
    staffIndexInPart: Int,
    measureIndex: Int,
    voiceIndex: Int,
    elementIndex: Int,
    noteIndexInChord: Int,
) -> ScoreItemID? {
    guard allNonnegative([partIndex, staffIndexInPart, measureIndex, voiceIndex, elementIndex]) else {
        return nil
    }
    switch kind {
    case 0:
        guard noteIndexInChord >= 0 else { return nil }
        return scalarScoreItemID(
            kind: "note",
            partIndex: partIndex,
            staffIndexInPart: staffIndexInPart,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
            noteIndexInChord: noteIndexInChord,
        )
    case 1:
        guard noteIndexInChord == -1 else { return nil }
        return scalarScoreItemID(
            kind: "rest",
            partIndex: partIndex,
            staffIndexInPart: staffIndexInPart,
            measureIndex: measureIndex,
            voiceIndex: voiceIndex,
            elementIndex: elementIndex,
            noteIndexInChord: noteIndexInChord,
        )
    default:
        return nil
    }
}

private func allNonnegative(_ values: [Int]) -> Bool {
    values.allSatisfy { $0 >= 0 }
}
