import SheetMusicFoundation

/// Inserts one measure column — one blank bar in every staff plus a parallel `SystemMeasure` — before
/// `measureIndex`; `measureIndex == measureCount` appends. Inserting at 0 moves the score-start signatures
/// (key / time / clef prefix of the old first bar) into the new first bar, mirroring MuseScore.
public struct InsertMeasure: EditCommand {
    public let measureIndex: Int
    /// Set only when this command is the inverse of a `DeleteMeasure`: the exact contents to restore.
    let restoredContents: MeasureSlice?
    /// Also inverse-only: the incoming first bar's voice 0 as it stood *before* the delete merged the
    /// deleted bar's inherited signatures into it, captured per part/staff — `nil` unless the delete this
    /// undoes was at measure 0. Restoring by whole-value overwrite (rather than trying to strip a known
    /// element count) is exact even though the merge is not always a contiguous prepend: a canonical
    /// clef/key/time merge can interleave with signatures the incoming bar already declared.
    let restoredIncomingVoice0: [[Voice]]?
    /// Also inverse-only: addresses of spanners whose span *ended exactly at* the deleted measure, so the
    /// generic insertion predicate can't tell they need re-incrementing — see
    /// `MeasureStructure.adjustSpannerOffsets(forDeletionAt:)`.
    let endpointSpannersToRestore: [VoiceElementID]

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
        restoredContents = nil
        restoredIncomingVoice0 = nil
        endpointSpannersToRestore = []
    }

    init(
        measureIndex: Int,
        restoredContents: MeasureSlice,
        restoredIncomingVoice0: [[Voice]]?,
        endpointSpannersToRestore: [VoiceElementID],
    ) {
        self.measureIndex = measureIndex
        self.restoredContents = restoredContents
        self.restoredIncomingVoice0 = restoredIncomingVoice0
        self.endpointSpannersToRestore = endpointSpannersToRestore
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

        // Restore path (inverse of a delete): undo the bar-0 signature merge byte-for-byte, then reinsert
        // the deleted column verbatim.
        if let contents = restoredContents {
            if let incomingVoices = restoredIncomingVoice0, measureIndex < count {
                for partIndex in score.parts.indices {
                    for staffIndex in score.parts[partIndex].staves.indices {
                        score.parts[partIndex].staves[staffIndex].measures[measureIndex].voices[0] =
                            incomingVoices[partIndex][staffIndex]
                    }
                }
            }
            insert(contents, into: &score)
            for address in endpointSpannersToRestore {
                guard case let .spanner(spanner) = score[address] else { continue }
                var restored = spanner
                restored.nextMeasuresOffset += 1
                score[address] = .spanner(restored)
            }
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
                    MeasureStructure.shiftTuplets(
                        in: &score.parts[partIndex].staves[staffIndex].measures[0].voices[0],
                        by: -prefix.count,
                    )
                    column.staffMeasures[partIndex][staffIndex].voices[0].elements
                        .insert(contentsOf: prefix, at: 0)
                }
            }
        }
        insert(column, into: &score)
        return DeleteMeasure(measureIndex: measureIndex)
    }

    private func insert(_ column: MeasureSlice, into score: inout Score) {
        let preInsertMeasureCount = MeasureStructure.measureCount(of: score)
        MeasureStructure.adjustSpannerOffsets(in: &score, forInsertionAt: measureIndex)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                score.parts[partIndex].staves[staffIndex].measures
                    .insert(column.staffMeasures[partIndex][staffIndex], at: measureIndex)
            }
        }
        // Only keep `systemMeasures` parallel when it was already tracking every measure — a score that
        // never maintained the invariant (see `MeasureSlice`'s `EditingFixtures` callout) must come back
        // out exactly as empty as it went in, not partially patched.
        if score.systemMeasures.count == preInsertMeasureCount {
            score.systemMeasures.insert(column.systemMeasure, at: measureIndex)
        }
    }
}
