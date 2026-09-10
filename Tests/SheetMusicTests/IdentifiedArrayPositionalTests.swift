import SheetMusicCore
import Testing

@Suite("Identified array positional operations")
struct IdentifiedArrayPositionalTests {
    private let first = EID(first: 42, second: 1)
    private let second = EID(first: 42, second: 2)
    private let third = EID(first: 42, second: 3)
    private let fourth = EID(first: 42, second: 4)

    private func identifiers(_ array: IdentifiedArray<Int>) -> [EID] {
        array.indices.map { array.eid(at: $0) }
    }

    @Test func insertAssignsSuppliedIdentifier() {
        var array = IdentifiedArray([(first, 10), (third, 30)])
        array.insert(20, at: 1, id: second)
        #expect(array.values == [10, 20, 30])
        #expect(identifiers(array) == [first, second, third])
    }

    @Test func insertContentsAssignsSuppliedIdentifiers() {
        var array = IdentifiedArray([(first, 10), (fourth, 40)])
        array.insert(contentsOf: [(second, 20), (third, 30)], at: 1)
        #expect(array.values == [10, 20, 30, 40])
        #expect(identifiers(array) == [first, second, third, fourth])
    }

    @Test func replaceSubrangeAssignsSuppliedIdentifiers() {
        var array = IdentifiedArray([(first, 10), (second, 20), (fourth, 40)])
        array.replaceSubrange(1 ..< 2, with: [(third, 30)])
        #expect(array.values == [10, 30, 40])
        #expect(identifiers(array) == [first, third, fourth])
    }

    @Test func replaceSubrangeCanReuseIdentifierInsideRange() {
        var array = IdentifiedArray([(first, 10), (second, 20), (fourth, 40)])
        array.replaceSubrange(1 ..< 2, with: [(second, 21), (third, 22)])
        #expect(array.values == [10, 21, 22, 40])
        #expect(identifiers(array) == [first, second, third, fourth])
    }

    @Test func removeSubrangeKeepsSurvivingIdentifiers() {
        var array = IdentifiedArray([(first, 10), (second, 20), (third, 30), (fourth, 40)])
        array.removeSubrange(1 ..< 3)
        #expect(array.values == [10, 40])
        #expect(identifiers(array) == [first, fourth])
    }

    @Test func removeAllKeepsSurvivingIdentifiers() {
        var array = IdentifiedArray([(first, 10), (second, 20), (third, 30), (fourth, 40)])
        array.removeAll { $0.isMultiple(of: 20) }
        #expect(array.values == [10, 30])
        #expect(identifiers(array) == [first, third])
    }

    @Test func removeSubrangeSupportsUnassignedSlots() {
        var array = IdentifiedArray([10, 20, 30, 40])
        array.removeSubrange(1 ..< 3)
        #expect(array.values == [10, 40])
        #expect(identifiers(array) == [.invalid, .invalid])
    }

    @Test func removeAllSupportsUnassignedSlots() {
        var array = IdentifiedArray([10, 20, 30, 40])
        array.removeAll { $0.isMultiple(of: 20) }
        #expect(array.values == [10, 30])
        #expect(identifiers(array) == [.invalid, .invalid])
    }

    @Test func anchorNamesPrecedingSlot() {
        let array = IdentifiedArray([(first, 10), (second, 20), (third, 30)])
        #expect(array.anchor(before: 0) == nil)
        for index in 1 ... array.endIndex {
            #expect(array.anchor(before: index) == array.eid(at: index - 1))
        }
        #expect(array.values == [10, 20, 30])
        #expect(identifiers(array) == [first, second, third])
    }
}
