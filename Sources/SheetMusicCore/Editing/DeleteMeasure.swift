import SheetMusicFoundation

/// Removes one measure column — the bar at `measureIndex` in every staff plus its `SystemMeasure`. Deleting
/// bar 0 re-homes the score-start signatures onto the new first bar in MuseScore's structural clef/key/time
/// order — each kind only when that bar doesn't declare its own. The inverse restores the captured column
/// and the incoming bar's pre-merge voice 0 verbatim.
public struct DeleteMeasure: EditCommand {
    public let measureIndex: Int
    /// Inverse of a fresh bar-0 insertion: restore tuplets lost or retargeted when its prefix moved away.
    let restoredFollowingVoice0: [[Voice]]?

    public init(measureIndex: Int) {
        self.init(measureIndex: measureIndex, restoringFollowingVoice0: nil)
    }

    init(measureIndex: Int, restoringFollowingVoice0: [[Voice]]?) {
        self.measureIndex = measureIndex
        restoredFollowingVoice0 = restoringFollowingVoice0
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: measureIndex, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let count = MeasureStructure.measureCount(of: score)
        guard measureIndex >= 0, measureIndex < count, !score.parts.isEmpty else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard count > 1 else {
            throw Self.refused(.cannotDeleteOnlyMeasure)
        }

        let slice = MeasureSlice(
            staffMeasures: score.parts.map { $0.staves.map { $0.measures[measureIndex] } },
            systemMeasure: score.systemMeasures.indices.contains(measureIndex)
                ? score.systemMeasures[measureIndex] : SystemMeasure(),
            systemMeasureEID: score.systemMeasures.indices.contains(measureIndex)
                ? score.systemMeasures.eid(at: measureIndex) : nil,
        )

        // Run before removal so anchor measure indices are still pre-delete, matching the insert direction.
        let endpointSpanners = MeasureStructure.adjustSpannerOffsets(in: &score, forDeletionAt: measureIndex)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                score.parts.updateValue(at: partIndex) { partValue in
                    partValue.staves.updateValue(at: staffIndex) { $0.measures.remove(at: measureIndex) }
                }
            }
        }
        if score.systemMeasures.indices.contains(measureIndex) {
            let eid = score.systemMeasures.eid(at: measureIndex)
            score.systemMeasures.remove(eid: eid)
        }

        let restoredIncomingVoice0 = rehomeInitialSignatures(in: &score, deleted: slice)
        if let restoredFollowingVoice0 {
            for partIndex in score.parts.indices {
                score.parts.updateValue(at: partIndex) { part in
                    for staffIndex in part.staves.indices {
                        part.staves.updateValue(at: staffIndex) { staff in
                            staff.measures[0].voices[0] = restoredFollowingVoice0[partIndex][staffIndex]
                        }
                    }
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

    private func rehomeInitialSignatures(in score: inout Score, deleted slice: MeasureSlice) -> [[Voice]]? {
        // Re-home the score-start signatures when bar 0 was deleted. Capture every staff's incoming voice 0
        // *before* any merge, whether or not that staff ends up needing one — the inverse restores this
        // verbatim rather than trying to reverse a canonical merge that isn't always a contiguous prepend.
        guard measureIndex == 0 else { return nil }
        let restoredIncomingVoice0 = score.parts.map { part in
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
                score.parts.updateValue(at: partIndex) { partValue in
                    partValue.staves.updateValue(at: staffIndex) { staffValue in
                        let removed = Set(incomingPrefix.indices.filter {
                            merged.index(of: incomingPrefix.eid(at: $0)) == nil
                        })
                        staffValue.measures[0].voices[0].removeElements(at: removed)
                        staffValue.measures[0].voices[0].elements
                            .replaceSubrange(
                                0 ..< (incomingPrefix.count - removed.count),
                                with: merged.identifiedPairs(in: merged.indices),
                            )
                    }
                }
            }
        }
        return restoredIncomingVoice0
    }
}
