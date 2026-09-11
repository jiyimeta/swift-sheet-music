import SheetMusicFoundation

extension Score {
    /// The clef a reader is under at `location` — the last clef declared at or before it on that staff, or the
    /// staff's opening clef when no `<Clef>` element precedes it.
    ///
    /// Distinct from `authoredClef(at:)`, which answers only for the START of a staff: this one carries mid-score
    /// clef changes forward, so a cello part that drops into treble at bar 40 reads treble from bar 40 on. Note
    /// input needs that — the octave a letter key writes has to follow the clef the user is actually looking at,
    /// not the one the staff opened with.
    ///
    /// Clefs live in voice 0 (`SetClef` writes them there and layout reads them from there), so only voice 0 is
    /// scanned whatever voice `location` names. A clef placed at element index `i` governs the elements from `i`
    /// onward — `SetClef(before:)`'s meaning — so a clef sharing the location's index counts, and one after it does
    /// not. Falls back to `.treble`, which is `NotatedClef(rawType:)`'s own answer for anything it cannot parse.
    public func clefInForce(at location: VoiceElementID) -> NotatedClef {
        guard let staff = self[location.staff] else { return .treble }
        var rawType = staff.defaultClefType
        let lastMeasure = min(location.measureIndex, staff.measures.count - 1)
        guard lastMeasure >= 0 else { return NotatedClef(rawType: rawType ?? "") }
        for measureIndex in 0 ... lastMeasure {
            let elements = staff.measures[measureIndex].voices.first?.elements ?? []
            for (elementIndex, element) in elements.enumerated() {
                // Past the caret in its own bar: a clef the user has not reached yet does not spell what they type.
                if measureIndex == location.measureIndex, elementIndex > location.elementIndex { break }
                if case let .clef(clef) = element { rawType = clef.concertClefType }
            }
        }
        return NotatedClef(rawType: rawType ?? "")
    }
}
