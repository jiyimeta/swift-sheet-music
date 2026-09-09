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

    @Test func nextNeverReturnsTheInvalidSentinel() {
        // Allocators from init() should never return the sentinel,
        // even over many successive calls.
        for _ in 0 ..< 50 {
            var allocator = EIDAllocator()
            // Pin the boundary where it actually lives: `init()` must never
            // draw an actor of 0 or .max, independent of what the counter
            // does later.
            #expect(allocator.actor != 0)
            #expect(allocator.actor != UInt64.max)
            for _ in 0 ..< 100 {
                #expect(allocator.next() != EID.invalid)
            }
        }

        // Allocators from init(actor:counter:) with legal actors
        // at various counter values, including adjacent to the boundary.
        let testCases: [(actor: UInt64, counter: UInt64)] = [
            (1, 0),
            (1, UInt64.max - 2),
            (1, UInt64.max - 1),
            (7, UInt64.max - 2),
            (7, UInt64.max - 1),
            (99, UInt64.max - 1),
            (UInt64.max - 1, 0),
            (UInt64.max - 1, UInt64.max - 2),
            (UInt64.max - 1, UInt64.max - 1),
        ]

        for (actor, counter) in testCases {
            var allocator = EIDAllocator(actor: actor, counter: counter)
            let id = allocator.next()
            #expect(id != EID.invalid)
        }
    }
}
