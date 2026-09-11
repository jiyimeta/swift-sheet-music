import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicZip
import Testing

/// **Gate 1 — an element identifier survives a save and a reload.**
///
/// Two legs, because the two things worth proving need different ground to stand on.
///
/// **Leg A — position-keyed, on the normalized form.** Encode the parsed score once (`pass 1`), parse that,
/// encode again (`pass 2`), parse that. Compare the two parses slot by slot: same path, same identifier, in
/// order. Both halves the spec asks for are here — the second parse's identifiers must equal the first's *at
/// each position*, and the first parse is also the in-memory score that produced `pass 2`, so "the in-memory
/// identifiers before encoding equal the decoded ones" is the same comparison read the other way. Without that
/// second half an encoder that wrote some OTHER sequence's identifiers, consistently, would still pass.
///
/// Leg A starts from pass 1 rather than from the file because the FIRST encode legitimately drops elements —
/// the staff-head C-major `<KeySig>` (`MSCXEncoder+Voice.swift`'s `shouldDropInitialZeroKeySig`) is the common
/// one — and a dropped element renumbers every voice-element position after it, so a position-keyed comparison
/// against the original file reports one identifier mismatch per element in the bar for a difference that is
/// not about identifiers at all. `MSCXIdempotencySweep` proves pass 1 and pass 2 are byte-identical over the
/// corpus, so the two parses Leg A compares are structurally congruent by construction and a path mismatch
/// there is a real defect rather than a normalization.
///
/// **What starting from pass 1 costs.** An identifier that MOVED between two surviving elements during
/// that first encode — the one leg starts after — is invisible to both legs: Leg A never looks at the
/// original file at all, and Leg B only checks set membership, which a swap does not change. Closing this
/// would need asserting the ORIGINAL's identifier sequence, filtered down to the set pass 1 still holds,
/// equals pass 1's sequence in that same order — order-preserving so a legitimate drop costs nothing but a
/// swap is caught — and it would assume the encoder never legitimately reorders identified slots relative
/// to each other, which is not yet established.
///
/// **Leg B — set-based, against the original file.** Every identifier the reload holds must already have been
/// in the original parse: a save and a reload may LOSE an identifier (the encoder dropped the element that
/// carried it) but may never INVENT one. This is the leg that speaks about the identifiers a MuseScore-authored
/// file actually carried, and it is immune to the renumbering above because it compares sets rather than
/// positions. An encoder that re-minted everything on write fails it; so does one that wrote a different
/// sequence's identifiers.
///
/// ## The three excluded voice-lane kinds, and why each is excluded
///
/// - `.preserved` — an unmodeled `<voice>` child kept verbatim in a bag. Its source `<eid>` is captured INSIDE
///   that bag, not decoded into the slot, so the slot's own identifier is re-minted on every reload by design
///   (decision 3). `EIDPersistenceTests.preservedElementCarriesExactlyOneEID` pins that shape.
/// - `.locationShift` — a bare `<location>` jog. It is re-derived from the tick cursor on every encode rather
///   than carried, so its slot identifier is likewise re-minted by design (decision 3).
/// - `.spanner` — **an open gap, not a design decision.** `<Spanner type="X">` is not an `EngravingItem` and
///   carries no `<eid>` of its own; the real identifier lives one level down on the payload child
///   (`Tests/SheetMusicTests/Resources/guitarbend_tied.mscx:169-171` is `<Spanner type="Tie">` → `<Tie>` →
///   `<eid>3865470566431</eid>`). `Spanner.spanner` was reverted to `.invalid` in Task 4a because modelling
///   payload identity needs the per-subtype field ordering untangled first. **Remove this exclusion when that
///   lands** — it is here so the gate reports the gap rather than failing for it, and an exclusion whose reason
///   is not written down is one nobody can ever remove.
///
/// Nothing else is excluded: all eighteen other voice-lane kinds, the five system-lane kinds, `<Tuplet>`, grace
/// chords, notes, the column, the `<Part><Staff>` declaration and our own `<Part>` child are all compared.
enum EIDRoundTrip {
    /// One identified slot: where it sits, and what identifier it holds. The path is a structural address, so a
    /// failure names the element rather than an index into a flat list.
    struct Slot: Equatable, Sendable {
        let path: String
        let eid: EID
    }

