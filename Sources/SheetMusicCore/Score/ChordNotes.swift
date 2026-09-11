import SheetMusicFoundation

/// A pitch-unique ordered collection of `Note`s belonging to a
/// single `Chord`.
///
/// Type-level invariant: **no two notes in a chord can share the
/// same MIDI `pitch`.** The two initializers and `mapValues` silently
/// dedupe, keeping the first occurrence of each pitch and dropping
/// the rest (and their identifiers) with it. `updateNote` and
/// `tryAppend` do NOT dedupe — a mutation that would introduce a
/// colliding pitch is refused outright and the chord is left
/// untouched, rather than silently resolved. The score model can
/// never reach a state where two notes of a chord have the same
/// pitch, no matter how callers mutate it — but which of those two
/// responses a caller gets depends on the method.
///
/// Every slot also carries an `EID` — see `IdentifiedArray`'s doc
/// comment for the general shape this follows: parallel storage/id
/// arrays, `RandomAccessCollection` with a get-only subscript,
/// `ExpressibleByArrayLiteral` producing unassigned slots, and
/// `Equatable` over values only, so two independent parses of one
/// file stay equal. `ChordNotes` is a bespoke type rather than an
/// `IdentifiedArray<Note>` because it also has to enforce pitch
/// uniqueness on every mutation, including two paths
/// (`tryAppend`, `mapValues`) that `IdentifiedArray` doesn't have at
/// all — a duplicate pitch drops the later slot AND its identifier
/// together, which is not a rule the generic type could express.
///
/// The type behaves like `Array<Note>` for the read patterns used in
/// this codebase — `RandomAccessCollection` and
/// `ExpressibleByArrayLiteral` mean call sites such as
/// `chord.notes.first`, `chord.notes[i]`, and `for n in chord.notes`
/// keep working unchanged. There is no mutable subscript and no
/// `RangeReplaceableCollection` conformance: every write goes
/// through a named method, so a caller can't drop a slot's identity
/// (or its pitch-uniqueness) by assigning through `notes[i] = note`
/// without saying so.
///
/// `storage` and `ids` are `@usableFromInline var`, not `private` —
/// the type's no-mutable-subscript guarantee holds only across the
/// module boundary. Inside `SheetMusicCore` a caller can still write
/// `notes.ids[i]` directly; the identity invariant tests use exactly
/// that hatch to forge collisions on purpose, to exercise the gates
/// that are supposed to catch them.
public struct ChordNotes: Sendable {
    @usableFromInline var storage: [Note]
    @usableFromInline var ids: [EID]

    public init() {
        storage = []
        ids = []
    }

    /// Every slot unassigned. The identifiers arrive at a chokepoint —
    /// `assignMissingIDs(using:)` — the same as `IdentifiedArray.init(_:)`.
    @inlinable
    public init<S: Sequence>(_ sequence: S) where S.Element == Note {
        var seen = Set<Int>()
        storage = []
        for note in sequence where seen.insert(note.pitch).inserted {
            storage.append(note)
        }
        ids = Array(repeating: .invalid, count: storage.count)
    }

    /// Pairs carry their own identifiers. A duplicate pitch is dropped
    /// first-wins, same as `init(_:)`, and the dropped slot's
    /// identifier goes with it.
    public init(_ pairs: [(EID, Note)]) {
        assert(
            Set(pairs.map(\.0).filter(\.isValid)).count == pairs.filter(\.0.isValid).count,
            "duplicate assigned identifiers",
        )
        var seen = Set<Int>()
        storage = []
        ids = []
        for (id, note) in pairs where seen.insert(note.pitch).inserted {
            storage.append(note)
            ids.append(id)
        }
    }

    /// Read-only access to the stored notes for consumers that do not
    /// need slot identity. There is deliberately no public setter —
    /// see `IdentifiedArray.values` for why.
    public var values: [Note] {
        storage
    }

    /// Slots whose identifier has not been assigned yet.
    public var hasUnassignedIDs: Bool {
        ids.contains { !$0.isValid }
    }

    public func eid(at position: Int) -> EID {
        ids[position]
    }

    public func index(of eid: EID) -> Int? {
        guard eid.isValid else { return nil }
        return ids.firstIndex(of: eid)
    }

    public subscript(eid eid: EID) -> Note? {
        guard let index = index(of: eid) else { return nil }
        return storage[index]
    }

