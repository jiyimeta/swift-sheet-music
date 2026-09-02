@testable import SheetMusicCore
import Testing

@Suite("RangeEditPlanner")
struct RangeEditPlannerTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func id(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    @Test("an onset consumed by an earlier lengthening is skipped, and later targets are re-found by tick")
    func skipsConsumedOnsets() throws {
        let score = EditingFixtures.fourQuarterRests() // [ts, r q, r q, r q, r q]
        var visited: [VoiceElementID] = []
        let plan = try RangeEditPlanner.plan(
            over: VoiceElementRange(start: Self.id(0, 1), end: Self.id(0, 4)), in: score,
        ) { target, _ in
            visited.append(target)
            return [SetRestDuration(at: target, duration: .half)]
        }
        // Element 1 → half consumed element 2 (tick 480); the rest that was element 3 (tick 960) is element 2 now.
        #expect(visited == [Self.id(0, 1), Self.id(0, 2)])
        #expect(plan?.commands.count == 2)
        #expect(plan?.result.parts[0].staves[0].measures[0].voices[0].elements == [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .rest(duration: .half), .rest(duration: .half),
        ])
    }

    @Test("targets are visited voice by voice in ascending onset order")
    func visitsInOnsetOrder() throws {
        var score = EditingFixtures.parityFixture()
        _ = try CreateVoice(staff: Self.staff0, measureIndex: 0, voiceIndex: 1).apply(to: &score)
        var visited: [VoiceElementID] = []
        _ = try RangeEditPlanner.plan(
            over: VoiceElementRange(start: Self.id(0, 1), end: Self.id(0, 4)), in: score,
        ) { target, _ in
            visited.append(target)
            return []
        }
        #expect(visited == [Self.id(0, 1), Self.id(0, 2), Self.id(0, 3), Self.id(0, 4), Self.id(0, 0, voice: 1)])
    }

    @Test("a step that throws propagates, and the composite is never built")
    func throwingStepPropagates() {
        // Element 1 is a C4 quarter chord, and `SetRestDuration` refuses anything with noteheads on it. (The
        // brief's `SetChordDuration` on a rest does NOT refuse here: `.rest` is `.chord` with no notes, so the
        // duration commands differ by a `notes.isEmpty` check that only `SetRestDuration` makes.)
        let score = EditingFixtures.chordAtIndex1()
        #expect(throws: SheetMusicError.self) {
            _ = try RangeEditPlanner.plan(
                over: VoiceElementRange(start: Self.id(0, 1), end: Self.id(0, 1)), in: score,
            ) { target, _ in
                [SetRestDuration(at: target, duration: .half)]
            }
        }
    }

    @Test("a range that resolves to nothing, or produces no command, plans to nil")
    func nothingIsNil() throws {
        let score = EditingFixtures.fourQuarterRests()
        let unresolvable = VoiceElementRange(start: Self.id(0, 1), end: Self.id(3, 0))
        #expect(try RangeEditPlanner.plan(over: unresolvable, in: score) { _, _ in [] } == nil)
        let inert = VoiceElementRange(start: Self.id(0, 1), end: Self.id(0, 4))
        #expect(try RangeEditPlanner.plan(over: inert, in: score) { _, _ in [] } == nil)
    }

    @Test("timedElementIndex finds the element that starts at a tick and nothing else")
    func timedElementIndex() throws {
        var score = EditingFixtures.fourQuarterRests()
        _ = try SetRestDuration(at: Self.id(0, 1), duration: .half).apply(to: &score) // [ts, r h, r q, r q]
        let voice = VoiceRef(staff: Self.staff0, measureIndex: 0, voiceIndex: 0)
        #expect(score.timedElementIndex(startingAt: 0, in: voice) == 1)
        #expect(score.timedElementIndex(startingAt: 480, in: voice) == nil)
        #expect(score.timedElementIndex(startingAt: 960, in: voice) == 2)
        #expect(score.timedElementIndex(startingAt: 1920, in: voice) == nil)
    }

    @Test("a tie chain is reported once, for the first chord that reaches it")
    func tieChainsAreVisitedOnce() {
        let score = EditingFixtures.tiedC4Chain(length: 3) // elements 1-3 tied, element 4 a plain C4
        var visited: Set<NoteID> = []
        let first = RangeEditPlanner.unvisitedTieChains(of: Self.id(0, 1), in: score, visited: &visited)
        #expect(first.map(\.count) == [3])
        #expect(RangeEditPlanner.unvisitedTieChains(of: Self.id(0, 2), in: score, visited: &visited).isEmpty)
        let untied = RangeEditPlanner.unvisitedTieChains(of: Self.id(0, 4), in: score, visited: &visited)
        #expect(untied.map(\.count) == [1])
    }
}
