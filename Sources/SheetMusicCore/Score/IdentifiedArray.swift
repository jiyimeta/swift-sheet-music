import SheetMusicFoundation

/// An ordered sequence whose *slots* carry identity.
///
/// The identifier lives on the slot rather than inside the element's value
/// type, so `Chord`, `Note`, and their neighbours are unchanged and equality,
/// the encoders, the fingerprint, and the corpus gates keep their present
/// meaning.
///
/// Two conformances are deliberately absent. Without `MutableCollection` and
/// `RangeReplaceableCollection`, `append`, `insert(_:at:)`, `remove(at:)`, and
/// `array[i] = value` do not compile — every site that restructures a sequence
/// or replaces an element wholesale becomes a compile error, and deciding
/// whether identity carries over stops being something a caller can forget.
///
/// `Element` *is* `Value` rather than a wrapper, so reading — iteration,
/// integer subscripting, `count`, `map`, `filter` — compiles unchanged.
public struct IdentifiedArray<Value: Sendable & Equatable>: Sendable {
    private var ids: [EID]
    /// Read-only access to the stored array for consumers that do not need slot identity.
    /// Array COW avoids an eager copy, and concrete consumers avoid extra generic specialization.
    /// There is deliberately no public setter: rebuilding this collection from a mutated
    /// array would create all-unassigned slots. The editing entry points assert on exit
    /// instead of filling those slots and hiding the lost identity.
    public private(set) var values: [Value]

    public init() {
        ids = []
        values = []
    }

    /// Every slot unassigned. The identifiers arrive at a chokepoint.
    public init(_ values: [Value]) {
        self.values = values
        ids = Array(repeating: .invalid, count: values.count)
    }

    public init(_ pairs: [(EID, Value)]) {
        ids = pairs.map(\.0)
        values = pairs.map(\.1)
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

    public subscript(eid eid: EID) -> Value? {
        guard let index = index(of: eid) else { return nil }
        return values[index]
    }
}

extension IdentifiedArray: RandomAccessCollection {
    public typealias Element = Value
    public typealias Index = Int

    public var startIndex: Int {
        values.startIndex
    }

    public var endIndex: Int {
        values.endIndex
    }

    public subscript(position: Int) -> Value {
        values[position]
    }
}

extension IdentifiedArray: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Value...) {
        self.init(elements)
    }
}

extension IdentifiedArray: Equatable {
    /// Values only. Two independent parses of one file mint different
    /// identifiers, and score equality must not start reporting them unequal.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.values == rhs.values
    }
}

// MARK: - Changing a value

extension IdentifiedArray {
    /// The same element, changed. The slot keeps its identifier.
    public mutating func setValue(_ value: Value, at eid: EID) {
        guard let index = index(of: eid) else { return }
        values[index] = value
    }

    /// In-place edit of one slot's value. The slot keeps its identifier.
    public mutating func updateValue(
        at position: Int, _ body: (inout Value) -> Void,
    ) {
        body(&values[position])
    }

    /// In-place edit of every value. Every slot keeps its identifier.
    public mutating func mapValues(_ body: (Value) -> Value) {
        for index in values.indices {
            values[index] = body(values[index])
        }
    }
}

// MARK: - Restructuring

extension IdentifiedArray {
    /// The anchor-resolution rule shared by `insert` and `move`: after the
    /// named slot, at the front when `target` is nil, or at the end when the
    /// anchor identifier is not present.
    private func insertionIndex(after target: EID?) -> Int {
        if let target, let index = index(of: target) {
            return index + 1
        }
        return target == nil ? 0 : values.endIndex
    }

    /// Insert after the named slot, or at the front when `after` is nil.
    /// When the anchor identifier is not present, the element lands at the end.
    /// The new slot's identifier is supplied by the caller, so a command and
    /// its replay produce the same identifier. In debug builds, this asserts
    /// that `id` is assigned and not already present in the array, and that
    /// a non-nil `after` is itself assigned (an unassigned anchor names
    /// nothing and is a programming error, not a synonym for "absent").
    public mutating func insert(_ value: Value, after eid: EID?, id: EID) {
        assert(id.isValid, "insert requires an assigned identifier")
        assert(index(of: id) == nil, "identifier already present — inserting it would duplicate")
        assert(eid?.isValid != false, "an anchor identifier, when given, must be assigned")
        let position = insertionIndex(after: eid)
        values.insert(value, at: position)
        ids.insert(id, at: position)
    }

    public mutating func remove(eid: EID) {
        guard let index = index(of: eid) else { return }
        values.remove(at: index)
        ids.remove(at: index)
    }

    /// One operation, not a removal and an insertion: the moved slot keeps
    /// its identifier, which is what lets an operation log say "this element
    /// moved" rather than "one vanished and another appeared".
    /// When `after` is nil, the element moves to the front. When the anchor
    /// identifier is not present, the element lands at the end. In debug
    /// builds, this asserts that a non-nil `target` is itself assigned (an
    /// unassigned anchor names nothing and is a programming error, not a
    /// synonym for "absent").
    public mutating func move(eid: EID, after target: EID?) {
        assert(target?.isValid != false, "an anchor identifier, when given, must be assigned")
        guard let from = index(of: eid) else { return }
        guard target != eid else { return }
        let value = values.remove(at: from)
        let id = ids.remove(at: from)
        // Resolve the anchor AFTER the subject has been removed — the
        // shifted-index semantics this relies on are covered by the
        // restructuring tests.
        let position = insertionIndex(after: target)
        values.insert(value, at: position)
        ids.insert(id, at: position)
    }

    /// A different element in the same place, so it takes a new identifier.
    /// In debug builds, this asserts that `newEID` is assigned and not
    /// already present elsewhere in the array.
    public mutating func replace(
        at eid: EID, with value: Value, newEID: EID,
    ) {
        assert(newEID.isValid, "replace requires an assigned identifier")
        assert(
            newEID == eid || index(of: newEID) == nil,
            "identifier already present — replacing would duplicate",
        )
        guard let index = index(of: eid) else { return }
        values[index] = value
        ids[index] = newEID
    }

    /// Fill every unassigned slot. Called at the points that produce a score,
    /// never as a cleanup after an edit — an edit that dropped identifiers
    /// must fail loudly rather than be silently renumbered.
    public mutating func assignMissingIDs(using allocator: inout EIDAllocator) {
        for index in ids.indices where !ids[index].isValid {
            ids[index] = allocator.next()
        }
    }
}
