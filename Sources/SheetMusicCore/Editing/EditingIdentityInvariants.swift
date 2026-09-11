import SheetMusicFoundation

#if DEBUG
    /// Debug-only identity gates for the structural spine, voice contents, and system-lane occupants.
    enum EditingIdentityInvariants {
        /// A chord's own note identifiers, plus each grace chord's note identifiers. Shared so the
        /// production gate and test fixtures that need "every note in this chord" (e.g. copy/paste
        /// disjointness checks) cannot drift on what counts as a note.
        ///
        /// Because `GraceTransportFixtures.allNoteIDs` delegates here (see its doc comment), this
        /// function and that test helper now share fate on traversal-completeness bugs: a future
        /// site that mints note identifiers without going through here (a new nested-note slot, a
        /// third grace list, …) is invisible to both at once. Extending what this function walks
        /// must come with a hardcoded-count regression test — the pattern in
        /// `identifierTraversalCountsTupletSlotsNotEndpointReferences` and
        /// `traversalCountsGraceSlotsAndRejectsCrossCollectionDuplicates` — rather than relying on
        /// the delegation to catch the gap.
        static func noteIdentifiers(of chord: Chord) -> [EID] {
            var result = chord.notes.indices.map { chord.notes.eid(at: $0) }
            for grace in chord.graceNotesBefore.values + chord.graceNotesAfter.values {
                result.append(contentsOf: grace.notes.indices.map { grace.notes.eid(at: $0) })
            }
            return result
        }

        static func identifiers(in score: Score) -> [EID] {
            var result = score.parts.indices.map { score.parts.eid(at: $0) }
            for part in score.parts {
                result.append(contentsOf: part.staves.indices.map { part.staves.eid(at: $0) })
                for staff in part.staves {
                    for measure in staff.measures {
                        for voice in measure.voices {
                            result.append(contentsOf: voice.elements.indices.map { voice.elements.eid(at: $0) })
                            for element in voice.elements {
                                guard case let .chord(chord) = element else { continue }
                                result.append(contentsOf: chord.graceNotesBefore.indices.map {
                                    chord.graceNotesBefore.eid(at: $0)
                                })
                                result.append(contentsOf: chord.graceNotesAfter.indices.map {
                                    chord.graceNotesAfter.eid(at: $0)
                                })
                                result.append(contentsOf: noteIdentifiers(of: chord))
                            }
                            result.append(contentsOf: voice.tuplets.indices.map { voice.tuplets.eid(at: $0) })
                        }
                    }
                }
            }
            result.append(contentsOf: score.systemMeasures.indices.map { score.systemMeasures.eid(at: $0) })
            for column in score.systemMeasures {
                result.append(contentsOf: column.elements.indices.map { column.elements.eid(at: $0) })
            }
            return result
        }

        static func hasUniqueIDs(_ score: Score) -> Bool {
            let ids = identifiers(in: score)
            return Set(ids).count == ids.count
        }

        /// Mark endpoints are legal; every endpoint must name an ordered member of its owning voice.
        static func hasValidTupletEndpoints(in score: Score) -> Bool {
            for part in score.parts {
                for staff in part.staves {
                    for measure in staff.measures {
                        for voice in measure.voices {
                            for tuplet in voice.tuplets {
                                guard case let .element(first) = tuplet.first,
                                      case let .element(last) = tuplet.last,
                                      let start = voice.elements.index(of: first),
                                      let end = voice.elements.index(of: last), start <= end
                                else { return false }
                            }
                        }
                    }
                }
            }
            return true
        }

        /// Catches a command payload carrying an identifier minted from an allocator copy, such as
        /// a planner's scratch value, that the live apply never advanced past. The next edit would
        /// reissue that counter; this catches it where it lands, before a duplicate exists.
        /// Uses `identifiers(in:)`, so coverage widens automatically when that traversal expands.
        static func allocatorCovers(_ score: Score, _ ids: EIDAllocator) -> Bool {
            identifiers(in: score).allSatisfy { $0.first != ids.actor || $0.second <= ids.counter }
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
        static func check(_ score: Score, ids: EIDAllocator, at seam: Seam) {
            assert(hasUniqueIDs(score), "duplicate structural element identifiers")
            assert(allocatorCovers(score, ids), "an identifier was minted outside the live allocator")
            assert(hasValidTupletEndpoints(in: score), "tuplet endpoints must name ordered members of their voice")
            storage.record(seam)
        }
    }
#endif
