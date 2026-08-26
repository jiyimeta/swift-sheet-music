import SheetMusicFoundation

/// Moves the part at `fromIndex` to `toIndex` — a removal followed by an insertion of the same `Part` value, which
/// is what "drag this instrument up two rows" means: the parts between the two indices shift one place the other
/// way, and nothing else in the column order changes.
///
/// `MovePart(from: 0, to: 1)` over `[A, B, C]` gives `[B, A, C]`; `MovePart(from: 2, to: 0)` gives `[C, A, B]`.
/// Both indices name positions in the CURRENT parts array, so both must be in range — `toIndex == parts.count` is
/// not an append here, unlike `AddPart`, because a move cannot grow the score.
///
/// ## What travels, and what has to be re-derived
///
/// The `Part` value carries its own instrument, staves and bars, so those need nothing. Two things do:
///
/// - **`PositionedSystemElement.originalStaff`** — the one field in the model embedding a part index (see
///   `AddPart`'s audit). Every address is re-stamped through the permutation, so a tempo written on the flute still
///   names the flute afterwards.
/// - **Brackets.** They anchor on a staff and count `span` staves downward in the GLOBAL flattened order, so a
///   permutation moves both ends. Each bracket follows its anchor staff and keeps its span, clamped to the staves
///   still below the anchor's new position — a brace travels with the part it braces, and a group bracket keeps
///   covering as much of the system as there is room for. That is the `Score.reanchoredBrackets` pass again, run
///   with every staff a survivor.
///
/// Neither the clamp nor the column compaction that pass applies is reversible by arithmetic, so — exactly as
/// `RemovePart` does — the inverse carries the pre-image of both fields whole and writes them back rather than
/// recomputing. `MovePart(from: to, to: from)` alone would restore the ORDER but not necessarily the spans.
public struct MovePart: EditCommand {
    public let fromIndex: Int
    public let toIndex: Int
    /// Set only when this command is the inverse of another `MovePart`: every staff's `brackets` array as it stood
    /// before the forward move, indexed `[partIndex][staffIndexInPart]` over the PRE-move parts — which is the
    /// order this command's own permutation restores, so the indices line up by construction.
    let restoredBrackets: [[[BracketItem]]]?
    /// Also inverse-only: every system element's `originalStaff` before the forward move, indexed
    /// `[measureIndex][elementIndex]`. Captured for symmetry with `restoredBrackets`; the re-stamp alone would get
    /// there, and writing the pre-image over it is what makes that a guarantee rather than an argument.
    let restoredOriginalStaves: [[StaffAddress?]]?

    public init(from fromIndex: Int, to toIndex: Int) {
        self.fromIndex = fromIndex
        self.toIndex = toIndex
        restoredBrackets = nil
        restoredOriginalStaves = nil
    }

    init(
        from fromIndex: Int,
        to toIndex: Int,
        brackets: [[[BracketItem]]],
        originalStaves: [[StaffAddress?]],
    ) {
        self.fromIndex = fromIndex
        self.toIndex = toIndex
        restoredBrackets = brackets
        restoredOriginalStaves = originalStaves
    }

    /// Where the move lands, not where it started — a host scrolling to the affected slot wants the part's new
    /// home on screen.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: toIndex, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(fromIndex), score.parts.indices.contains(toIndex) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }

        let brackets = score.parts.map { $0.staves.map(\.brackets) }
        let originalStaves = score.systemMeasures.map { $0.elements.map(\.originalStaff) }
        // Computed against the PRE-move parts: the re-anchor pass reads the original global staff order and reports
        // where each bracket lands in the permuted one. Every staff survives a move, so nothing is dropped.
        let rebased = Score.reanchoredBrackets(in: score.parts, survivorLocations: survivorLocations(in: score))

        let part = score.parts.remove(at: fromIndex)
        score.parts.insert(part, at: toIndex)
        restampSystemElements(in: &score)
        Self.writeBack(rebased, to: &score)
        restore(&score)