    /// Which voice-lane slots a traversal reports.
    ///
    /// `.persisted` drops the three kinds whose identifier is not expected to come back off disk — what gate 1
    /// compares. `.every` reports them too, which is what gate 3 wants: a file with no `<eid>` at all must come
    /// back with EVERY slot identified, including the three whose identifier is minted rather than read.
    enum Coverage: Sendable {
        case persisted
        case every
    }

    /// See the type's doc comment for why each of these three is excluded from `.persisted`.
    static func isExcluded(_ element: VoiceElement, under coverage: Coverage) -> Bool {
        guard coverage == .persisted else { return false }
        switch element {
        case .preserved, .locationShift, .spanner: return true
        default: return false
        }
    }

    static func slots(in score: Score, coverage: Coverage = .persisted) -> [Slot] {
        var out: [Slot] = []
        for partIndex in score.parts.indices {
            let part = score.parts[partIndex]
            let partPath = "p\(partIndex)"
            out.append(Slot(path: partPath, eid: score.parts.eid(at: partIndex)))
            for staffIndex in part.staves.indices {
                out.append(Slot(path: "\(partPath)/s\(staffIndex)", eid: part.staves.eid(at: staffIndex)))
                appendStaffSlots(
                    part.staves[staffIndex], at: "\(partPath)/s\(staffIndex)", coverage: coverage, to: &out,
                )
            }
        }
        for columnIndex in score.systemMeasures.indices {
            let column = score.systemMeasures[columnIndex]
            let columnPath = "col\(columnIndex)"
            out.append(Slot(path: columnPath, eid: score.systemMeasures.eid(at: columnIndex)))
            for elementIndex in column.elements.indices {
                out.append(Slot(
                    path: "\(columnPath)/e\(elementIndex)", eid: column.elements.eid(at: elementIndex),
                ))
            }
        }
        return out
    }

    private static func appendStaffSlots(
        _ staff: Staff, at path: String, coverage: Coverage, to out: inout [Slot],
    ) {
        for measureIndex in staff.measures.indices {
            let measure = staff.measures[measureIndex]
            for voiceIndex in measure.voices.indices {
                let voice = measure.voices[voiceIndex]
                let voicePath = "\(path)/m\(measureIndex)/v\(voiceIndex)"
                for elementIndex in voice.elements.indices
                    where !isExcluded(voice.elements[elementIndex], under: coverage)
                {
                    let elementPath = "\(voicePath)/e\(elementIndex)"
                    out.append(Slot(path: elementPath, eid: voice.elements.eid(at: elementIndex)))
                    guard case let .chord(chord) = voice.elements[elementIndex] else { continue }
                    appendChordSlots(chord, at: elementPath, to: &out)
                }
                for tupletIndex in voice.tuplets.indices {
                    out.append(Slot(
                        path: "\(voicePath)/t\(tupletIndex)", eid: voice.tuplets.eid(at: tupletIndex),
                    ))
                }
            }
        }
    }

    private static func appendChordSlots(_ chord: Chord, at path: String, to out: inout [Slot]) {
        for noteIndex in chord.notes.indices {
            out.append(Slot(path: "\(path)/n\(noteIndex)", eid: chord.notes.eid(at: noteIndex)))
        }
        for graceIndex in chord.graceNotesBefore.indices {
            let gracePath = "\(path)/gb\(graceIndex)"
            out.append(Slot(path: gracePath, eid: chord.graceNotesBefore.eid(at: graceIndex)))
            let grace = chord.graceNotesBefore[graceIndex]
            for noteIndex in grace.notes.indices {
                out.append(Slot(path: "\(gracePath)/n\(noteIndex)", eid: grace.notes.eid(at: noteIndex)))
            }
        }
        for graceIndex in chord.graceNotesAfter.indices {
            let gracePath = "\(path)/ga\(graceIndex)"
            out.append(Slot(path: gracePath, eid: chord.graceNotesAfter.eid(at: graceIndex)))
            let grace = chord.graceNotesAfter[graceIndex]
            for noteIndex in grace.notes.indices {
                out.append(Slot(path: "\(gracePath)/n\(noteIndex)", eid: grace.notes.eid(at: noteIndex)))
            }
        }
    }

