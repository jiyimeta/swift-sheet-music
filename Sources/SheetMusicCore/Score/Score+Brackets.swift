import SheetMusicFoundation

extension Score {
    /// Re-anchors every bracket declared in `parts` over the staves that survive a structural change, returning
    /// where each surviving bracket now belongs.
    ///
    /// `BracketItem`s anchor on the topmost staff of their group and count `span` staves downward in the GLOBAL
    /// flattened staff order (`parts.flatMap(\.staves)`), not within one part — MuseScore routinely groups several
    /// single-staff parts under one bracket. So both survival and span must be computed over the flattened
    /// sequence; a per-part calculation collapses such cross-part brackets down to their anchor staff.
    ///
    /// A bracket at global index `g` with span `s` covers `g … g+s-1`. It re-anchors on the first surviving staff
    /// in that window (which may live in a different part than the original anchor) and its span becomes the
    /// number of survivors in the window. A window with no survivor drops the bracket entirely.
    ///
    /// `survivorLocations` maps each ORIGINAL address that survives to where it landed; an address absent from the
    /// map is one that went away. Callers strip the brackets off the rebuilt staves and append what this returns —
    /// see `filtered(hidingStaves:)` (staff visibility) and `RemovePart` (a whole part deleted), the two callers
    /// this exists to keep in agreement.
    ///
    /// This is a pass for a change where staves GO AWAY, and `span` is re-derived from what is left. `MovePart`
    /// deliberately does not use it: under a permutation every staff survives, so re-deriving could only clip a
    /// declared span against the end of the staff list. See `MovePart.movedBrackets`.
    ///
    /// The result's `column`s are compacted (`canonicalizedColumns`) before it is returned, so a bracket whose
    /// neighbour in the gutter went away does not keep drawing a column further out than anything occupies.
    static func reanchoredBrackets(
        in parts: [Part],
        survivorLocations: [StaffAddress: (part: Int, staff: Int)],
    ) -> [(part: Int, staff: Int, bracket: BracketItem)] {
        canonicalizedColumns(rebasedBrackets(in: parts, survivorLocations: survivorLocations))
    }

    private static func rebasedBrackets(
        in parts: [Part],
        survivorLocations: [StaffAddress: (part: Int, staff: Int)],
    ) -> [(part: Int, staff: Int, bracket: BracketItem)] {
        var originalAddresses: [StaffAddress] = []
        for (partIndex, part) in parts.enumerated() {
            for staffIndex in part.staves.indices {
                originalAddresses.append(StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex))
            }
        }
        var result: [(part: Int, staff: Int, bracket: BracketItem)] = []
        for (globalIndex, address) in originalAddresses.enumerated() {
            let staff = parts[address.partIndex].staves[address.staffIndexInPart]
            for bracket in staff.brackets {
                let endIndex = min(globalIndex + bracket.span - 1, originalAddresses.count - 1)
                let surviving = (globalIndex ... endIndex)
                    .filter { survivorLocations[originalAddresses[$0]] != nil }
                guard let anchorGlobal = surviving.first,
                      let location = survivorLocations[originalAddresses[anchorGlobal]]
                else { continue }
                var rebased = bracket
                rebased.span = surviving.count
                result.append((part: location.part, staff: location.staff, bracket: rebased))
            }
        }
        return result
    }

    /// Closes the gaps a re-anchor pass leaves in the bracket gutter: the columns still occupied are renumbered
    /// onto `0 ..< n`, keeping their order.
    ///
    /// `column` is a horizontal coordinate, not a label — `StaffRenderer.bracketSpineX` puts a bracket's spine at
    /// `staffOriginX - 0.5 sp - column * sp`, and `LayoutEngine.bracketGutterInfo` sizes the whole gutter as
    /// `maxColumn + 1`. So a group bracket left at column 1 after the brace at column 0 was removed with its part
    /// draws one `sp` further left than anything needs and reserves a gutter column nothing occupies. `RemovePart`
    /// and `MovePart` write their result to the score the user saves, which is why it is compacted rather than
    /// left for the layout engine to shrug at.
    ///
    /// The renumbering is GLOBAL over the pass's result rather than per anchor staff. Brackets sharing a column
    /// share a spine position across the whole system — that is the alignment a nested layout depends on — so
    /// compacting one staff's columns in isolation would pull its outer bracket down onto a spine another staff
    /// still draws one column further out. A column any surviving bracket still occupies is not a gap.
    ///
    /// "Occupied" counts EVERY surviving bracket, including invisible ones and `.noBracket` — which
    /// `LayoutEngine.buildBrackets` skips when it draws, and `bracketGutterInfo` skips when it sizes the gutter.
    /// So an invisible bracket at column 0 keeps a visible one at column 1 where it is. That is deliberate:
    /// this pass repairs the damage a structural edit did, and an undrawn bracket is still a slot the score
    /// declared and a slot the user can make visible again. Squeezing it out would silently rewrite a column the
    /// edit never touched, and the gutter it costs is already zero — the sizing pass ignores it too.
    private static func canonicalizedColumns(
        _ entries: [(part: Int, staff: Int, bracket: BracketItem)],
    ) -> [(part: Int, staff: Int, bracket: BracketItem)] {
        let occupied = Set(entries.map(\.bracket.column)).sorted()
        guard occupied != Array(occupied.indices) else { return entries }
        let dense = Dictionary(uniqueKeysWithValues: occupied.enumerated().map { ($1, $0) })
        return entries.map { entry in
            var bracket = entry.bracket
            bracket.column = dense[bracket.column] ?? bracket.column
            return (part: entry.part, staff: entry.staff, bracket: bracket)
        }
    }
}
