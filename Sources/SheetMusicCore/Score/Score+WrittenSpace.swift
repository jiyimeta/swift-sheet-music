/// Addressing a transposing staff in the space the READER sees.
///
/// A score is stored in concert pitch and rendered through `writtenPitchView()`, so anything phrased in terms of
/// what is on the page — a letter key, an accidental key, a note-name readout — has to cross that transform and
/// come back. These two helpers are the only sanctioned crossing, so the editing paths and the renderer cannot
/// drift onto different respelling rules.
extension Score {
    /// The shift `writtenPitchView()` applies to a concert `(pitch, tpc)` on this staff in this measure: ADD these
    /// to get what the staff reads, SUBTRACT them to come back. `(0, 0)` wherever the view leaves the music alone —
    /// a concert-pitch part, a `useDrumset` part, a `"percussion"` staff, or an address outside the score.
    ///
    /// `fifths` is deliberately NOT the instrument's `writtenFifthsOffset`. Whenever the written key has to be
    /// respelled back into the writable `[-7, +7]` range, `writtenPitchView()` moves notes by `newKey − oldKey`
    /// instead: a concert F♯ major (+6) clarinet part wants +8, so it is written in A♭ major (−4) and its notes
    /// move −10 fifths, not +2. Inverting a written-space answer with the instrument offset there spells the
    /// letter C as a D𝄫 — the right sound on the wrong line.
    ///
    /// Resolved per MEASURE, as the view does: a mid-score key change moves the respelling boundary.
    package func writtenSpaceOffsets(
        staff address: StaffAddress, measureIndex: Int,
    ) -> (pitch: Int, fifths: Int) {
        guard parts.indices.contains(address.partIndex) else { return (0, 0) }
        let instrument = parts[address.partIndex].instrument
        guard instrument.isTransposing, !instrument.useDrumset, self[address]?.group != "percussion" else {
            return (0, 0)
        }
        let concertKey = activeKey(staff: address, measureIndex: measureIndex)
        let writtenKey = Self.respelledKey(concertKey + instrument.writtenFifthsOffset)
        return (instrument.writtenPitchOffset, writtenKey - concertKey)
    }

    /// The WRITTEN `(pitch, tpc)` of `noteID` — the note as the staff reads it, which is what a host spells into a
    /// selection readout. Equals the stored concert pair on a staff that does not transpose. `nil` when the id
    /// names no note.
    ///
    /// Reading it from here rather than adding the instrument's offsets at the call site keeps the host on the
    /// same respelling rule `writtenPitchView()` renders with; see `writtenSpaceOffsets(staff:measureIndex:)`.
    public func writtenSpelling(of noteID: NoteID) -> (pitch: Int, tpc: Int)? {
        guard let note = self[noteID] else { return nil }
        let offsets = writtenSpaceOffsets(staff: noteID.staff, measureIndex: noteID.measureIndex)
        return (note.pitch + offsets.pitch, note.tpc + offsets.fifths)
    }
}
