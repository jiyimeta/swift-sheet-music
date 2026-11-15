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
/// - **Score-wide system elements anchored into the part.** A tempo written on the instrument being removed must
///   survive the instrument — dropping it would silently take the score's tempo with the part. Such an element
///   re-anchors on `StaffAddress(partIndex: 0, staffIndexInPart: 0)`; addresses past the removed part move one part
///   up. A STAFF-bound one — a `pizz.`, a staff swing, an instrument change — goes with its part, as MuseScore
///   deletes a removed staff's annotations: re-anchored, it would have printed over the first part, and an
///   instrument change would have changed the first part's sound.
/// - **The top staff's system objects**, when the part removed is the first. Its measure flags
///   (`MeasureFlagsHoist`) and its voltas and gradual tempo changes (`SystemSpannerHoist`) move onto the staff that
///   becomes the top one, rather than leaving with the part.
///
/// None of it is reversible by arithmetic, so the inverse carries the pre-images whole: the brackets, the system
/// lane, and the staff that became the top one.
///
/// Removing a score's LAST part is refused. Not a taste judgment: `AddPart`'s restore form needs a reference staff
/// to validate against, so its `apply` would throw against the emptied score — and `ScoreEditor.undo` pops the
/// inverse BEFORE applying it, so a throwing undo would drop that entry permanently and leave every older entry on
/// the stack keyed to a score shape that no longer matches. The refusal is what keeps the undo stack coherent.
public struct RemovePart: EditCommand {
    public let partIndex: Int
    /// Set only when this command is the inverse of an `AddPart`: the system lane as it stood before the insertion,
    /// written back whole instead of re-anchoring — an insertion at the top keeps the top staff's marks where they
    /// were, which arithmetic on the way back could only approximate.
    let restoredLane: IdentifiedArray<SystemMeasure>?
    /// Also inverse-of-an-insertion only: the staff that was canonical before an insertion at index 0, which moved
    /// its measure flags and system spanners onto the new part. Written back over (0, 0) once the inserted part is
    /// gone, so the two hoists come undone exactly — the removal's own hoists do not run on this path.
    let restoredCanonicalStaff: Staff?

    public init(partIndex: Int) {
        self.partIndex = partIndex
        restoredLane = nil
        restoredCanonicalStaff = nil
    }

    init(partIndex: Int, restoringLane lane: IdentifiedArray<SystemMeasure>, canonicalStaff: Staff?) {
        self.partIndex = partIndex
        restoredLane = lane
        restoredCanonicalStaff = canonicalStaff
    }

    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: partIndex, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        guard score.parts.indices.contains(partIndex) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        guard score.parts.count > 1 else {
            throw Self.refused(.cannotRemoveLastPart)
        }

        let removed = score.parts[partIndex]
        let removedID = score.parts.eid(at: partIndex)
        let brackets = score.parts.map { $0.staves.map(\.brackets) }
        let lane = score.systemMeasures

        // The part being removed may be the canonical one. Capture the staff that will become canonical as it is
        // now, then move the system spanners onto it while both staves are still there, and the flags AFTER the
        // removal (its address is (0, 0) only then).
        let becomesCanonical = partIndex == 0 && score.parts.count > 1
        let incoming = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        let incomingBefore = becomesCanonical ? score[incoming] : nil
        // Undoing an insertion writes the pre-images back instead of hoisting (`restoredCanonicalStaff`).
        let hoists = becomesCanonical && restoredLane == nil
        let removedFlags = hoists ? MeasureFlagsHoist.column(of: Score.canonicalStaff, in: score) : nil
        if hoists {
            SystemSpannerHoist.move(from: Score.canonicalStaff, to: incoming, in: &score, ids: &ids)
        }

        // Computed against the PRE-removal parts — the re-anchor pass reads the original global staff order and
        // reports where each surviving bracket lands in the post-removal one.
        var survivorLocations: [StaffAddress: (part: Int, staff: Int)] = [:]
        for (part, value) in score.parts.enumerated() where part != partIndex {
            for staff in value.staves.indices {
                survivorLocations[StaffAddress(partIndex: part, staffIndexInPart: staff)] =
                    (part < partIndex ? part : part - 1, staff)
            }
        }
        let rebased = Score.reanchoredBrackets(in: score.parts.values, survivorLocations: survivorLocations)

        score.parts.remove(eid: removedID)
        for part in score.parts.indices {
            for staff in score.parts[part].staves.indices {
                score.parts.updateValue(at: part) { partValue in
                    partValue.staves.updateValue(at: staff) { staffValue in
                        staffValue.brackets = []
                    }
                }
            }
        }
        for entry in rebased {
            score.parts.updateValue(at: entry.part) { partValue in
                partValue.staves.updateValue(at: entry.staff) { staffValue in
                    staffValue.brackets.append(entry.bracket)
                }
            }
        }
        if let restoredLane {
            score.systemMeasures = restoredLane
        } else {
            reanchorSystemElements(in: &score)
        }

        if let removedFlags {
            MeasureFlagsHoist.write(removedFlags, to: Score.canonicalStaff, in: &score)
        }
        if let restoredCanonicalStaff, partIndex == 0 {
            score.replaceStaff(at: Score.canonicalStaff, with: restoredCanonicalStaff)
        }
        return AddPart(
            restoring: removed, eid: removedID, at: partIndex,
            brackets: brackets, lane: lane, canonicalStaff: incomingBefore,
        )
    }

    /// Re-homes every system-element anchor the removal invalidated. A score-wide element INTO the removed part falls
    /// back to the score's first staff, which is always a real one: `apply` has refused the last-part case, so at
    /// least one part survives — unless the top staff already carries the same mark at the same beat, when it is
    /// removed instead: it was a copy, MuseScore's linked one on a system-object staff, which goes with its staff.
    /// A staff-bound one is removed with its part — an element with no staff is on the top staff, so it is the
    /// removed part's when that part is the first.
    private func reanchorSystemElements(in score: inout Score) {
        for measureIndex in score.systemMeasures.indices {
            score.systemMeasures.updateValue(at: measureIndex) { column in
                var dropped: [Int] = []
                for elementIndex in column.elements.indices {
                    let element = column.elements[elementIndex]
                    guard let address = element.originalStaff ?? (element.isScoreWide ? nil : Score.canonicalStaff)
                    else { continue }
                    if address.partIndex == partIndex {
                        let copiesTopMark = column.elements.indices.contains { other in
                            other != elementIndex && column.elements[other].isTopSystemObject
                                && column.elements[other].position == element.position
                                && column.elements[other].element == element.element
                        }
                        guard element.isScoreWide, !copiesTopMark || address == Score.canonicalStaff else {
                            dropped.append(elementIndex)
                            continue
                        }
                        column.elements.updateValue(at: elementIndex) {
                            $0.originalStaff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
                        }
                    } else if address.partIndex > partIndex {
                        column.elements.updateValue(at: elementIndex) {
                            $0.originalStaff = StaffAddress(
                                partIndex: address.partIndex - 1,
                                staffIndexInPart: address.staffIndexInPart,
                            )
                        }
                    }
                }
                for elementIndex in dropped.reversed() {
                    column.elements.removeSubrange(elementIndex ..< elementIndex + 1)
                }
            }
        }
    }
}
