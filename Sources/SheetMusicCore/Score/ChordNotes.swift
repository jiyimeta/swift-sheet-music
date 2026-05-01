import Foundation

/// A pitch-unique ordered collection of `Note`s belonging to a
/// single `Chord`.
///
/// Type-level invariant: **no two notes in a chord can share the
/// same MIDI `pitch`.** Every mutation path (init, `append`,
/// subscript set, `replaceSubrange`, …) silently dedupes,
/// keeping the first occurrence of each pitch. The score model
/// can never reach a state where two notes of a chord have the
/// same pitch, no matter how callers mutate it.
///
/// The type behaves like `Array<Note>` for the patterns used in
/// this codebase — `RandomAccessCollection`, `MutableCollection`,
/// `RangeReplaceableCollection`, and `ExpressibleByArrayLiteral`
/// conformances mean call sites such as `chord.notes.first`,
/// `chord.notes[i]`, `chord.notes.append(...)`, and
/// `for n in chord.notes` keep working without changes. The
/// dedup happens behind the scenes.
///
/// When a caller wants explicit feedback on whether a mutation
/// succeeded (e.g. to surface "this pitch already exists" in the
/// UI) it should use the `tryAppend(_:)` and `updateNote(at:_:)`
/// APIs which return `Bool`.
public struct ChordNotes: Sendable, Equatable {
    @usableFromInline internal var storage: [Note]

    public init() {
        self.storage = []
    }

    @inlinable
    public init<S: Sequence>(_ sequence: S) where S.Element == Note {
        var seen = Set<Int>()
        self.storage = []
        for note in sequence where seen.insert(note.pitch).inserted {
            self.storage.append(note)
        }
    }

    /// Append a note. Returns `false` and leaves the chord
    /// unchanged when a note with the same `pitch` already
    /// exists. Distinct from `append(_:)` from
    /// `RangeReplaceableCollection`, which silently no-ops on
    /// duplicates and returns `Void`.
    @discardableResult
    public mutating func tryAppend(_ note: Note) -> Bool {
        guard !contains(where: { $0.pitch == note.pitch })
        else { return false }
        storage.append(note)
        return true
    }

    /// In-place mutation of the note at `index`. The closure can
    /// freely change any field; if it produces a pitch that
    /// collides with another note in the chord the change is
    /// rolled back and the chord is left untouched.
    /// Returns `true` when the mutation was applied.
    @discardableResult
    public mutating func updateNote(
        at index: Int, _ transform: (inout Note) -> Void
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
}

// MARK: - Sequence / Collection / MutableCollection

extension ChordNotes: RandomAccessCollection, MutableCollection {
    public typealias Index = Int
    public typealias Element = Note

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }

    public func index(after i: Int) -> Int { storage.index(after: i) }
    public func index(before i: Int) -> Int { storage.index(before: i) }
    public func index(_ i: Int, offsetBy distance: Int) -> Int {
        storage.index(i, offsetBy: distance)
    }
    public func distance(from start: Int, to end: Int) -> Int {
        storage.distance(from: start, to: end)
    }

    /// Subscript get returns the note as-is. Subscript set drops
    /// the assignment when it would create a duplicate pitch in
    /// the chord — silent no-op rather than trap so production
    /// callers don't crash on adversarial input. Use
    /// `updateNote(at:_:)` or `tryAppend(_:)` when an explicit
    /// success/failure signal is needed.
    public subscript(position: Int) -> Note {
        get { storage[position] }
        set {
            if storage.indices.contains(where: {
                $0 != position && storage[$0].pitch == newValue.pitch
            }) {
                return
            }
            storage[position] = newValue
        }
    }
}

// MARK: - RangeReplaceableCollection

extension ChordNotes: RangeReplaceableCollection {
    public mutating func replaceSubrange<C, R>(
        _ subrange: R, with newElements: C
    ) where C: Collection, C.Element == Note,
            R: RangeExpression, R.Bound == Int {
        // Build the would-be sequence (existing minus subrange +
        // newElements) then dedupe with the same first-wins rule
        // used in `init(_:)`. Pitches that already exist outside
        // the subrange win; pitches in newElements that appear
        // earlier in newElements win over later duplicates.
        var combined = storage
        combined.replaceSubrange(subrange, with: newElements)
        var seen = Set<Int>()
        storage = combined.filter { seen.insert($0.pitch).inserted }
    }
}

// MARK: - ExpressibleByArrayLiteral

extension ChordNotes: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Note...) {
        self.init(elements)
    }
}
