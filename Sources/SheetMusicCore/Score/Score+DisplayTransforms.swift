extension Score {
    /// Authored opening clef rawType for the staff at `address`: the explicit measure-0 clef when one exists, otherwise
    /// the staff's `defaultClefType`. Returns nil when the address points outside the score or the staff declares no
    /// default. Callers (e.g. the Reader's clef-override picker) layer their own fallback on top. Shared by iOS and the
    /// Android JNI parts/staves descriptor so both surface the same "current clef".
    public func authoredClef(at address: StaffAddress) -> String? {
        guard let staff = self[address] else { return nil }
        if let first = staff.measures.first?.voices.first?.elements.first,
           case let .clef(c) = first
        {
            return c.concertClefType
        }
        return staff.defaultClefType
    }

    /// Returns a copy of the score with the staves at the given addresses removed from each `Part.staves`. Parts left
    /// without any visible staff are dropped entirely so labels and brackets do not render against an empty group.
    ///
    /// Indexing is positional: a `StaffAddress(partIndex, staffIndexInPart)` resolves to
    /// `parts[partIndex].staves[staffIndexInPart]` on the pre-filter score.
    ///
    /// `BracketItem`s anchor on the topmost staff of their group with a `span` count of staves below them (see
    /// `BracketItem` in SheetMusicCore). Naively dropping staves loses the bracket when the anchor is hidden and
    /// miscounts the span when an interior staff is hidden, so brackets are re-anchored here against the surviving
    /// staves before the layout engine sees them.
    public func filtered(hidingStaves addresses: Set<StaffAddress>) -> Score {
        guard !addresses.isEmpty else { return self }
        var copy = self
        var newParts: [Part] = []
        for (partIndex, part) in parts.enumerated() {
            let keep: [Bool] = part.staves.indices.map { staffIndex in
                !addresses.contains(StaffAddress(
                    partIndex: partIndex, staffIndexInPart: staffIndex,
                ))
            }
            guard keep.contains(true) else { continue }

            var keptStaves: [Staff] = []
            var newIndexFor: [Int: Int] = [:]
            for (origIndex, staff) in part.staves.enumerated() where keep[origIndex] {
                newIndexFor[origIndex] = keptStaves.count
                var stripped = staff
                stripped.brackets = []
                keptStaves.append(stripped)
            }

            for (origIndex, staff) in part.staves.enumerated() {
                for bracket in staff.brackets {
                    let endOriginal = min(
                        origIndex + bracket.span - 1,
                        part.staves.count - 1,
                    )
                    let surviving = (origIndex ... endOriginal).filter { keep[$0] }
                    guard let firstOriginal = surviving.first,
                          let anchor = newIndexFor[firstOriginal]
                    else { continue }
                    var rebased = bracket
                    rebased.span = surviving.count
                    keptStaves[anchor].brackets.append(rebased)
                }
            }

            var newPart = part
            newPart.staves = keptStaves
            newParts.append(newPart)
        }
        copy.parts = newParts
        return copy
    }

    /// Returns a copy of the score with each staff's opening clef rewritten according to `clefOverrides`. The map is
    /// keyed by the pre-`filtered(hidingStaves:)` staff address — apply this transform *before* filtering, otherwise
    /// the filter's reindex invalidates the keys.
    ///
    /// For each `(staff, rawType)`:
    /// - If the staff's measure 0, voice 0, element 0 is an explicit
    ///   `<Clef>` voice element, that element's `concertClefType` is
    ///   rewritten to `rawType`. The `transposingClefType` is cleared
    ///   so the override doesn't collide with a stale transpose.
    /// - Otherwise `Staff.defaultClefType = rawType`. The layout
    ///   engine synthesizes the opening clef from this when no
    ///   explicit measure-0 clef is present.
    ///
    /// Mid-score clef changes (any explicit `<Clef>` element at position other than measure 0 / voice 0 / element 0)
    /// are not touched.
    ///
    /// Overrides targeting staves that don't exist in this score are skipped silently — no error, no crash.
    public func applying(clefOverrides: [StaffAddress: String]) -> Score {
        guard !clefOverrides.isEmpty else { return self }
        var copy = self
        for (address, rawType) in clefOverrides {
            guard copy.parts.indices.contains(address.partIndex) else { continue }
            guard copy.parts[address.partIndex].staves.indices
                .contains(address.staffIndexInPart) else { continue }
            let p = address.partIndex
            let s = address.staffIndexInPart
            if let firstElement = copy.parts[p].staves[s]
                .measures.first?.voices.first?.elements.first,
                case .clef = firstElement
            {
                copy.parts[p].staves[s].measures[0].voices[0].elements[0] =
                    .clef(Clef(concertClefType: rawType))
            } else {
                copy.parts[p].staves[s].defaultClefType = rawType
            }
        }
        return copy
    }
}
