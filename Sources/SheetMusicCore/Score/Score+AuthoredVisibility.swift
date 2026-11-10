import SheetMusicFoundation

extension Score {
    /// The address of every staff the file itself hides in the score: all staves of a part whose
    /// `Part.isVisibleInScore` is false (MuseScore's `<Part><show>0</show>`, the instrument's eye), and each staff
    /// whose own `Staff.isVisibleInScore` is false (`<isStaffVisible>0</isStaffVisible>`, one staff's eye — the left
    /// hand of a piano, say).
    ///
    /// The layout engine draws every staff regardless; this is what a host seeds into its hidden-staff set so a
    /// score opens the way its author left it, while the staves stay revealable and audible. One derivation, so the
    /// Apple, Android (`StaffWire.isAuthoredHidden`) and Windows hosts cannot disagree about which staves those are.
    public var authoredHiddenStaffAddresses: Set<StaffAddress> {
        var hidden: Set<StaffAddress> = []
        for (partIndex, part) in parts.enumerated() {
            for (staffIndexInPart, staff) in part.staves.enumerated()
                where !part.isVisibleInScore || !staff.isVisibleInScore
            {
                hidden.insert(StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndexInPart))
            }
        }
        return hidden
    }
}
