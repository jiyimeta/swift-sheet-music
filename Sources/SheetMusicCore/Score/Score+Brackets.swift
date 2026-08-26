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
    static func reanchoredBrackets(
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
}
