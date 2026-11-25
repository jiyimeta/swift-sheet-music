@testable import SheetMusicCore
import Testing

/// `SetOrnament` — the palette toggle on the chord's own `ornaments` array.
@Suite("SetOrnament")
struct SetOrnamentTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func ornaments(_ score: Score, _ id: VoiceElementID) -> [ChordOrnament] {
        guard case let .chord(chord)? = score[id] else { return [] }
        return chord.ornaments
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }

    /// The parity fixture with `ornaments` on its first quarter.
    private static func score(_ ornaments: [ChordOrnament]) -> Score {
        var score = EditingFixtures.parityFixture()
        var chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        chord.ornaments = ornaments
        score[slot(0, 1)] = .chord(chord)
        return score
    }

    /// A trill with everything an author or a file can put on one.
    private static let authored: ChordOrnament = {
        var ornament = ChordOrnament(
            kind: .trill, intervalAbove: .init(step: .second, quality: .major), showAccidental: .always,
            showCueNote: .on, startOnUpperNote: true, ornamentStyle: .baroque, plays: false, accidentalAbove: .sharp,
            anchor: .bottom,
        )
        ornament.elementProperties.color = ScoreColor(red: 1, green: 2, blue: 3)
        return ornament
    }()

    @Test("a write appends a bare ornament of the kind", arguments: ChordOrnament.Kind.modeled)
    func writes(kind: ChordOrnament.Kind) throws {
        var score = EditingFixtures.parityFixture()
        let before = score.stableFingerprint
        _ = try SetOrnament(at: Self.slot(0, 1), kind: kind, present: true).apply(to: &score)
        #expect(Self.ornaments(score, Self.slot(0, 1)) == [ChordOrnament(kind: kind)])
        #expect(score.stableFingerprint != before)
    }

    @Test("undo restores the chord exactly, whatever the ornament carried")
    func undoIsExact() throws {
        var bare = EditingFixtures.parityFixture()
        let beforeBare = bare
        let inverse = try SetOrnament(at: Self.slot(0, 1), kind: .turn, present: true).apply(to: &bare)
        _ = try inverse.apply(to: &bare)
        #expect(bare == beforeBare)

        var full = Self.score([Self.authored, ChordOrnament(kind: .turn), ChordOrnament(kind: .trill)])
        let beforeFull = full
        let fingerprint = full.stableFingerprint
        let restore = try SetOrnament(at: Self.slot(0, 1), kind: .trill, present: false).apply(to: &full)
        #expect(full.stableFingerprint != fingerprint)
        _ = try restore.apply(to: &full)
        #expect(full == beforeFull)
        #expect(full.stableFingerprint == fingerprint)
    }

    @Test("a write keeps an ornament of the kind that is already there, with everything it carries")
    func writeKeepsWhatIsThere() throws {
        let standing = [ChordOrnament(kind: .turn), Self.authored]
        var score = Self.score(standing)
        _ = try SetOrnament(at: Self.slot(0, 1), kind: .trill, present: true).apply(to: &score)
        #expect(Self.ornaments(score, Self.slot(0, 1)) == standing)
    }

    @Test("a different kind is added beside the one that is there, which is not touched")
    func differentKindIsAdded() throws {
        var score = Self.score([Self.authored])
        _ = try SetOrnament(at: Self.slot(0, 1), kind: .mordent, present: true).apply(to: &score)
        #expect(Self.ornaments(score, Self.slot(0, 1)) == [Self.authored, ChordOrnament(kind: .mordent)])
    }

    @Test("present == false removes every entry of that kind and leaves the others standing")
    func clears() throws {
        var score = Self.score([Self.authored, ChordOrnament(kind: .turn), ChordOrnament(kind: .trill)])
        _ = try SetOrnament(at: Self.slot(0, 1), kind: .trill, present: false).apply(to: &score)
        #expect(Self.ornaments(score, Self.slot(0, 1)) == [ChordOrnament(kind: .turn)])
    }

    @Test("an unknown kind toggles exactly its own string")
    func unknownKind() throws {
        var score = EditingFixtures.parityFixture()
        let target = Self.slot(0, 1)
        let comma = ChordOrnament.Kind.unknown(subtype: "ornamentComma")
        _ = try SetOrnament(at: target, kind: comma, present: true).apply(to: &score)
        _ = try SetOrnament(at: target, kind: .unknown(subtype: "ornamentOther"), present: false).apply(to: &score)
        _ = try SetOrnament(at: target, kind: .trill, present: false).apply(to: &score)
        #expect(Self.ornaments(score, target) == [ChordOrnament(kind: comma)])
        _ = try SetOrnament(at: target, kind: comma, present: false).apply(to: &score)
        #expect(Self.ornaments(score, target).isEmpty)
    }

    @Test("the other notes, the other bars, the other staff and the chord's articulations are untouched")
    func siblingsUntouched() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetArticulation(at: Self.slot(0, 1), kind: .tenuto, anchor: .above, present: true).apply(to: &score)
        let before = score
        _ = try SetOrnament(at: Self.slot(0, 1), kind: .trill, present: true).apply(to: &score)
        #expect(score.parts[1] == before.parts[1])
        #expect(score.parts[0].staves[0].measures[1...] == before.parts[0].staves[0].measures[1...])
        #expect(Self.ornaments(score, Self.slot(0, 2)).isEmpty)
        guard case let .chord(chord)? = score[Self.slot(0, 1)] else { return #expect(Bool(false)) }
        #expect(chord.articulations == [ChordArticulation(kind: .tenuto, anchor: .above)])
        #expect(chord.notes.map(\.pitch) == [60])
    }

    @Test("a rest, a non-chord element and a missing element are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let onRest = #expect(throws: SheetMusicError.self) {
            _ = try SetOrnament(at: Self.slot(0, 3), kind: .trill, present: true).apply(to: &score)
        }
        #expect(Self.reason(of: onRest) == .wrongElementKind(at: Self.slot(0, 3), expected: .chord))
        let onMeter = #expect(throws: SheetMusicError.self) {
            _ = try SetOrnament(at: Self.slot(0, 0), kind: .trill, present: true).apply(to: &score)
        }
        #expect(Self.reason(of: onMeter) == .wrongElementKind(at: Self.slot(0, 0), expected: .chord))
        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetOrnament(at: Self.slot(0, 9), kind: .trill, present: true).apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(Self.slot(0, 9)))
        #expect(score == before)
    }

    /// The toggle a host builds: read the chord, write the opposite of what it finds. MuseScore's
    /// `Score::toggleArticulation` — the same subtype comes off, a different one is added.
    @Test("through a session, the same kind toggles off and a different one is added; a restatement applies nothing")
    func sessionToggle() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let target = Self.slot(0, 1)
        func kinds() -> [ChordOrnament.Kind] {
            Self.ornaments(session.score, target).map(\.kind)
        }
        #expect(session.apply(.setOrnament(at: target, kind: .trill, present: true)))
        #expect(session.apply(.setOrnament(at: target, kind: .turn, present: true)))
        #expect(kinds() == [.trill, .turn])
        #expect(!session.apply(.setOrnament(at: target, kind: .trill, present: true)))
        #expect(session.apply(.setOrnament(at: target, kind: .trill, present: false)))
        #expect(kinds() == [.turn])
        #expect(session.undo())
        #expect(kinds() == [.trill, .turn])
        #expect(session.redo())
        #expect(kinds() == [.turn])
    }
}
