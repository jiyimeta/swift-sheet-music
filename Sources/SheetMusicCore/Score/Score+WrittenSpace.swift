/// Addressing a transposing staff in the space the READER sees.
///
/// A score is stored in concert pitch and rendered through `writtenPitchView()`, so anything phrased in terms of
/// what is on the page — a letter key, an accidental key, a note-name readout — has to cross that transform and
/// come back. `WrittenSpaceCrossing` is the only sanctioned crossing, so the editing paths and the renderer
/// cannot drift onto different respelling rules, and so the range guard on the storing direction lives in exactly
/// one place.
extension Score {
    /// One staff's crossing between the CONCERT values the score stores and the WRITTEN values that staff reads,
    /// resolved for one measure. Obtained from `writtenSpaceCrossing(staff:measureIndex:)`.
    ///
    /// The two directions are deliberately asymmetric. `written(_:)` cannot fail — it describes what the renderer
    /// already draws. `concert(_:)` CAN: it is the direction that stores, and a written pitch perfectly inside
    /// MIDI's `0…127` can sit over a concert pitch that is not (a B♭ clarinet reading its lowest written C♯ would
    /// be stored at concert −1). Every caller that writes to the score has to handle that nil.
    package struct WrittenSpaceCrossing {
        /// Semitones ADDED to a concert pitch to get the written one.
        let pitchOffset: Int
        /// Line-of-fifths steps ADDED to a concert tpc to get the written one.
        let fifthsOffset: Int

        /// True wherever `writtenPitchView()` leaves the music alone, and so the crossing is a no-op: a
        /// concert-pitch part, a `useDrumset` part, a `"percussion"` staff, an address outside the score.
        var isIdentity: Bool {
            pitchOffset == 0 && fifthsOffset == 0
        }

        /// Concert → written: what the staff reads.
        ///
        /// Total on purpose, including at the extremes where `writtenPitchView()` gives up and leaves a note at
        /// its concert pitch under a key signature that DID move. That note already reads wrong on the page;
        /// this reports the spelling the transform was aiming for rather than inventing a second rule for it.
        func written(_ pair: (pitch: Int, tpc: Int)) -> (pitch: Int, tpc: Int) {
            (pair.pitch + pitchOffset, pair.tpc + fifthsOffset)
        }

        /// The pitch half alone — for a reference pitch, which is a sounding height with no spelling attached.
        func writtenPitch(_ pitch: Int) -> Int {
            pitch + pitchOffset
        }

        /// Written → concert: the pair to STORE so the staff goes on reading `pair`. `nil` when that pair would
        /// have to be stored outside MIDI's `0…127`, which is the caller's cue to write nothing at all.
        func concert(_ pair: (pitch: Int, tpc: Int)) -> (pitch: Int, tpc: Int)? {
            let pitch = pair.pitch - pitchOffset
            guard (0 ... 127).contains(pitch) else { return nil }
            return (pitch, pair.tpc - fifthsOffset)
        }
    }

    /// The crossing in force on `address` in `measureIndex` — an identity crossing wherever `writtenPitchView()`
    /// leaves the music alone, including for an address that names no staff.
    ///
    /// The fifths offset is deliberately NOT the instrument's `writtenFifthsOffset`. Whenever the written key has
    /// to be respelled back into the writable `[-7, +7]` range, `writtenPitchView()` moves notes by
    /// `newKey − oldKey` instead: a concert F♯ major (+6) clarinet part wants +8, so it is written in A♭ major
    /// (−4) and its notes move −10 fifths, not +2. Crossing back with the instrument offset there spells the
    /// letter C as a D𝄫 — the right sound on the wrong line.
    ///
    /// Resolved per MEASURE, as the view does: a mid-score key change moves the respelling boundary.
    package func writtenSpaceCrossing(
        staff address: StaffAddress, measureIndex: Int,
    ) -> WrittenSpaceCrossing {
        let identity = WrittenSpaceCrossing(pitchOffset: 0, fifthsOffset: 0)
        guard parts.indices.contains(address.partIndex) else { return identity }
        let instrument = parts[address.partIndex].instrument
        guard instrument.isTransposing, !instrument.useDrumset,
              let staff = self[address], staff.group != "percussion"
        else { return identity }
        let concertKey = activeKey(staff: address, measureIndex: measureIndex)
        let writtenKey = Self.respelledKey(concertKey + instrument.writtenFifthsOffset)
        return WrittenSpaceCrossing(
            pitchOffset: instrument.writtenPitchOffset, fifthsOffset: writtenKey - concertKey,
        )
    }

    /// The WRITTEN `(pitch, tpc)` of `noteID` — the note as the staff reads it, which is what a host spells into a
    /// selection readout. Equals the stored concert pair on a staff that does not transpose. `nil` when the id
    /// names no note.
    ///
    /// Reading it from here rather than adding the instrument's offsets at the call site keeps the host on the
    /// same respelling rule `writtenPitchView()` renders with; see `writtenSpaceCrossing(staff:measureIndex:)`.
    public func writtenSpelling(of noteID: NoteID) -> (pitch: Int, tpc: Int)? {
        guard let note = self[noteID] else { return nil }
        let crossing = writtenSpaceCrossing(staff: noteID.staff, measureIndex: noteID.measureIndex)
        return crossing.written((note.pitch, note.tpc))
    }
}
