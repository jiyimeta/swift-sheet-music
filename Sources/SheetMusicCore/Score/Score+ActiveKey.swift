import SheetMusicFoundation

extension Score {
    /// Concert-key value (`-7…+7`; flats negative) in effect at the
    /// given staff / measure location. Walks the staff's measures up
    /// to and including `measureIndex`, returning the most recent
    /// `<KeySig>` element on voice 0; falls back to 0 (C major /
    /// A minor) when the staff has no key declarations.
    ///
    /// MuseScore's read path attaches key signatures to specific
    /// ticks; this helper coarsens to per-measure resolution because
    /// arrow-key transposition operates on the note's measure as a
    /// whole. Mid-measure key changes (rare in practice) take effect
    /// from the start of their measure here.
    public func activeKey(staff: StaffAddress, measureIndex: Int) -> Int {
        guard let s = self[staff] else { return 0 }
        let measures = s.measures
        let upperBound = min(measureIndex + 1, measures.count)
        var current = 0
        for idx in 0 ..< upperBound {
            guard let leadingVoice = measures[idx].voices.first else {
                continue
            }
            for el in leadingVoice.elements {
                if case let .keySignature(k) = el {
                    current = k.concertKey
                }
            }
        }
        return current
    }

    /// Convenience: active key for the staff/measure that contains
    /// `noteID`. Equivalent to
    /// `activeKey(staff: noteID.staff,
    ///            measureIndex: noteID.measureIndex)`.
    public func activeKey(at noteID: NoteID) -> Int {
        activeKey(
            staff: noteID.staff,
            measureIndex: noteID.measureIndex,
        )
    }
}
