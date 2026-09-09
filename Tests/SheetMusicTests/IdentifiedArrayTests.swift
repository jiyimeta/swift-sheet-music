@testable import SheetMusicCore
import Testing

@Suite("IdentifiedArray reading")
struct IdentifiedArrayReadingTests {
    private func sample() -> IdentifiedArray<String> {
        IdentifiedArray([
            (EID(first: 1, second: 1), "a"),
            (EID(first: 1, second: 2), "b"),
            (EID(first: 1, second: 3), "c"),
        ])
    }

    @Test func readsLikeAPlainArrayOfValues() {
        let array = sample()
        #expect(array.count == 3)
        #expect(array[1] == "b")
        #expect(Array(array) == ["a", "b", "c"])
        #expect(array.map { $0.uppercased() } == ["A", "B", "C"])
        #expect(array.first(where: { $0 == "c" }) == "c")
        #expect(array.indices.map { array[$0] } == ["a", "b", "c"])
    }

    @Test func exposesTheIdentityOfEachSlot() {
        let array = sample()
        #expect(array.eid(at: 0) == EID(first: 1, second: 1))
        #expect(array.index(of: EID(first: 1, second: 3)) == 2)
        #expect(array.index(of: EID(first: 9, second: 9)) == nil)
        #expect(array[eid: EID(first: 1, second: 2)] == "b")
        #expect(array[eid: EID(first: 9, second: 9)] == nil)
    }

    @Test func equalityComparesValuesAndIgnoresIdentity() {
        // Two independent parses of the same file mint different identifiers.
        // Score equality must keep meaning what it means today.
        let left = IdentifiedArray([
            (EID(first: 1, second: 1), "a"),
            (EID(first: 1, second: 2), "b"),
        ])
        let right = IdentifiedArray([
            (EID(first: 5, second: 40), "a"),
            (EID(first: 5, second: 41), "b"),
        ])
        #expect(left == right)
    }

    @Test func arrayLiteralsProduceUnassignedSlots() {
        // 2107 construction sites across Sources and Tests keep compiling
        // because of this; the identifiers arrive later, at a chokepoint.
        let array: IdentifiedArray<String> = ["a", "b"]
        #expect(Array(array) == ["a", "b"])
        #expect(array.hasUnassignedIDs)
        #expect(array.eid(at: 0) == EID.invalid)
    }

    @Test func anArrayOfPairsIsFullyAssigned() {
        #expect(sample().hasUnassignedIDs == false)
    }

    @Test func lookupIgnoresUnassignedSlots() {
        // Every unassigned slot holds `EID.invalid`, so asking for the
        // invalid identifier must not return the first unassigned element.
        let array: IdentifiedArray<String> = ["a", "b"]
        #expect(array.index(of: .invalid) == nil)
        #expect(array[eid: .invalid] == nil)
    }
}

@Suite("IdentifiedArray restructuring")
struct IdentifiedArrayRestructuringTests {
    private let a = EID(first: 1, second: 1)
    private let b = EID(first: 1, second: 2)
    private let c = EID(first: 1, second: 3)

    private func sample() -> IdentifiedArray<String> {
        IdentifiedArray([(a, "a"), (b, "b"), (c, "c")])
    }

    @Test func changingAValueKeepsTheSlotsIdentity() {
        var array = sample()
        array.setValue("B", at: b)
        #expect(Array(array) == ["a", "B", "c"])
        #expect(array.eid(at: 1) == b)
    }

    @Test func updatingInPlaceKeepsTheSlotsIdentity() {
        var array = sample()
        array.updateValue(at: 1) { $0 = $0.uppercased() }
        #expect(Array(array) == ["a", "B", "c"])
        #expect(array.eid(at: 1) == b)
    }

    @Test func mappingValuesKeepsEveryIdentity() {
        var array = sample()
        array.mapValues { $0.uppercased() }
        #expect(Array(array) == ["A", "B", "C"])
        #expect((0 ..< 3).map { array.eid(at: $0) } == [a, b, c])
    }

    @Test func insertingAfterAnIdentifierPlacesAndNamesTheNewSlot() {
        var array = sample()
        let new = EID(first: 1, second: 4)
        array.insert("b2", after: b, id: new)
        #expect(Array(array) == ["a", "b", "b2", "c"])
        #expect(array.eid(at: 2) == new)
    }

