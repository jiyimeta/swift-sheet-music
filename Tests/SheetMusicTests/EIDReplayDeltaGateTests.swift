import Foundation
@testable import SheetMusicCore
import Testing

#if DEBUG
    /// **Gate 6 — the replay chains' identifier deltas.**
    ///
    /// The spec asks that for each step of the 92-step parity chain (`EditReplayScript+Parity.swift`),
    /// `IDs after == IDs before − deleted + created` matches the edit-command classification table. Nothing in
    /// P1–P3 implemented it. This is that gate, run over every chain in `ReplayChain.all` rather than the parity
    /// chain alone — the harness is the same and three more chains cost milliseconds.
    ///
    /// ## What is gated, and what is not
    ///
    /// The equation itself is set algebra: it is true of ANY two sets unless an identifier appears twice, so a
    /// test that only asserted it would measure almost nothing. Four classes of assertion carry the real weight,
    /// and the classification an intent falls into is read off the intent, not recorded from a run:
    ///
    /// - **Every step** — no duplicate identifier after; every identifier that appeared was minted by the LIVE
    ///   allocator during this very step (`first == actor`, `counter before < second <= counter after`), so an
    ///   identifier copied in from a planner's scratch allocator or resurrected from a deleted element is
    ///   caught; and, on every non-undo step, nothing the chain has ever seen before comes back. Plus the
    ///   `apply` returned `true`: a refused step has a trivially empty delta and would satisfy every
    ///   expectation below without doing anything.
    /// - **`.preserved`** — a value-only intent (`SetNotePitch`, `SetAccidental`, a visibility flag, a `Measure`
    ///   flag, a range respelling) creates and deletes NOTHING. `before == after`, as sets. This is the
    ///   classification table's "carries over" row, and it is the one that catches a command that re-minted
    ///   everything while looking correct on values.
    /// - **`.exactly(created:deleted:)`** — the two rows P3 added: `AddNoteToChord` mints exactly one note
    ///   identifier and drops none; `RemoveNoteFromChord` drops exactly one and mints none. The chord carries
    ///   over in both, which the counts express.
    /// - **`.noDeletion`** — `MoveToVoice`, whose table row is "carries over": it was a delete-plus-create
    ///   before SP0 and was rewritten to a move, so no identifier may leave the score. It still CREATES (the
    ///   source slot becomes a rest and the destination voice may not exist yet), so the count is open on that
    ///   side only.
    /// - **An undo step** restores the identifier set that stood before the intent it reverses, exactly
    ///   (`EditingIdentityInvariants.restoresIDs`) — spec gate 7a. A fresh identifier minted on undo would make
    ///   an undone deletion read as delete-plus-create in SP6's log.
    ///
    /// **Not gated: the create-count rows for every other intent.** Writing them would mean transcribing the
    /// whole classification table into this file, and a table recorded from a run rather than derived is a
    /// golden that agrees with whatever the code does. Those steps are still covered by the every-step checks
    /// above, which is a real constraint (freshness, non-reuse, uniqueness) — just not an exact count. The
    /// report for this task lists them by name.
    enum EIDReplayDelta {
        /// What an intent is allowed to do to the identifier set. Derived from the intent, never recorded.
        enum Expectation: Equatable {
            /// A value write: the identifier set is untouched.
            case preserved
            /// Exactly this many identifiers minted and dropped.
            case exactly(created: Int, deleted: Int)
            /// May mint, may not drop.
            case noDeletion
            /// The classification table has a row, but expressing it here would mean transcribing the table.
            case unclassified
        }

        /// Value-only intents: each plans to a `setValue`-shaped command that rewrites a field of an element
        /// already in the score, never a `replace` that swaps the element or a splice that changes a count.
        /// Grouped by the classification table's own grouping so a new intent lands in the right list.
        static func expectation(of intent: EditIntent) -> Expectation {
            switch intent {
            // Note value writes — the classification table's "carries over, a value change" row.
            case .setNotePitch, .setAccidental, .setNoteHead, .setNoteVisible, .setNoteParentheses,
                 .setGlissando, .setTie:
                .preserved
            // Chord / element value writes.
            case .setArticulation, .setTremolo, .setArpeggio, .setChordLine,
                 .setElementVisible, .setStemVisible, .setBeamVisible,
                 .setElementColor, .setElementPlacement:
                .preserved
            // `Measure` flag writes — these never touch a voice's element list at all.
            case .setLayoutBreak, .setRepeatBarLines, .setJumps, .setMarkers:
                .preserved
            // Range intents that plan to per-note value writes.
            case .transposeRange, .setAccidentalsInRange, .respellRange:
                .preserved
            // Text and part-level value writes.
            case .setTextVisible, .setTextFont, .setLyricSyllables, .setLyricVerse,
                 .setPartNames, .setDrumsetEntry:
                .preserved
            // The two rows P3 added to the table.
            case .addNoteToChord: .exactly(created: 1, deleted: 0)
            case .removeNoteFromChord: .exactly(created: 0, deleted: 1)
            // "Carries over": rewritten from delete-plus-create to a move in SP0 precisely so nothing is lost.
            case .moveToVoice: .noDeletion
            // A composite is as strict as its strictest member, and only when EVERY member is a value write —
            // `.composite([addNoteToChord, removeNoteFromChord])` nets to zero, but through two real deltas.
            case let .composite(inner):
                inner.allSatisfy { expectation(of: $0) == .preserved } ? .preserved : .unclassified
            default: .unclassified
            }
        }

        /// What one chain's walk measured. Every field is printed, because a gate that walked 92 steps and ran
        /// no assertion is the failure this plan keeps warning about.
        struct Walk {
            var steps = 0
            var intents = 0
            var undos = 0
            var preservedChecks = 0
            var exactChecks = 0
            var noDeletionChecks = 0
            var undoChecks = 0
            var unclassified = 0
            /// The intent kinds this gate does NOT hold to an exact count — printed with the counts so the
            /// coverage gap is stated by the gate itself rather than only in a report nobody re-reads.
            var unclassifiedKinds: Set<String> = []
            var created = 0
            var deleted = 0
        }

        /// The case name of an intent, without its payload — `setBarLine`, `composite`, … Used only to report
        /// which kinds fell through to `.unclassified`.
        static func kind(of intent: EditIntent) -> String {
            String(String(describing: intent).prefix { $0 != "(" })
        }
    }

    @Suite("EID replay delta gate")
    struct EIDReplayDeltaGateTests {
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

        @Test("every replay step accounts for its identifier delta", arguments: ReplayChain.all)
        func chainStepsAccountForTheirDelta(chain: ReplayChain) {
            let walk = Self.walk(chain)
            #expect(walk.steps == chain.steps(Self.staff).count)
            let classified = walk.preservedChecks + walk.exactChecks + walk.noDeletionChecks + walk.undoChecks
            #expect(classified > 0, "\(chain.name): every step fell through to `.unclassified`")
        }

        /// The parity chain's own numbers, pinned rather than printed.
        ///
        /// This is the answer to "92 steps that ran zero assertions". The step count says the gate reached the
        /// end of the frozen chain; the non-zero created and deleted counts say the walk observed real
        /// identifier deltas rather than a sequence of refusals, each of which would show an empty one; and the
        /// per-class counts say each of the four expectation classes was actually reached. `ReplayChain.parity`
        /// is frozen (see its doc comment), so these are constants, not a golden to refresh: a number that moves
        /// means the chain or the classification moved, and both are worth stopping for.
        @Test("the parity chain's delta gate walks all 92 steps and reaches every expectation class")
        func parityWalkIsNotInert() {
            let walk = Self.walk(.parity)
            #expect(walk.steps == 92)
            #expect(walk.intents == 87)
            #expect(walk.undos == 5)
            #expect(walk.preservedChecks == 35)
            #expect(walk.exactChecks == 2)
            #expect(walk.noDeletionChecks == 2)
            #expect(walk.undoChecks == 5)
            #expect(walk.created > 0)
            #expect(walk.deleted > 0)
        }

        private static func walk(_ chain: ReplayChain) -> EIDReplayDelta.Walk {
            let steps = chain.steps(Self.staff)
            let session = ScoreEditSession(score: chain.fixture())
            var walk = EIDReplayDelta.Walk()
            var everSeen = Set(EditingIdentityInvariants.identifiers(in: session.score))
            // The identifier set standing before the previous step — what an `.undo` must restore.
            var beforePreviousStep = everSeen

            for (index, step) in steps.enumerated() {
                let label = "\(chain.name) step \(index + 1)"
                let before = Set(EditingIdentityInvariants.identifiers(in: session.score))
                let counterBefore = session.idAllocator.counter
                let expectation = Self.run(step, on: session, label: label)
                let afterList = EditingIdentityInvariants.identifiers(in: session.score)
                let after = Set(afterList)
                walk.steps += 1

                let created = after.subtracting(before)
                let deleted = before.subtracting(after)
                walk.created += created.count
                walk.deleted += deleted.count
                Self.expectEveryStepInvariants(
                    session: session, slots: afterList, before: before, after: after,
                    created: created, deleted: deleted, label: label,
                )

                switch step {
                case let .intent(intent):
                    walk.intents += 1
                    if expectation == .unclassified {
                        walk.unclassifiedKinds.insert(EIDReplayDelta.kind(of: intent))
                    }
                    #expect(
                        created.isDisjoint(with: everSeen),
                        "\(label): reissued an identifier this chain had already used",
                    )
                    // Only on a forward step. An undo legitimately brings identifiers back from BELOW the
                    // counter it started at — that is what `restoresIDs` below asserts instead, and it is the
                    // stronger of the two.
                    Self.expectFreshlyMinted(
                        created, actor: session.idAllocator.actor,
                        above: counterBefore, upTo: session.idAllocator.counter, label: label,
                    )
                    Self.check(expectation, created: created, deleted: deleted, label: label, into: &walk)
                case .undo, .redo:
                    walk.undos += 1
                    // `beforePreviousStep` is the set the PREVIOUS step started from, which is the set this
                    // undo must restore only while every `.undo` in every chain immediately follows the intent
                    // it reverses — true of all four today, and asserted rather than assumed: an undo after an
                    // undo would make the comparison meaningless, so the check is skipped and counted as
                    // unclassified instead of quietly asserting the wrong set.
                    guard index > 0, case .intent = steps[index - 1] else {
                        walk.unclassified += 1
                        break
                    }
                    #expect(
                        EditingIdentityInvariants.restoresIDs(beforePreviousStep, after: after),
                        "\(label): undo did not restore the identifier set the undone step started from",
                    )
                    walk.undoChecks += 1
                }

                everSeen.formUnion(after)
                beforePreviousStep = before
            }

            print("[eid-replay-delta] chain=\(chain.name) steps=\(walk.steps) intents=\(walk.intents) "
                + "undos=\(walk.undos) preserved=\(walk.preservedChecks) exact=\(walk.exactChecks) "
                + "noDeletion=\(walk.noDeletionChecks) undoRestore=\(walk.undoChecks) "
                + "unclassified=\(walk.unclassified) created=\(walk.created) deleted=\(walk.deleted)")
            print("[eid-replay-delta] chain=\(chain.name) notHeldToACount="
                + walk.unclassifiedKinds.sorted().joined(separator: ","))
            return walk
        }

        /// The three checks every step is held to regardless of what it did: no duplicate identifier, the
        /// spec's equation, and the live allocator covering everything in the score.
        ///
        /// The equation is set algebra — and that is exactly why it is asserted next to the uniqueness check
        /// rather than on its own, since a duplicate is the only way it can break.
        private static func expectEveryStepInvariants(
            session: ScoreEditSession, slots: [EID], before: Set<EID>, after: Set<EID>,
            created: Set<EID>, deleted: Set<EID>, label: String,
        ) {
            #expect(after.count == slots.count, "\(label): two slots share an identifier")
            #expect(
                after.count == before.count - deleted.count + created.count,
                "\(label): \(before.count) - \(deleted.count) + \(created.count) != \(after.count)",
            )
            #expect(
                EditingIdentityInvariants.allocatorCovers(session.score, session.idAllocator),
                "\(label): an identifier was minted outside the live allocator",
            )
        }

        /// Applies one step and answers what its delta is allowed to be. An intent that was REFUSED has an empty
        /// delta and would satisfy every expectation without editing anything, so the return value is asserted
        /// here rather than discarded.
        private static func run(
            _ step: EditReplayStep, on session: ScoreEditSession, label: String,
        ) -> EIDReplayDelta.Expectation {
            switch step {
            case let .intent(intent):
                #expect(session.apply(intent), "\(label): the step was refused, so its delta proves nothing")
                return EIDReplayDelta.expectation(of: intent)
            case .undo:
                #expect(session.undo(), "\(label): the undo was refused")
                return .unclassified
            case .redo:
                #expect(session.redo(), "\(label): the redo was refused")
                return .unclassified
            }
        }

        /// Every identifier that appeared must have come out of the live allocator during THIS step: the actor
        /// is the session's, and the counter sits strictly above where the step started and no higher than
        /// where it ended. A value copied in from a planner's scratch allocator, or a dead identifier reissued,
        /// fails one half or the other.
        private static func expectFreshlyMinted(
            _ created: Set<EID>, actor: UInt64, above: UInt64, upTo: UInt64, label: String,
        ) {
            for eid in created.sorted(by: { $0.second < $1.second }) {
                #expect(eid.first == actor, "\(label): \(eid.stringValue) was not minted by the live allocator")
                let range = "(\(above), \(upTo)]"
                #expect(
                    eid.second > above && eid.second <= upTo,
                    "\(label): \(eid.stringValue) is outside the counter range this step consumed \(range)",
                )
            }
        }

        private static func check(
            _ expectation: EIDReplayDelta.Expectation,
            created: Set<EID>, deleted: Set<EID>, label: String, into walk: inout EIDReplayDelta.Walk,
        ) {
            switch expectation {
            case .preserved:
                walk.preservedChecks += 1
                #expect(created.isEmpty, "\(label): a value write minted \(created.count) identifiers")
                #expect(deleted.isEmpty, "\(label): a value write dropped \(deleted.count) identifiers")
            case let .exactly(expectedCreated, expectedDeleted):
                walk.exactChecks += 1
                #expect(created.count == expectedCreated, "\(label): created \(created.count)")
                #expect(deleted.count == expectedDeleted, "\(label): deleted \(deleted.count)")
            case .noDeletion:
                walk.noDeletionChecks += 1
                #expect(deleted.isEmpty, "\(label): a move dropped \(deleted.count) identifiers")
            case .unclassified:
                walk.unclassified += 1
            }
        }
    }
#endif
