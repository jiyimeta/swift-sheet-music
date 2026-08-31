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
///   permutation moves the anchor. Each bracket is carried to its anchor staff's new address verbatim — same
///   `type`, same `span`, same `column`. A brace travels with the part it braces; a group bracket stays the size
///   the score declared it.
///
/// Nothing rewrites the declared span, and in particular it is not clamped to the staves left below the new
/// anchor. That matches MuseScore, where `Score::sortStaves` reorders parts without touching spans, and where
/// clamping is a DRAW-time concern: `LayoutEngine.buildBrackets` already caps the last spanned staff at the
/// system's end (mirroring `BracketItem::staffIdx2`) and hides a bracket whose effective span collapses to one
/// staff. Baking that into the model would be lossy in a way undo cannot reach — two forward moves, anchor to the
/// bottom and back again with no undo between them, would permanently shrink a group bracket to `span: 1` and turn
/// something MuseScore hides into something it draws. `movedBrackets` says why this cannot go through
/// `Score.reanchoredBrackets`, which the other two structural paths share.
///
/// The inverse still carries the pre-image of both fields whole and writes them back, exactly as `RemovePart`
/// does. Carrying brackets verbatim under the inverse permutation is already exact, so this is a guarantee rather
/// than a repair: it keeps undo byte-exact by construction instead of by an argument about the forward pass, and
/// keeps it that way if that pass ever starts normalizing something.
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
        // Read off the PRE-move parts, so the entries name where each bracket lands in the permuted order.
        let rebased = movedBrackets(in: score)

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

    /// Every bracket carried to its anchor staff's new address, verbatim — same `type`, same `span`, same `column`.
    ///
    /// Deliberately NOT `Score.reanchoredBrackets`, which the two other structural paths use. That pass is built
    /// for a change where staves go away: it re-derives `span` as the number of SURVIVORS in the bracket's window,
    /// clipped at the end of the staff list. Under a permutation every staff survives, so re-deriving can only
    /// lose information — a group bracket whose anchor part moves to the bottom of the score has one staff left in
    /// its clipped window and would come back with `span: 1`, permanently, in the file. The window arithmetic that
    /// pass performs answers "which of the staves I covered are still here"; a move's answer is "all of them".
    ///
    /// No column compaction either, for the same reason it is right elsewhere: nothing was dropped, so the set of
    /// occupied columns is exactly what it was. Running the compaction here could only rewrite a gap the score
    /// arrived with — a column this edit never touched.
    private func movedBrackets(in score: Score) -> [(part: Int, staff: Int, bracket: BracketItem)] {
        var entries: [(part: Int, staff: Int, bracket: BracketItem)] = []
        for (part, value) in score.parts.enumerated() {
            for (staff, staffValue) in value.staves.enumerated() {
                for bracket in staffValue.brackets {
                    entries.append((part: permuted(part), staff: staff, bracket: bracket))
                }
            }
        }
        return entries
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

    /// Strips every staff's brackets and re-lays the moved ones, untouched. Nothing here clamps or normalizes: a
    /// span reaching past the last staff is the layout engine's to cap at draw time, and rewriting it in the model
    /// would throw away what the score declared. See the type's doc comment.
    private static func writeBack(
        _ entries: [(part: Int, staff: Int, bracket: BracketItem)],
        to score: inout Score,
    ) {
        for part in score.parts.indices {
            for staff in score.parts[part].staves.indices {
                score.parts[part].staves[staff].brackets = []
            }
        }
        for entry in entries {
            score.parts[entry.part].staves[entry.staff].brackets.append(entry.bracket)
        }
    }

    /// The inverse path: the parts are back in their pre-forward-move order, so the two captured pre-images are
    /// written over whatever the pass above computed.
    ///
    /// Both the writes and the `indices.contains` guards around them are belt-and-braces. The pass above is
    /// already exact under the inverse permutation, and a pre-image is captured from the very score this command's
    /// own permutation restores — so it is self-consistent by construction and every index below is in range. What
    /// this buys is that undo stays byte-exact if the forward pass ever starts normalizing something, and that a
    /// hand-built command (or a future caller capturing from elsewhere) cannot trap on a subscript.
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
