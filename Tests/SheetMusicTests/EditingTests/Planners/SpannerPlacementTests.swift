@testable import SheetMusicCore
import Testing

/// The one engine behind intents 62…72: which storage form a kind uses, how a range collapses to one voice, what
/// tick each kind ends at, and the two refusals (`duplicateSpanner`, `noSpannerAtLocation`).
@Suite("SpannerPlacement")
struct SpannerPlacementTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ staff: StaffAddress, _ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func elements(_ score: Score, _ staff: Int, _ measure: Int) -> [VoiceElement] {
        score.parts[staff].staves[0].measures[measure].voices[0].elements
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    private static func operation(of error: SheetMusicError?) -> String? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.operation
    }

    /// The engine stamps whatever `operation` its caller passes; the eleven commands each pass their own type
    /// name. This suite drives the engine directly, so it passes a stand-in and `refusals` pins that it arrives.
    private static let testOperation = "SpannerPlacementUnderTest"

    private static func add(
        _ template: Spanner, over range: VoiceElementRange, in score: Score,
    ) throws -> any EditCommand {
        try SpannerPlacement.add(template, over: range, in: score, operation: testOperation)
    }

    private static func remove(
        _ kind: Spanner.Kind, at location: VoiceElementID, in score: Score,
    ) throws -> any EditCommand {
        try SpannerPlacement.remove(kind, at: location, in: score, operation: testOperation)
    }

    private static func hairpin() -> Spanner {
        Spanner(kind: .hairpin, rawType: "HairPin", hairpin: .init(subtype: .crescendo))
    }

    @Test("each kind knows its storage form")
    func storageForms() {
        #expect(SpannerPlacement.storage(of: .slur) == .chordAnchored)
        #expect(SpannerPlacement.storage(of: .volta) == .measureVolta)
        // The eight line kinds, plus the two that are not spanner commands at all — `.glissando` lives on
        // `Note.glissando` and `.other` is the decoder's catch-all — which the engine still routes here.
        for kind in [
            Spanner.Kind.hairpin, .pedal, .ottava, .textLine, .trill, .vibrato, .palmMute, .letRing,
            .glissando, .other,
        ] {
            #expect(SpannerPlacement.storage(of: kind) == .voiceElement)
        }
    }

    /// bar 0 is `[ts, C4 q, D4 q, r q, r q]`; a hairpin over the two chords ends at the SECOND chord's END tick,
    /// i.e. 1/2 into the bar — the mid-measure spelling.
    @Test("a line spanner is inserted before the first chord and ends at the last element's end tick")
    func lineSpanner() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(Self.flute, 0, 1), end: Self.slot(Self.flute, 0, 2))
        _ = try Self.add(Self.hairpin(), over: range, in: score).apply(to: &score)
        let elements = Self.elements(score, 0, 0)
        #expect(elements.count == 6)
        guard case let .spanner(written) = elements[1] else { Issue.record("expected the spanner at 1"); return }
        #expect(written.kind == .hairpin)
        #expect(written.nextMeasuresOffset == 0)
        #expect(written.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
        #expect(elements[2] == .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])))
    }

    /// bar 2 is `[E4 h ~, E4 h]`; a slur over both is stored on the FIRST chord and points at the SECOND's
    /// ONSET (1/2), not its end — the slur / line-spanner difference, in one assertion.
    @Test("a slur is stored on the start chord and points at the end chord's onset")
    func slur() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(Self.flute, 2, 0), end: Self.slot(Self.flute, 2, 1))
        _ = try Self.add(Spanner(kind: .slur, rawType: "Slur"), over: range, in: score)
            .apply(to: &score)
        let elements = Self.elements(score, 0, 2)
        #expect(elements.count == 2) // no element inserted
        guard case let .chord(head) = elements[0] else { Issue.record("expected the head chord"); return }
        #expect(head.spanners.count == 1)
        #expect(head.spanners[0].nextMeasuresOffset == 0)
        #expect(head.spanners[0].nextFractionsOffset == Fraction(numerator: 1, denominator: 2))
    }

    /// The bounds may be given in either order, and a range naming two staves narrows to the earlier bound's.
    @Test("the range is normalized and narrowed to one voice")
    func rangeNormalization() throws {
        var score = EditingFixtures.parityFixture()
        let reversed = VoiceElementRange(start: Self.slot(Self.flute, 0, 2), end: Self.slot(Self.flute, 0, 1))
        _ = try Self.add(Self.hairpin(), over: reversed, in: score).apply(to: &score)
        guard case let .spanner(written) = Self.elements(score, 0, 0)[1] else {
            Issue.record("expected the spanner at 1"); return
        }
        // The reversed range covers BOTH chords, exactly as the forward one does. A `run(of:)` that collapsed it
        // to its (single) start bound would still put a spanner at index 1 — but ending at 1/4, not 1/2.
        #expect(written.nextMeasuresOffset == 0)
        #expect(written.nextFractionsOffset == Fraction(numerator: 1, denominator: 2))

        var crossStaff = EditingFixtures.parityFixture()
        let across = VoiceElementRange(start: Self.slot(Self.flute, 0, 1), end: Self.slot(Self.cello, 0, 1))
        _ = try Self.add(Self.hairpin(), over: across, in: crossStaff).apply(to: &crossStaff)
        #expect(Self.elements(crossStaff, 1, 0) == Self.elements(EditingFixtures.parityFixture(), 1, 0))
        // Narrowed to the flute's voice 0, the run is `[C4, D4, r, r]` — the whole bar, so the end tick rolls
        // onto bar 1's downbeat and the spelling is `(1, nil)`, not the `(0, 1/2)` of the two chords alone.
        guard case let .spanner(spanner) = Self.elements(crossStaff, 0, 0)[1] else {
            Issue.record("expected the spanner at 1 of the flute"); return
        }
        #expect(spanner.nextMeasuresOffset == 1)
        #expect(spanner.nextFractionsOffset == nil)
    }

    /// A volta ignores the range's staff and voice: it goes to voice 0 of the canonical staff, at index 0, and
    /// ends at the end of the last measure of the range. Bar 3 is the LAST bar, so the score-end spelling of
    /// `Spanner.offsets` applies — `(0, 1/1)`, not `(1, nil)`.
    @Test("a volta is measure-granular on the canonical staff, and the last bar takes the score-end spelling")
    func volta() throws {
        var score = EditingFixtures.parityFixture()
        let midRange = VoiceElementRange(start: Self.slot(Self.cello, 1, 0), end: Self.slot(Self.cello, 1, 0))
        _ = try Self.add(
            Spanner(kind: .volta, rawType: "Volta", voltaEndings: [1]), over: midRange, in: score,
        ).apply(to: &score)
        guard case let .spanner(mid) = Self.elements(score, 0, 1)[0] else {
            Issue.record("expected the volta on the canonical staff"); return
        }
        #expect(mid.nextMeasuresOffset == 1)
        #expect(mid.nextFractionsOffset == nil)

        var last = EditingFixtures.parityFixture()
        let lastRange = VoiceElementRange(start: Self.slot(Self.flute, 3, 0), end: Self.slot(Self.flute, 3, 0))
        _ = try Self.add(
            Spanner(kind: .volta, rawType: "Volta", voltaEndings: [2]), over: lastRange, in: last,
        ).apply(to: &last)
        guard case let .spanner(final) = Self.elements(last, 0, 3)[0] else {
            Issue.record("expected the volta"); return
        }
        #expect(final.nextMeasuresOffset == 0)
        #expect(final.nextFractionsOffset == Fraction(numerator: 1, denominator: 1))
    }

    /// Bar 3 is `[rest measure]` — a single-element range naming a bare measure rest, the LAST bar. A line
    /// spanner (unlike a slur) is legal over one element, and a rest resolves as a member since a rest IS a
    /// `.chord` (`VoiceElement.rest(duration:)`). This hits the score-end roll of `Spanner.offsets` through a
    /// DIFFERENT path than the volta's last-bar case: `score.end(of:)` on the rest itself, not the canonical
    /// staff's measure duration table — so it must be pinned separately.
    @Test("a line spanner over the last bar's measure rest also takes the score-end spelling")
    func lineSpannerOverLastBarMeasureRest() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(Self.flute, 3, 0), end: Self.slot(Self.flute, 3, 0))
        _ = try Self.add(Self.hairpin(), over: range, in: score).apply(to: &score)
        let elements = Self.elements(score, 0, 3)
        #expect(elements.count == 2)
        guard case let .spanner(written) = elements[0] else { Issue.record("expected the spanner at 0"); return }
        #expect(written.kind == .hairpin)
        #expect(written.nextMeasuresOffset == 0)
        #expect(written.nextFractionsOffset == Fraction(numerator: 1, denominator: 1))
        #expect(elements[1] == .rest(duration: .measure))
    }

    @Test("a tuplet straddling the insertion point keeps its start and grows its end")
    func tupletRemap() throws {
        var score = EditingFixtures.fourQuarterRests()
        _ = try CreateTuplet(at: Self.slot(Self.flute, 0, 1), actualNotes: 3, normalNotes: 2).apply(to: &score)
        let range = VoiceElementRange(start: Self.slot(Self.flute, 0, 2), end: Self.slot(Self.flute, 0, 3))
        _ = try Self.add(Self.hairpin(), over: range, in: score).apply(to: &score)
        #expect(score.parts[0].staves[0].measures[0].voices[0].tuplets
            == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 4)])
    }

    @Test("undo restores the score exactly, for both storage forms")
    func undoIsExact() throws {
        for template in [Self.hairpin(), Spanner(kind: .slur, rawType: "Slur")] {
            var score = EditingFixtures.parityFixture()
            let before = score
            let range = VoiceElementRange(start: Self.slot(Self.flute, 2, 0), end: Self.slot(Self.flute, 2, 1))
            let inverse = try Self.add(template, over: range, in: score).apply(to: &score)
            #expect(score != before)
            _ = try inverse.apply(to: &score)
            #expect(score == before)
        }
    }

    @Test("remove takes the element back off, for both storage forms, and its inverse puts it back")
    func removeRoundTrips() throws {
        for template in [Self.hairpin(), Spanner(kind: .slur, rawType: "Slur")] {
            var score = EditingFixtures.parityFixture()
            let plain = score
            let range = VoiceElementRange(start: Self.slot(Self.flute, 2, 0), end: Self.slot(Self.flute, 2, 1))
            _ = try Self.add(template, over: range, in: score).apply(to: &score)
            let written = score
            let inverse = try Self.remove(template.kind, at: Self.slot(Self.flute, 2, 0), in: score)
                .apply(to: &score)
            #expect(score == plain)
            _ = try inverse.apply(to: &score)
            #expect(score == written)
        }
    }

    @Test("a second spanner of the same kind at the same position is refused, found by walking the whole run")
    func duplicate() throws {
        var score = EditingFixtures.parityFixture()
        let range = VoiceElementRange(start: Self.slot(Self.flute, 2, 0), end: Self.slot(Self.flute, 2, 1))
        _ = try Self.add(Self.hairpin(), over: range, in: score).apply(to: &score)
        let firstWrite = Self.elements(score, 0, 2)[0]
        // The chord is element 1 now; put a SECOND, different-kind spanner in front of it too, so two
        // annotations of different kinds precede the chord — a naive "look one slot back" duplicate check would
        // see only the pedal and miss the hairpin two slots back.
        let shifted = VoiceElementRange(start: Self.slot(Self.flute, 2, 1), end: Self.slot(Self.flute, 2, 2))
        _ = try Self.add(Spanner(kind: .pedal, rawType: "Pedal"), over: shifted, in: score)
            .apply(to: &score)
        // The second insert splices the voice's element list; the hairpin has to come back out of it verbatim,
        // offsets and all, rather than being re-derived from its new neighbours.
        #expect(Self.elements(score, 0, 2)[0] == firstWrite)
        let after = score
        // The chord is element 2 now; duplicate detection must walk the whole [hairpin, pedal] run to find it.
        let again = VoiceElementRange(start: Self.slot(Self.flute, 2, 2), end: Self.slot(Self.flute, 2, 3))
        let error = #expect(throws: SheetMusicError.self) {
            _ = try Self.add(Self.hairpin(), over: again, in: score)
        }
        #expect(Self.reason(of: error) == .duplicateSpanner(at: Self.slot(Self.flute, 2, 2), kind: .hairpin))
        // A DIFFERENT kind at the same position is fine.
        _ = try Self.add(
            Spanner(kind: .ottava, rawType: "Ottava"), over: again, in: score,
        ).apply(to: &score)
        #expect(score != after)
    }

    @Test("""
    the refusals: a slur with nothing to slur to, an empty range, a removal with nothing to remove, \
    and a removal of the wrong kind
    """)
    func refusals() throws {
        let score = EditingFixtures.parityFixture()
        let single = VoiceElementRange(start: Self.slot(Self.flute, 2, 0), end: Self.slot(Self.flute, 2, 0))
        let lonely = #expect(throws: SheetMusicError.self) {
            _ = try Self.add(Spanner(kind: .slur, rawType: "Slur"), over: single, in: score)
        }
        #expect(Self.reason(of: lonely) == .noNextChord(at: Self.slot(Self.flute, 2, 0)))
        // The engine stamps the caller's `operation` rather than a fixed literal of its own; the eleven commands
        // each pass their own type name, so a host can tell a refused pedal from a refused trill.
        #expect(Self.operation(of: lonely) == Self.testOperation)
        let missing = VoiceElementRange(start: Self.slot(Self.flute, 9, 0), end: Self.slot(Self.flute, 9, 0))
        let goneAway = #expect(throws: SheetMusicError.self) {
            _ = try Self.add(Self.hairpin(), over: missing, in: score)
        }
        #expect(Self.reason(of: goneAway) == .targetNotFound(Self.slot(Self.flute, 9, 0)))
        let nothingThere = #expect(throws: SheetMusicError.self) {
            _ = try Self.remove(.slur, at: Self.slot(Self.flute, 2, 0), in: score)
        }
        #expect(Self.reason(of: nothingThere) == .noSpannerAtLocation(Self.slot(Self.flute, 2, 0)))
        let notAnElement = #expect(throws: SheetMusicError.self) {
            _ = try Self.remove(.hairpin, at: Self.slot(Self.flute, 0, 0), in: score)
        }
        #expect(Self.reason(of: notAnElement)
            == .wrongElementKind(at: Self.slot(Self.flute, 0, 0), expected: .spanner))
        // A `.spanner` element IS there, but of a different kind — the line-spanner-storage wrong-kind shape.
        var withHairpin = EditingFixtures.parityFixture()
        let hairpinRange = VoiceElementRange(start: Self.slot(Self.flute, 2, 0), end: Self.slot(Self.flute, 2, 1))
        _ = try Self.add(Self.hairpin(), over: hairpinRange, in: withHairpin).apply(to: &withHairpin)
        let wrongKind = #expect(throws: SheetMusicError.self) {
            _ = try Self.remove(.pedal, at: Self.slot(Self.flute, 2, 0), in: withHairpin)
        }
        #expect(Self.reason(of: wrongKind) == .noSpannerAtLocation(Self.slot(Self.flute, 2, 0)))
    }
}
