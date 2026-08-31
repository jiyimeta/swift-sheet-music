import SheetMusicFoundation

/// Removes the whole part at `partIndex` — its instrument, its staves and their bar chains — and re-settles what
/// pointed at it.
///
/// Reachable directly as `EditIntent.removePart(at:)`, and also `AddPart`'s inverse. See `AddPart`'s doc comment
/// for the audit of what in the model carries a part index.
///
/// Two things outlive the part:
///
/// - **Brackets.** A cross-part bracket spanning the removed staves shrinks over them, and one anchored ON a
///   removed staff re-anchors onto the first staff it still covers rather than disappearing. That is exactly the
///   pass `Score.filtered(hidingStaves:)` runs for hidden staves, shared as `Score.reanchoredBrackets`.
/// - **System elements anchored into the part.** A tempo written on the instrument being removed must survive the
///   instrument — dropping it would silently take the score's tempo with the part. Such an element re-anchors on
///   `StaffAddress(partIndex: 0, staffIndexInPart: 0)`; addresses past the removed part move one part up.
///
/// Neither is reversible by arithmetic, so the inverse carries both pre-images whole.
///
/// Removing a score's LAST part is refused. Not a taste judgment: `AddPart`'s restore form needs a reference staff
/// to validate against, so its `apply` would throw against the emptied score — and `ScoreEditor.undo` pops the
/// inverse BEFORE applying it, so a throwing undo would drop that entry permanently and leave every older entry on
/// the stack keyed to a score shape that no longer matches. The refusal is what keeps the undo stack coherent.
public struct RemovePart: EditCommand {
    public let partIndex: Int

    public init(partIndex: Int) {
        self.partIndex = partIndex
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: partIndex, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(partIndex) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard score.parts.count > 1 else {
            throw Self.refused(.cannotRemoveLastPart)
        }

        let removed = score.parts[partIndex]
        let brackets = score.parts.map { $0.staves.map(\.brackets) }
        let originalStaves = score.systemMeasures.map { $0.elements.map(\.originalStaff) }

        // Computed against the PRE-removal parts — the re-anchor pass reads the original global staff order and
        // reports where each surviving bracket lands in the post-removal one.
        var survivorLocations: [StaffAddress: (part: Int, staff: Int)] = [:]
        for (part, value) in score.parts.enumerated() where part != partIndex {
            for staff in value.staves.indices {
                survivorLocations[StaffAddress(partIndex: part, staffIndexInPart: staff)] =
                    (part < partIndex ? part : part - 1, staff)
            }
        }
        let rebased = Score.reanchoredBrackets(in: score.parts, survivorLocations: survivorLocations)

        score.parts.remove(at: partIndex)
        for part in score.parts.indices {
            for staff in score.parts[part].staves.indices {
                score.parts[part].staves[staff].brackets = []
            }
        }
        for entry in rebased {
            score.parts[entry.part].staves[entry.staff].brackets.append(entry.bracket)
        }
        reanchorSystemElements(in: &score)

        return AddPart(
            restoring: removed, at: partIndex,
            brackets: brackets, originalStaves: originalStaves,
        )
    }

    /// Re-homes every system-element anchor the removal invalidated. An address INTO the removed part falls back to
    /// the score's first staff, which is always a real one: `apply` has refused the last-part case, so at least one
    /// part survives.
    private func reanchorSystemElements(in score: inout Score) {
        for measureIndex in score.systemMeasures.indices {
            for elementIndex in score.systemMeasures[measureIndex].elements.indices {
                guard let address = score.systemMeasures[measureIndex].elements[elementIndex].originalStaff
                else { continue }
                if address.partIndex == partIndex {
                    score.systemMeasures[measureIndex].elements[elementIndex].originalStaff =
                        StaffAddress(partIndex: 0, staffIndexInPart: 0)
                } else if address.partIndex > partIndex {
                    score.systemMeasures[measureIndex].elements[elementIndex].originalStaff = StaffAddress(
                        partIndex: address.partIndex - 1,
                        staffIndexInPart: address.staffIndexInPart,
                    )
                }
            }
        }
    }
}
