@testable import SheetMusicCore
import Testing

@Suite("Allocator high-water invariant")
struct AllocatorHighWaterTests {
    #if DEBUG
        @Test func rejectsIdentifierBeyondLiveCounter() {
            let ids = EIDAllocator(actor: 42, counter: 1)
            let score = Score(division: 480, systemMeasures: IdentifiedArray([
                (EID(first: 42, second: 2), SystemMeasure()),
            ]))
            #expect(!EditingIdentityInvariants.allocatorCovers(score, ids))
        }

        @Test func ignoresForeignActorCounter() {
            let ids = EIDAllocator(actor: 42, counter: 1)
            let score = Score(division: 480, systemMeasures: IdentifiedArray([
                (EID(first: 43, second: .max), SystemMeasure()),
            ]))
            #expect(EditingIdentityInvariants.allocatorCovers(score, ids))
        }

        @Test func acceptsIdentifierAtLiveCounter() {
            let ids = EIDAllocator(actor: 42, counter: 2)
            let score = Score(division: 480, systemMeasures: IdentifiedArray([
                (EID(first: 42, second: 2), SystemMeasure()),
            ]))
            #expect(EditingIdentityInvariants.allocatorCovers(score, ids))
        }
    #endif
}