        return MovePart(from: toIndex, to: fromIndex, brackets: brackets, originalStaves: originalStaves)
    }

    /// Where each part index lands after the move. `fromIndex` goes to `toIndex`; everything strictly between them
    /// shifts one place towards the vacated slot; everything outside the pair is untouched.
    private func permuted(_ partIndex: Int) -> Int {
        if partIndex == fromIndex { return toIndex }
        if fromIndex < toIndex {
            return (partIndex > fromIndex && partIndex <= toIndex) ? partIndex - 1 : partIndex
        }
        return (partIndex >= toIndex && partIndex < fromIndex) ? partIndex + 1 : partIndex
    }

    /// Every staff's original address mapped to where it lands — the whole-permutation form of what `RemovePart`
    /// builds from the survivors, and what lets both commands share one bracket pass.
    private func survivorLocations(in score: Score) -> [StaffAddress: (part: Int, staff: Int)] {
        var locations: [StaffAddress: (part: Int, staff: Int)] = [:]
        for (part, value) in score.parts.enumerated() {
            for staff in value.staves.indices {
                locations[StaffAddress(partIndex: part, staffIndexInPart: staff)] = (permuted(part), staff)
            }
        }
        return locations
    }

    private func restampSystemElements(in score: inout Score) {
        // The permutation is stated over the PRE-move indices, so this reads each address once and writes the
        // answer — re-stamping in place against the already-permuted parts would compose the map with itself.
        for measureIndex in score.systemMeasures.indices {
            for elementIndex in score.systemMeasures[measureIndex].elements.indices {
                guard let address = score.systemMeasures[measureIndex].elements[elementIndex].originalStaff
                else { continue }
                score.systemMeasures[measureIndex].elements[elementIndex].originalStaff = StaffAddress(
                    partIndex: permuted(address.partIndex),
                    staffIndexInPart: address.staffIndexInPart,
                )
            }
        }
    }

    /// Strips every staff's brackets and re-lays the re-anchored ones, clamping each span to the staves left below
    /// its new anchor. A bracket that overran the last staff is not something the layout engine has a sane answer
    /// for, and a permutation can produce one — moving a group's anchor part to the bottom of the score, say.
    private static func writeBack(
        _ entries: [(part: Int, staff: Int, bracket: BracketItem)],
        to score: inout Score,
    ) {
        var globalIndex: [StaffAddress: Int] = [:]
        var staffCount = 0
        for part in score.parts.indices {
            for staff in score.parts[part].staves.indices {
                score.parts[part].staves[staff].brackets = []
                globalIndex[StaffAddress(partIndex: part, staffIndexInPart: staff)] = staffCount
                staffCount += 1
            }
        }
        for entry in entries {
            let anchor = globalIndex[StaffAddress(partIndex: entry.part, staffIndexInPart: entry.staff)] ?? 0
            var bracket = entry.bracket
            bracket.span = max(1, min(bracket.span, staffCount - anchor))
            score.parts[entry.part].staves[entry.staff].brackets.append(bracket)
        }
    }

    /// The inverse path: the parts are back in their pre-forward-move order, so the two captured pre-images are
    /// written over whatever the pass above computed.
    private func restore(_ score: inout Score) {
        if let restoredBrackets {
            for part in score.parts.indices where restoredBrackets.indices.contains(part) {
                for staff in score.parts[part].staves.indices
                    where restoredBrackets[part].indices.contains(staff)
                {
                    score.parts[part].staves[staff].brackets = restoredBrackets[part][staff]
                }
            }
        }
        guard let restoredOriginalStaves else { return }
        for measureIndex in score.systemMeasures.indices
            where restoredOriginalStaves.indices.contains(measureIndex)
        {
            for elementIndex in score.systemMeasures[measureIndex].elements.indices
                where restoredOriginalStaves[measureIndex].indices.contains(elementIndex)
            {
                score.systemMeasures[measureIndex].elements[elementIndex].originalStaff =
                    restoredOriginalStaves[measureIndex][elementIndex]
            }
        }
    }
}