    /// Fill every unassigned slot. Called at the points that produce a
    /// score, never as a cleanup after an edit — an edit that dropped
    /// identifiers must fail loudly rather than be silently renumbered.
    public mutating func assignMissingIDs(using allocator: inout EIDAllocator) {
        for index in ids.indices where !ids[index].isValid {
            ids[index] = allocator.next()
        }
    }

    /// In-place mutation of the note at `index`. The closure can
    /// freely change any field; if it produces a pitch that collides
    /// with another note in the chord the change is rolled back and
    /// the chord is left untouched. The slot keeps its identifier
    /// either way. Returns `true` when the mutation was applied.
    @discardableResult
    public mutating func updateNote(
        at index: Int, _ transform: (inout Note) -> Void,
    ) -> Bool {
        var copy = storage[index]
        transform(&copy)
        if storage.indices.contains(where: {
            $0 != index && storage[$0].pitch == copy.pitch
        }) {
            return false
        }
        storage[index] = copy
        return true
    }

    /// In-place edit of every note. Used by transposition, which can
    /// map two distinct pitches onto one. Keeps first-wins: the
    /// surviving slot keeps ITS OWN identifier, and the later slot —
    /// and its identifier — is dropped.
    ///
    /// Returns the identifiers of slots the transform collided away —
    /// empty in the normal case. A silently vanished note would
    /// otherwise be invisible to every gate, so `mapValues` reports
    /// what it dropped, which is exactly why it returns the list.
    /// Display and playback callers discard it; a future editing
    /// caller can refuse on a non-empty one. `init(_ pairs:)` drops an
    /// identifier the same way on a duplicate pitch, but with no
    /// return value pointing at it — that initializer is now the
    /// type's one place where an identifier can still disappear
    /// without the caller learning which one.
    @discardableResult
    public mutating func mapValues(_ body: (Note) -> Note) -> [EID] {
        storage = storage.map(body)
        return dedupingByPitch()
    }

    /// Append a note. Returns `false` and leaves the chord unchanged
    /// when a note with the same `pitch` already exists.
    ///
    /// The caller supplies the identifier from its allocator so
    /// replay is deterministic. On refusal nothing is minted lazily
    /// inside — the caller's allocator has already advanced, which is
    /// fine (a burnt counter is not a duplicate identifier).
    @discardableResult
    public mutating func tryAppend(_ note: Note, id: EID) -> Bool {
        assert(id.isValid, "tryAppend requires an assigned identifier")
        assert(index(of: id) == nil, "identifier already present — appending it would duplicate")
        guard !storage.contains(where: { $0.pitch == note.pitch })
        else { return false }
        storage.append(note)
        ids.append(id)
        return true
    }

    public mutating func remove(eid: EID) {
        guard let index = index(of: eid) else { return }
        storage.remove(at: index)
        ids.remove(at: index)
    }

    /// Keep the first occurrence of each pitch, in current storage
    /// order, and report the identifiers of whatever was dropped.
    @discardableResult
    private mutating func dedupingByPitch() -> [EID] {
        var seen = Set<Int>()
        var newStorage: [Note] = []
        var newIDs: [EID] = []
        var dropped: [EID] = []
        newStorage.reserveCapacity(storage.count)
        newIDs.reserveCapacity(ids.count)
        for (note, id) in zip(storage, ids) {
            if seen.insert(note.pitch).inserted {
                newStorage.append(note)
                newIDs.append(id)
            } else {
                dropped.append(id)
            }
        }
        storage = newStorage
        ids = newIDs
        return dropped
    }
}

// MARK: - Sequence / Collection

extension ChordNotes: RandomAccessCollection {
    public typealias Index = Int
    public typealias Element = Note

    public var startIndex: Int {
        storage.startIndex
    }

    public var endIndex: Int {
        storage.endIndex
    }

    /// Get-only. There is no setter — see the type's doc comment for why.
    public subscript(position: Int) -> Note {
        storage[position]
    }
}

// MARK: - ExpressibleByArrayLiteral

extension ChordNotes: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Note...) {
        self.init(elements)
    }
}

// MARK: - Equatable

extension ChordNotes: Equatable {
    /// Values only. Two independent parses of one file mint different
    /// identifiers, and score equality must not start reporting them
    /// unequal.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage == rhs.storage
    }
}