    /// What one file contributed to the gate. `slotCount` is what makes "it ran" distinguishable from "nothing
    /// matched": a file that reports zero compared slots is reported as a failure by the callers below.
    struct Outcome {
        var slotCount = 0
        /// Identifiers present after the reload that were not in the original parse — Leg B's failure.
        var invented: [String] = []
        /// Leg A's failures: a path or an identifier that moved between pass 1's parse and pass 2's.
        var unstable: [String] = []
        /// Identifiers the encoder dropped along with the element carrying them. Counted, not failed: the
        /// staff-head C-major `<KeySig>` omission is the dominant cause and is a normalization the preservation
        /// gate owns, not an identity defect.
        var droppedCount = 0
    }

    static func check(_ score: Score) throws -> Outcome {
        var outcome = Outcome()
        let original = slots(in: score)
        let pass1 = try MSCXParser.parse(MSCXEncoder.encode(score))
        let pass2 = try MSCXParser.parse(MSCXEncoder.encode(pass1))
        let first = slots(in: pass1)
        let second = slots(in: pass2)
        outcome.slotCount = first.count

        for index in 0 ..< min(first.count, second.count) where first[index] != second[index] {
            outcome.unstable.append(
                "\(first[index].path) held \(first[index].eid.stringValue), "
                    + "reloaded as \(second[index].path) = \(second[index].eid.stringValue)",
            )
            break
        }
        if first.count != second.count {
            outcome.unstable.append("pass 1 has \(first.count) identified slots, pass 2 has \(second.count)")
        }

        let originalIDs = Set(original.map(\.eid))
        let invented = first.filter { !originalIDs.contains($0.eid) }
        outcome.invented = invented.prefix(3).map { "\($0.path) = \($0.eid.stringValue)" }
        outcome.droppedCount = max(0, original.count - first.count)
        return outcome
    }
}

/// The always-on layer: gate 1 over committed fixtures, so a default `swift test` measures it. The fixture list
/// is `MSCXIdempotencyTests`' — the shapes that have moved the encoder's output — plus `midi01` (the only
/// MuseScore-authored fixture whose `<eid>`s this repo asserts by literal value) and `own/instrument-change`
/// (the repo's only `<InstrumentChange>`, whose `<eid>` sits after two conditional children and is therefore the
/// carrier most likely to move silently).
@Suite("EID save/load round trip")
struct EIDRoundTripTests {
    @Test("a committed fixture's identifiers survive a save and a reload", arguments: [
        "midi01",
        "instrument-change",
        "testVoltaTemp",
        "testSingleNoteDynamics",
        "slur_ms4_resave",
        "grace-notes",
        "grace_after",
        "multiPartMixedStaves",
        "spanner_offsets_score_end",
        "slur_ms3_exchangevoices",
        "guitarbend_simple",
    ])
    func fixtureIdentifiersSurvive(_ name: String) throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
        let outcome = try EIDRoundTrip.check(score)
        print("[eid-roundtrip] \(name).mscx identifiers=\(outcome.slotCount) dropped=\(outcome.droppedCount)")
        #expect(outcome.slotCount > 0, "\(name): compared no identified slots")
        #expect(outcome.unstable.isEmpty, "\(name): \(outcome.unstable.joined(separator: "; "))")
        let inventedDetail = outcome.invented.joined(separator: "; ")
        #expect(
            outcome.invented.isEmpty,
            "\(name): the reload invented identifiers the source parse never held: \(inventedDetail)",
        )
    }

    #if DEBUG
        /// **`EIDRoundTrip.slots` and `EditingIdentityInvariants.identifiers(in:)` share fate.**
        ///
        /// `slots(in:coverage: .every)` is a second hand-written walk of the same identified sequences that
        /// `identifiers(in:)` walks. Two independent traversals of one structure drift, and
        /// `identifiers(in:)`'s own doc comment already warns that a new minting site becomes "invisible to
        /// both at once" — a third walker inherits that blindness, and gate 1 and gate 3 both rest on this one.
        ///
        /// It is gate 3 in particular that needs this. Its count-equality compares two numbers that BOTH come
        /// from `slots(in:coverage: .every)`, so a traversal that stopped walking notes would shrink both sides
        /// equally and the gate would pass having measured less. This test is what makes that count-equality an
        /// independent check rather than a tautology: the traversal is pinned against a walker that lives in a
        /// different module and is maintained for a different reason.
        ///
        /// Compared as a SET, not only as a count: the two walks emit a chord's own notes and its grace
        /// chords' notes in a different order, so order-sensitive equality would fail for a reason that is not
        /// about coverage, while set equality over distinct identifiers is strictly stronger than the count.
        ///
        /// Fixtures: `grace-notes` carries the repo's only `<Tuplet>` plus grace chords (the two nested
        /// sequences most easily dropped from a walk), and `instrument-change` is the only one with a
        /// system-lane occupant.
        @Test("the gate's traversal and the editing invariant's walk cover the same slots", arguments: [
            "grace-notes",
            "instrument-change",
            "testSingleNoteDynamics",
        ])
        func traversalAgreesWithTheEditingInvariant(_ name: String) throws {
            let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
            let mine = EIDRoundTrip.slots(in: score, coverage: .every).map(\.eid)
            let theirs = EditingIdentityInvariants.identifiers(in: score)
            #expect(!mine.isEmpty, "\(name): the traversal reported nothing, so agreement proves nothing")
            #expect(mine.count == theirs.count, "\(name): \(mine.count) slots here, \(theirs.count) there")
            #expect(Set(mine) == Set(theirs), "\(name): the two walks cover different slots")
        }
    #endif
}

