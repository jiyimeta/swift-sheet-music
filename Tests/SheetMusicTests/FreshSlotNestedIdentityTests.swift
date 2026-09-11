@testable import SheetMusicCore
import Testing

/// Task 0 (SP0 P4): a fresh slot clears nested identity unless it is explicitly carrying it.
///
/// These call `VoiceSlot.materialize` and `ReplaceVoiceElement.apply(to:ids:)` directly, never through
/// `ScoreEditor.apply` (the DEBUG identity assert would abort the process instead of failing a test) and
/// never through `PasteVoiceElement` (it already clears, so a gate built on it would be green before the
/// fix exists).
@Suite("Fresh slot nested identity")
struct FreshSlotNestedIdentityTests {
    private typealias V = VoiceIdentityFixtures
    private typealias G = GraceTransportFixtures

    /// Every identifier nested inside `chord`: its own notes, both grace slot lists' own identifiers, and
    /// each grace chord's own notes. Mirrors what `Chord.clearNestedIDsForCopy()` clears and
    /// `Chord.assignMissingNestedIDs` fills.
    private static func nestedIDs(of chord: Chord) -> Set<EID> {
        var result = Set(EditingIdentityInvariants.noteIdentifiers(of: chord))
        result.formUnion(chord.graceNotesBefore.indices.map { chord.graceNotesBefore.eid(at: $0) })
        result.formUnion(chord.graceNotesAfter.indices.map { chord.graceNotesAfter.eid(at: $0) })
        return result
    }

    /// A chord whose own notes, both grace lists, and each grace chord's own notes are all genuinely
    /// assigned — i.e. what a chord read out of a real score looks like.
    private static func assignedChord(_ duration: NoteDuration = .whole) throws -> Chord {
        var seed = EIDAllocator()
        var element = G.decorated(duration)
        element.assignMissingNestedIDs(using: &seed)
        guard case let .chord(chord) = element else {
            Issue.record("Expected a chord")
            throw TestSetupError.expectedChord
        }
        return chord
    }

    private enum TestSetupError: Error { case expectedChord }

    // MARK: 1. VoiceSlot.materialize, .fresh, default (cleared)

    @Test func freshSlotClearsAssignedNestedIdentity() throws {
        let source = try Self.assignedChord()
        let sourceIDs = Self.nestedIDs(of: source)
        var ids = EIDAllocator()
        let materialized = VoiceSlot.materialize(
            [VoiceSlot(identity: .fresh, element: .chord(source))], using: &ids,
        )
        guard case let .chord(result) = materialized[0] else {
            Issue.record("Expected a chord")
            return
        }
        let resultIDs = Self.nestedIDs(of: result)
        // Hardcoded per `EditingIdentityInvariants.swift`'s standing rule: a relative count alone stays
        // green if `nestedIDs(of:)` under-walks. `G.decorated()`'s fixture is 1 own note + 1
        // graceNotesBefore slot + 1 graceNotesAfter slot + 1 before-grace note + 1 after-grace note = 5.
        #expect(sourceIDs.count == 5)
        #expect(resultIDs.count == sourceIDs.count)
        #expect(resultIDs.isDisjoint(with: sourceIDs))
        #expect(result == source)
    }

    // MARK: 2. ReplaceVoiceElement, .fresh, a chord copied from elsewhere in the same score

    @Test func freshReplaceClearsNestedIdentityOfElementCopiedFromElsewhere() throws {
        var ids = EIDAllocator()
        var score = V.score(elements: [G.decorated(.quarter), .rest(duration: .quarter)])
        score.assignMissingIDs(using: &ids)
        let original = try G.chord(score, 0)
        let originalIDs = Self.nestedIDs(of: original)

        _ = try ReplaceVoiceElement(at: V.location(1), with: .chord(original), identity: .fresh)
            .apply(to: &score, ids: &ids)

        let stillAtSource = try G.chord(score, 0)
        let copy = try G.chord(score, 1)
        #expect(Self.nestedIDs(of: stillAtSource) == originalIDs)
        #expect(Self.nestedIDs(of: copy).isDisjoint(with: originalIDs))
        #expect(copy == original)
        #expect(EditingIdentityInvariants.hasUniqueIDs(score))
    }

    // MARK: 3. .restore and .keep carry nested identity through unchanged

    @Test func restoreCarriesNestedIdentityUnchanged() throws {
        var ids = EIDAllocator()
        var score = V.score(elements: [G.decorated(.quarter)])
        score.assignMissingIDs(using: &ids)
        let original = try G.chord(score, 0)
        let originalSlotEID = V.elements(score).eid(at: 0)

        _ = try ReplaceVoiceElement(
            at: V.location(0), with: .chord(original), identity: .restore(originalSlotEID),
        ).apply(to: &score, ids: &ids)

        let restored = try G.chord(score, 0)
        #expect(Self.nestedIDs(of: restored) == Self.nestedIDs(of: original))
        #expect(V.elements(score).eid(at: 0) == originalSlotEID)
    }

    @Test func keepCarriesNestedIdentityUnchanged() throws {
        let source = try Self.assignedChord()
        let sourceIDs = Self.nestedIDs(of: source)
        var ids = EIDAllocator()
        let kept = EID(first: 7, second: 1)
        let materialized = VoiceSlot.materialize(
            [VoiceSlot(identity: .keep(kept), element: .chord(source))], using: &ids,
        )
        guard case let .chord(result) = materialized[0] else {
            Issue.record("Expected a chord")
            return
        }
        #expect(Self.nestedIDs(of: result) == sourceIDs)
    }

    // MARK: 4. The opt-out: a VoiceSlot built with the carrying form keeps nested identity under .fresh

    @Test func carriedNestedIdentitySurvivesFreshSlot() throws {
        let source = try Self.assignedChord()
        let sourceIDs = Self.nestedIDs(of: source)
        var ids = EIDAllocator()
        let materialized = VoiceSlot.materialize(
            [VoiceSlot(identity: .fresh, element: .chord(source), nestedIdentity: .carried)], using: &ids,
        )
        guard case let .chord(result) = materialized[0] else {
            Issue.record("Expected a chord")
            return
        }
        #expect(Self.nestedIDs(of: result) == sourceIDs)
    }
}
