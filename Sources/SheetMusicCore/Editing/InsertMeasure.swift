import SheetMusicFoundation

/// Inserts one measure column — one blank bar in every staff plus a parallel `SystemMeasure` — before
/// `measureIndex`; `measureIndex == measureCount` appends. Inserting at 0 moves the score-start signatures
/// (key / time / clef prefix of the old first bar) into the new first bar, mirroring MuseScore.
public struct InsertMeasure: EditCommand {
    public let measureIndex: Int
    /// Set only when this command is the inverse of a `DeleteMeasure`: the exact contents to restore.
    let restoredContents: MeasureSlice?
    /// Also inverse-only: how many merged signature elements `DeleteMeasure` prepended to the neighboring bar,
    /// per part/staff (same shape as `MeasureSlice.staffMeasures`) — stripped before reinserting the slice.
    let prependedNeighborCounts: [[Int]]?

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
        restoredContents = nil
        prependedNeighborCounts = nil
    }

    init(measureIndex: Int, restoredContents: MeasureSlice, prependedNeighborCounts: [[Int]]) {
        self.measureIndex = measureIndex
        self.restoredContents = restoredContents
        self.prependedNeighborCounts = prependedNeighborCounts
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        let count = MeasureStructure.measureCount(of: score)
        guard measureIndex >= 0, measureIndex <= count, !score.parts.isEmpty else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }

        // Restore path (inverse of a delete): strip the merged prefix the delete added, then reinsert verbatim.
        if let contents = restoredContents {
            if let counts = prependedNeighborCounts, measureIndex < count {
                for partIndex in score.parts.indices {
                    for staffIndex in score.parts[partIndex].staves.indices {
                        let strip = counts[partIndex][staffIndex]
                        guard strip > 0 else { continue }
                        score.parts[partIndex].staves[staffIndex].measures[measureIndex]
                            .voices[0].elements.removeFirst(strip)
                    }
                }
            }
            insert(contents, into: &score)
            return DeleteMeasure(measureIndex: measureIndex)
        }

        // Blank path.
        var column = MeasureStructure.blankColumn(for: score)
        if measureIndex == 0, count > 0 {
            for partIndex in score.parts.indices {
                for staffIndex in score.parts[partIndex].staves.indices {
                    let oldVoice = score.parts[partIndex].staves[staffIndex].measures[0].voices[0]
                    let prefix = MeasureStructure.leadingSignaturePrefix(of: oldVoice)
                    guard !prefix.isEmpty else { continue }
                    score.parts[partIndex].staves[staffIndex].measures[0].voices[0].elements
                        .removeFirst(prefix.count)
                    column.staffMeasures[partIndex][staffIndex].voices[0].elements
                        .insert(contentsOf: prefix, at: 0)
                }
            }
        }
        insert(column, into: &score)
        return DeleteMeasure(measureIndex: measureIndex)
    }

    private func insert(_ column: MeasureSlice, into score: inout Score) {
        MeasureStructure.adjustSpannerOffsets(in: &score, forInsertionAt: measureIndex)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                score.parts[partIndex].staves[staffIndex].measures
                    .insert(column.staffMeasures[partIndex][staffIndex], at: measureIndex)
            }
        }
        if score.systemMeasures.count >= measureIndex {
            score.systemMeasures.insert(column.systemMeasure, at: measureIndex)
        }
    }
}
