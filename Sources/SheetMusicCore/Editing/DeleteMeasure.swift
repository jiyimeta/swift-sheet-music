import SheetMusicFoundation

/// Removes one measure column — the bar at `measureIndex` in every staff plus its `SystemMeasure`. Deleting
/// bar 0 re-homes the score-start signatures onto the new first bar (each of key / time / clef only when that
/// bar doesn't declare its own), mirroring MuseScore. The inverse restores the captured column verbatim.
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

        MeasureStructure.adjustSpannerOffsets(in: &score, forDeletionAt: measureIndex)
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                score.parts[partIndex].staves[staffIndex].measures.remove(at: measureIndex)
            }
        }
        if score.systemMeasures.indices.contains(measureIndex) {
            score.systemMeasures.remove(at: measureIndex)
        }

        // Re-home the score-start signatures when bar 0 was deleted.
        var prependedCounts = score.parts.map { $0.staves.map { _ in 0 } }
        if measureIndex == 0 {
            for partIndex in score.parts.indices {
                for staffIndex in score.parts[partIndex].staves.indices {
                    let deletedPrefix = MeasureStructure
                        .leadingSignaturePrefix(of: slice.staffMeasures[partIndex][staffIndex].voices[0])
                    guard !deletedPrefix.isEmpty else { continue }
                    let incoming = score.parts[partIndex].staves[staffIndex].measures[0].voices[0]
                    let incomingPrefix = MeasureStructure.leadingSignaturePrefix(of: incoming)
                    let inherited = deletedPrefix.filter { element in
                        !incomingPrefix.contains { sameSignatureKind($0, element) }
                    }
                    guard !inherited.isEmpty else { continue }
                    score.parts[partIndex].staves[staffIndex].measures[0].voices[0].elements
                        .insert(contentsOf: inherited, at: 0)
                    prependedCounts[partIndex][staffIndex] = inherited.count
                }
            }
        }

        return InsertMeasure(
            measureIndex: measureIndex,
            restoredContents: slice,
            prependedNeighborCounts: prependedCounts,
        )
    }

    private func sameSignatureKind(_ lhs: VoiceElement, _ rhs: VoiceElement) -> Bool {
        switch (lhs, rhs) {
        case (.keySignature, .keySignature), (.timeSignature, .timeSignature), (.clef, .clef): true
        default: false
        }
    }
}
