import SheetMusicFoundation

#if DEBUG
    /// Debug-only structural-spine gates; extend the traversal when later phases identify more lanes.
    enum EditingIdentityInvariants {
        static func identifiers(in score: Score) -> [EID] {
            var result = score.parts.indices.map { score.parts.eid(at: $0) }
            for part in score.parts {
                result.append(contentsOf: part.staves.indices.map { part.staves.eid(at: $0) })
            }
            result.append(contentsOf: score.systemMeasures.indices.map { score.systemMeasures.eid(at: $0) })
            return result
        }

        static func hasUniqueIDs(_ score: Score) -> Bool {
            let ids = identifiers(in: score)
            return Set(ids).count == ids.count
        }

        static func restoresIDs(_ before: Set<EID>, after: Set<EID>) -> Bool {
            before == after
        }

        enum Seam {
            case apply, undo, redo, bare
        }

        struct Counts: Sendable {
            var apply = 0
            var undo = 0
            var redo = 0
            var bare = 0
        }

        /// All access to mutable counter state is serialized, including reads from parallel tests.
        private final class CounterStorage: @unchecked Sendable {
            private let lock = SerialLock(label: "SheetMusicCore.EditingIdentityInvariants")
            private var value = Counts()

            func record(_ seam: Seam) {
                lock.withLock {
                    switch seam {
                    case .apply: value.apply += 1
                    case .undo: value.undo += 1
                    case .redo: value.redo += 1
                    case .bare: value.bare += 1
                    }
                }
            }

            func snapshot() -> Counts {
                lock.withLock { value }
            }
        }

        private static let storage = CounterStorage()

        static var counts: Counts {
            storage.snapshot()
        }

        /// Gate 5 covers every apply through ScoreEditor (apply / undo / redo) or the bare
        /// apply(to:) convenience: 804 bare call sites at introduction and the production editing entry points.
        /// Direct low-level apply(to:ids:) calls are not covered: currently 15 call sites in four identity
        /// test files, all of which assert identity explicitly. A future direct call silently inherits this gap.
        /// Those files are StructuralCommandIdentityTests, StructuralSpineIdentityTests,
        /// ScoreIdentityAssignmentTests, and MeasureColumnIdentityTests.
        /// MeasureColumnIdentityTests.swift:114 bypasses the seam deliberately to observe dropped IDs;
        /// routing that test through a covered entry point would trap instead of testing the observable state.
        /// Called beside the out-assert at each of the four seams; no checks or counters exist in release.
        static func check(_ score: Score, at seam: Seam) {
            assert(hasUniqueIDs(score), "duplicate structural element identifiers")
            storage.record(seam)
        }
    }
#endif
