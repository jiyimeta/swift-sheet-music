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