    @Test func insertingAfterNilPlacesAtTheFront() {
        var array = sample()
        let new = EID(first: 1, second: 4)
        array.insert("z", after: nil, id: new)
        #expect(Array(array) == ["z", "a", "b", "c"])
        #expect(array.eid(at: 0) == new)
    }

    @Test func removingDropsExactlyThatSlot() {
        var array = sample()
        array.remove(eid: b)
        #expect(Array(array) == ["a", "c"])
        #expect((0 ..< 2).map { array.eid(at: $0) } == [a, c])
    }

    @Test func movingPreservesIdentity() {
        // The reason the whole design exists: a move is one operation, not a
        // delete plus a create.
        var array = sample()
        array.move(eid: a, after: c)
        #expect(Array(array) == ["b", "c", "a"])
        #expect(array.eid(at: 2) == a)
        #expect(array.index(of: a) == 2)
    }

    @Test func movingToTheFront() {
        var array = sample()
        array.move(eid: c, after: nil)
        #expect(Array(array) == ["c", "a", "b"])
        #expect(array.eid(at: 0) == c)
    }

    @Test func replacingTakesANewIdentity() {
        var array = sample()
        let new = EID(first: 1, second: 9)
        array.replace(at: b, with: "different", newEID: new)
        #expect(Array(array) == ["a", "different", "c"])
        #expect(array.eid(at: 1) == new)
        #expect(array.index(of: b) == nil)
    }

    @Test func assigningMissingIdentifiersLeavesExistingOnesAlone() {
        var array: IdentifiedArray<String> =
            IdentifiedArray([(a, "a"), (EID.invalid, "b"), (c, "c")])
        var allocator = EIDAllocator(actor: 7, counter: 0)
        array.assignMissingIDs(using: &allocator)
        #expect(array.hasUnassignedIDs == false)
        #expect(array.eid(at: 0) == a)
        #expect(array.eid(at: 2) == c)
        #expect(array.eid(at: 1) == EID(first: 7, second: 1))
        #expect(allocator.counter == 1)
    }

    @Test func operationsOnAnAbsentIdentifierDoNothing() {
        // A no-op is the right answer: the caller is describing a slot that is
        // not here, which under concurrency is an operation that has already
        // been superseded.
        var array = sample()
        let absent = EID(first: 9, second: 9)
        array.setValue("x", at: absent)
        array.remove(eid: absent)
        array.move(eid: absent, after: a)
        array.replace(at: absent, with: "x", newEID: EID(first: 1, second: 9))
        #expect(Array(array) == ["a", "b", "c"])
        #expect((0 ..< 3).map { array.eid(at: $0) } == [a, b, c])
    }

    @Test func anAbsentAnchorPlacesTheElementAtTheEnd() {
        // When the anchor (after:) is not present, the element lands at the
        // end, and the moved slot keeps its identifier.
        var array = sample()
        let absent = EID(first: 9, second: 9)
        let new = EID(first: 1, second: 4)
        // Insert with absent after: should place at end
        array.insert("x", after: absent, id: new)
        #expect(Array(array) == ["a", "b", "c", "x"])
        #expect(array.eid(at: 3) == new)
        // Move with absent after: should place at end and preserve identity
        array.move(eid: a, after: absent)
        #expect(Array(array) == ["b", "c", "x", "a"])
        #expect(array.eid(at: 3) == a)
    }

    @Test func movingAnElementAfterItselfChangesNothing() {
        var array = sample()
        array.move(eid: b, after: b)
        #expect(Array(array) == ["a", "b", "c"])
        #expect(array.eid(at: 0) == a)
        #expect(array.eid(at: 1) == b)
        #expect(array.eid(at: 2) == c)
    }

    @Test func anEmptyArraySupportsAbsentMoveThenInsertion() {
        var array = IdentifiedArray<String>()
        #expect(array.isEmpty)
        #expect(array.hasUnassignedIDs == false)

        // Moving an id that is not present is a harmless no-op, even on an
        // empty array.
        array.move(eid: EID(first: 9, second: 9), after: nil)
        #expect(array.isEmpty)

        array.insert("a", after: nil, id: a)
        #expect(Array(array) == ["a"])
        #expect(array.eid(at: 0) == a)

        array.insert("b", after: a, id: b)
        #expect(Array(array) == ["a", "b"])
        #expect(array.eid(at: 1) == b)
    }
}
