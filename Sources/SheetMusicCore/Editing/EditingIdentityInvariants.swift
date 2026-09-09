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

        /// Gate 5 covers every apply that reaches the score through `ScoreEditor` (apply / undo /
        /// redo) or the bare `apply(to:)` convenience — the whole production editing surface, and
        /// every test that drives a command either of those ways.
        ///
        /// It does NOT cover a direct call to the low-level `apply(to:ids:)`, which bypasses all
        /// four seams. Today every such call sits in a test that asserts identity explicitly, so the
        /// gap is covered by construction rather than left open — but a new direct call inherits the
        /// gap silently, and nothing recomputes that. `EditingIdentityInvariantTests` is where to add
        /// a guard if that stops being true.
        ///
        /// One test bypasses the seam **deliberately**:
        /// `MeasureColumnIdentityTests.aLaneRebuiltFromALiteralIsDetectableBeforeTheOutAssert`
        /// observes the state the out-assert traps on, so routing it through a covered entry point
        /// would crash instead of testing. Do not "close the coverage gap" by moving it.
        ///
        /// Deliberately no counts here: a tally in a doc comment is a claim nothing recomputes, and
        /// this file's own guard test is what measures the reach.
        ///
        /// Called beside the out-assert at each of the four seams; no checks or counters exist in release.
        static func check(_ score: Score, at seam: Seam) {
            assert(hasUniqueIDs(score), "duplicate structural element identifiers")
            storage.record(seam)
        }
    }
#endif
