import SheetMusicFoundation

/// Writes a clef change before the chord or rest at `target` — MuseScore's palette drop of a clef onto a note.
///
/// If the chord already has a clef in its attachment run (`AdjacentElementSlot`), that clef is replaced in
/// place: its type becomes `clef`, its transposing type is dropped (a stale one would draw a glyph other than the
/// one asked for), and its visibility survives. Otherwise a `.clef` is inserted: at index 0 when the chord is the
/// bar's first timed element — the header clef, ahead of key and time, MuseScore's tick-0 segment order — and
/// otherwise after any mid-bar key / time signature and before the chord's annotations, which is where MuseScore's
/// `Clef` segment falls relative to the `ChordRest` segment at the same tick.
///
/// Writes `concertClefType` only; `transposingClefType` is left `nil`. `SetStaffDefaultClef` remains the command
/// for a staff's opening clef.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` (replace) or `ReplaceVoiceElements` (insert). It
/// > exists to give the operation a domain-meaningful name and to own the placement rule; callers can equally
/// > construct the equivalent primitive directly. See `docs/edit-commands.md`.
public struct SetClef: EditCommand {
    public let target: VoiceElementID
    public let clef: NotatedClef

    public init(before target: VoiceElementID, clef: NotatedClef) {
        self.target = target
        self.clef = clef
    }

    public var affectedLocation: VoiceElementID {
        target
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[target] else { throw Self.refused(.targetNotFound(target)) }
        guard case .chord = element else { throw Self.refused(.wrongElementKind(at: target, expected: .timed)) }
        let ref = VoiceRef(target)
        guard let elements = score[voice: ref]?.elements else { throw Self.refused(.targetNotFound(target)) }
        let run = AdjacentElementSlot.run(.before, of: target.elementIndex, in: elements)
        if let index = run.first(where: { if case .clef = elements[$0] { true } else { false } }),
           case var .clef(existing) = elements[index]
        {
            existing.concertClefType = clef.rawType
            existing.transposingClefType = nil
            return try AdjacentElementSlot.replacing(.clef(existing), at: index, in: ref).apply(to: &score)
        }
        let index = run.lowerBound == 0
            ? 0
            : run.first { AdjacentElementSlot.isAnnotation(elements[$0]) } ?? target.elementIndex
        guard let insert = AdjacentElementSlot.inserting(
            .clef(Clef(concertClefType: clef.rawType)), at: index, in: ref, of: score,
        ) else { throw Self.refused(.targetNotFound(target)) }
        return try insert.apply(to: &score)
    }
}

/// Removes the explicit clef element at `location`. Refused as `.wrongElementKind(expected: .clef)` when the
/// element is anything else — a clef is the one thing this addresses, and a host asking to remove "the clef" at
/// a note should hear that there is none rather than lose the note.
///
/// > Note: This command is sugar over `ReplaceVoiceElements`. See `docs/edit-commands.md`.
public struct RemoveClef: EditCommand {
    public let location: VoiceElementID

    public init(at location: VoiceElementID) {
        self.location = location
    }

    public var affectedLocation: VoiceElementID {
        location
    }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let element = score[location] else { throw Self.refused(.targetNotFound(location)) }
        guard case .clef = element else { throw Self.refused(.wrongElementKind(at: location, expected: .clef)) }
        guard let removal = AdjacentElementSlot.removing(
            at: location.elementIndex, in: VoiceRef(location), of: score,
        ) else { throw Self.refused(.targetNotFound(location)) }
        return try removal.apply(to: &score)
    }
}
