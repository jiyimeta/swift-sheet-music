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
    private var values: [Value]

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
