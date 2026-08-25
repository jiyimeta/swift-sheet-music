import SheetMusicFoundation

/// Removes one measure column — the bar at `measureIndex` in every staff plus its `SystemMeasure`. Deleting
/// bar 0 re-homes the score-start signatures onto the new first bar in MuseScore's structural clef/key/time
/// order — each kind only when that bar doesn't declare its own. The inverse restores the captured column
/// and the incoming bar's pre-merge voice 0 verbatim.
public struct DeleteMeasure: EditCommand {
    public let measureIndex: Int

    public init(measureIndex: Int) {
        self.measureIndex = measureIndex
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
        guard measureIndex >= 0, measureIndex < count, !score.parts.isEmpty else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard count > 1 else {
            throw Self.refused(.cannotDeleteOnlyMeasure)
        }

        let slice = MeasureSlice(
            staffMeasures: score.parts.map { part in
                part.staves.map { $0.measures[measureIndex] }
            },
            systemMeasure: score.systemMeasures.indices.contains(measureIndex)
                ? score.systemMeasures[measureIndex] : SystemMeasure(),
        )

        // Run before removal so anchor measure indices are still pre-delete, matching the insert direction.
        let endpointSpanners = MeasureStructure.adjustSpannerOffsets(in: &score, forDeletionAt: measureIndex)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                score.parts[partIndex].staves[staffIndex].measures.remove(at: measureIndex)
            }
        }
        if score.systemMeasures.indices.contains(measureIndex) {
            score.systemMeasures.remove(at: measureIndex)
        }

        // Re-home the score-start signatures when bar 0 was deleted. Capture every staff's incoming voice 0
        // *before* any merge, whether or not that staff ends up needing one — the inverse restores this
        // verbatim rather than trying to reverse a canonical merge that isn't always a contiguous prepend.
        var restoredIncomingVoice0: [[Voice]]?
        if measureIndex == 0 {
            restoredIncomingVoice0 = score.parts.map { part in
                part.staves.map { $0.measures[0].voices[0] }
            }
            for partIndex in score.parts.indices {
                for staffIndex in score.parts[partIndex].staves.indices {
                    let deletedPrefix = MeasureStructure
                        .leadingSignaturePrefix(of: slice.staffMeasures[partIndex][staffIndex].voices[0])
                    guard !deletedPrefix.isEmpty else { continue }
                    let incoming = score.parts[partIndex].staves[staffIndex].measures[0].voices[0]
                    let incomingPrefix = MeasureStructure.leadingSignaturePrefix(of: incoming)
                    let merged = MeasureStructure.mergedLeadingSignatures(
                        inheritingFrom: deletedPrefix, into: incomingPrefix,
                    )
                    guard merged.count > incomingPrefix.count else { continue }
                    score.parts[partIndex].staves[staffIndex].measures[0].voices[0].elements
                        .replaceSubrange(0 ..< incomingPrefix.count, with: merged)
                    MeasureStructure.shiftTuplets(
                        in: &score.parts[partIndex].staves[staffIndex].measures[0].voices[0],
                        by: merged.count - incomingPrefix.count,
                    )
                }
            }
        }

        return InsertMeasure(
            measureIndex: measureIndex,
            restoredContents: slice,
            restoredIncomingVoice0: restoredIncomingVoice0,
            endpointSpannersToRestore: endpointSpanners,
        )
    }
}
