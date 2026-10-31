extension Chord {
    /// The grace slot MuseScore's `Chord::graceIndex()` `index` names, or `nil` when the chord has no such grace.
    ///
    /// MuseScore keeps one grace vector per chord, numbered in the order the file lists the graces ahead of their
    /// chord (`rw/read460/measureread.cpp`, `setGraceIndex(i)` over the buffered run). This package writes that run
    /// as `graceNotesBefore` left to right, then `graceNotesAfter` right to left — `Chord::graceNotesAfter()` reads
    /// the vector backwards (`dom/chord.cpp`), so the after-run is stored back to front relative to how it sounds.
    /// This is the inverse of `museScoreGraceIndex(side:index:)`, and both agree with the order the MSCX encoder
    /// writes graces in, which is what makes a `<grace>` it writes name the grace it means.
    public func grace(atMuseScoreGraceIndex index: Int) -> (side: GraceNoteID.Side, index: Int)? {
        guard index >= 0 else { return nil }
        if index < graceNotesBefore.count { return (.before, index) }
        let fromEnd = index - graceNotesBefore.count
        guard fromEnd < graceNotesAfter.count else { return nil }
        return (.after, graceNotesAfter.count - 1 - fromEnd)
    }

    /// MuseScore's `Chord::graceIndex()` of the grace at `index` in the list `side` names — the number a
    /// `<location><grace>` carries for it. See `grace(atMuseScoreGraceIndex:)`.
    public func museScoreGraceIndex(side: GraceNoteID.Side, index: Int) -> Int {
        switch side {
        case .before: index
        case .after: graceNotesBefore.count + (graceNotesAfter.count - 1 - index)
        }
    }
}
