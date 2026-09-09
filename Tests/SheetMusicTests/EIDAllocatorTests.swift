@testable import SheetMusicCore
import Testing

@Suite("EIDAllocator")
struct EIDAllocatorTests {
    @Test func mintsAscendingCountersUnderOneActor() {
        var allocator = EIDAllocator(actor: 7, counter: 0)
        let a = allocator.next()
        let b = allocator.next()
        #expect(a == EID(first: 7, second: 1))
        #expect(b == EID(first: 7, second: 2))
    }

    @Test func neverMintsTheSameIdentifierTwice() {
        var allocator = EIDAllocator(actor: 7, counter: 0)
        var seen: Set<EID> = []
        for _ in 0 ..< 1000 {
            #expect(seen.insert(allocator.next()).inserted)
        }
        #expect(seen.count == 1000)
    }

    @Test func mintedIdentifiersAreValid() {
        var allocator = EIDAllocator()
        #expect(allocator.next().isValid)
    }

    @Test func aCopyThatAdvancesDoesNotAdvanceTheOriginal() {
        // The allocator is a value, and P2's commands pass it in and out.
        // Planners work on a copy; this documents what a copy does.
        var original = EIDAllocator(actor: 7, counter: 0)
        var copy = original
        _ = copy.next()
        #expect(original.counter == 0)
        #expect(original.next() == EID(first: 7, second: 1))
    }

    @Test func drawsAnActorThatCannotCollideWithTheInvalidSentinel() {
        for _ in 0 ..< 100 {
            let allocator = EIDAllocator()
            #expect(allocator.actor != UInt64.max)
            #expect(allocator.actor != 0)
        }
    }
}
