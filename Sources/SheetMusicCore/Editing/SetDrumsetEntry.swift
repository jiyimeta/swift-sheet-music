import SheetMusicFoundation

/// Write (or remove) one pitch's entry in a part's drum kit — MuseScore's `<Drum>`, which says what line the drum
/// sits on and what notehead it wears.
///
/// The reason it is an edit command rather than a mutation: a drum key can be pressed for an instrument the open
/// chart never used, and without an entry the layout engine falls back to the pitched diatonic formula and draws
/// the note on a completely wrong line. Repairing that is a change to the score, and every change to the score in
/// this package is a command — so it undoes, and so an Android host relays it rather than re-deriving it.
///
/// `entry: nil` removes the pitch, which is what the inverse of an add is.
public struct SetDrumsetEntry: EditCommand {
    public let partIndex: Int
    public let pitch: Int
    public let entry: DrumsetEntry?

    public init(partIndex: Int, pitch: Int, entry: DrumsetEntry?) {
        self.partIndex = partIndex
        self.pitch = pitch
        self.entry = entry
    }

    /// The part's instrument is not a voice slot. Element 0 of the part's first staff and first measure is the
    /// nearest honest answer — a host uses this to scroll to what changed, and what changed is that part.
    public var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: partIndex, staffIndexInPart: 0),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
        )
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard score.parts.indices.contains(partIndex) else {
            throw Self.refused(.targetNotFound(affectedLocation))
        }
        let previous = score.parts[partIndex].instrument.drumset[pitch]
        score.parts[partIndex].instrument.drumset[pitch] = entry
        return SetDrumsetEntry(partIndex: partIndex, pitch: pitch, entry: previous)
    }
}