/// The opt-in corpus layer, deliberately keyed on the SAME `SM_MSCX_IDEMPOTENCY_DIR` the 2-pass sweep uses —
/// one corpus path, two sweeps over it, no second variable to configure and no second file enumerator:
///
///     SM_MSCX_IDEMPOTENCY_DIR=~/path/to/scores swift test --filter EIDRoundTripSweep
///
/// Disabled when the variable is unset, so a default `swift test` costs nothing. A file that will not DECODE is
/// reported and skipped (a corpus of real scores holds MuseScore 1.x files this reader does not claim to open);
/// a file that decodes but throws on encode is counted as `failed` and fails the sweep, for the reason
/// `MSCXIdempotencySweep` states. The run prints its counts because "no failure was reported" and "it compared
/// 669 scores and 400 000 identifiers" are different facts.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SM_MSCX_IDEMPOTENCY_DIR"] != nil))
struct EIDRoundTripSweep {
    @Test("every identifier in the corpus survives a save and a reload")
    func corpusIdentifiersSurvive() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["SM_MSCX_IDEMPOTENCY_DIR"])
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let files = MSCXIdempotency.scoreFiles(under: root)
        #expect(!files.isEmpty, "no .mscx / .mscz found under \(root.path)")

        var loaded = 0
        var slots = 0
        var dropped = 0
        var emptyFiles: [String] = []
        var unreadable = 0
        var failed: [String] = []
        var unstable: [String] = []
        var invented: [String] = []
        for file in files {
            guard let score = try? MSCXIdempotency.score(at: file) else {
                unreadable += 1
                continue
            }
            loaded += 1
            do {
                let outcome = try EIDRoundTrip.check(score)
                slots += outcome.slotCount
                dropped += outcome.droppedCount
                if outcome.slotCount == 0 { emptyFiles.append(file.lastPathComponent) }
                unstable += outcome.unstable.map { "\(file.lastPathComponent): \($0)" }
                invented += outcome.invented.map { "\(file.lastPathComponent): \($0)" }
            } catch {
                failed.append("\(file.lastPathComponent): \(error)")
            }
        }

        print("[eid-roundtrip] files=\(files.count) loaded=\(loaded) unreadable=\(unreadable) "
            + "failed=\(failed.count) identifiers=\(slots) dropped=\(dropped) "
            + "unstable=\(unstable.count) invented=\(invented.count) noIdentifiers=\(emptyFiles.count)")
        for line in (failed + unstable + invented).prefix(20) {
            print("[eid-roundtrip][issue] \(line)")
        }
        #expect(loaded > 0, "the sweep decoded no file at all")
        #expect(slots > 0, "the sweep compared no identifier at all")
        #expect(failed.isEmpty, "\(failed.count) of \(loaded) scores decoded but threw on re-encode")
        #expect(emptyFiles.isEmpty, "\(emptyFiles.count) scores carried no identified slot at all")
        #expect(unstable.isEmpty, "\(unstable.count) of \(loaded) scores moved an identifier across a reload")
        #expect(invented.isEmpty, "\(invented.count) of \(loaded) scores invented an identifier on reload")
    }
}
