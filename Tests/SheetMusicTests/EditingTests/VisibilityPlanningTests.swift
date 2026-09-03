@testable import SheetMusicCore
import Testing

@Suite("Visibility planning")
struct VisibilityPlanningTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func celloBar1(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: cello, measureIndex: 1, voiceIndex: 0, elementIndex: element)
    }

    private static let celloLeadNote = NoteID(
        staff: cello, measureIndex: 1, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
    )

    /// The parity fixture with two eighths written into the cello's bar 1 — the exact preparation Task 9's chain
    /// performs (steps S+1 / S+2), pinned here so the chain's assumption about the resulting shape is a test,
    /// not a hope: `[G2 e, A2 e, r q, r h]`, elements 0 and 1 one beam group led by 0.
    private static func beamedSession() -> ScoreEditSession {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(session.apply(.inputNote(
            at: RestID(staff: cello, measureIndex: 1, voiceIndex: 0, elementIndex: 0), pitch: 43, tpc: 15,
            duration: .eighth,
        )))
        #expect(session.apply(.inputNote(
            at: RestID(staff: cello, measureIndex: 1, voiceIndex: 0, elementIndex: 1), pitch: 45, tpc: 17,
            duration: nil,
        )))
        let elements = session.score.parts[1].staves[0].measures[1].voices[0].elements
        #expect(elements.count == 4)
        #expect(elements.map(\.isRest) == [false, false, true, true])
        #expect(SetBeamVisible.leader(of: celloBar1(1), in: session.score) == celloBar1(0))
        return session
    }

    @Test("each visibility intent applies through the session and undoes")
    func appliesAndUndoes() {
        let session = Self.beamedSession()
        let before = session.score
        #expect(session.apply(.setElementVisible(at: Self.celloBar1(1), visible: false)))
        #expect(session.apply(.setNoteVisible(at: Self.celloLeadNote, visible: false)))
        #expect(session.apply(.setStemVisible(at: Self.celloBar1(0), visible: false)))
        #expect(session.apply(.setBeamVisible(at: Self.celloBar1(1), visible: false))) // named at the FOLLOWER
        guard case let .chord(lead)? = session.score[Self.celloBar1(0)],
              case let .chord(follower)? = session.score[Self.celloBar1(1)]
        else { Issue.record("expected two chords"); return }
        #expect(!lead.beamVisible) // re-targeted to the leader
        #expect(follower.beamVisible)
        #expect(!follower.visible && !lead.notes[0].visible && !lead.stemVisible)
        #expect(session.lastAffectedLocation == Self.celloBar1(0)) // the command's location is the leader
        for _ in 0 ..< 4 {
            #expect(session.undo())
        }
        #expect(session.score == before)
    }

    @Test("restating what the score already says plans to nothing — through either beam member")
    func restatingIsNothingToApply() {
        let session = Self.beamedSession()
        #expect(!session.apply(.setElementVisible(at: Self.celloBar1(1), visible: true)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(!session.apply(.setNoteVisible(at: Self.celloLeadNote, visible: true)))
        #expect(!session.apply(.setStemVisible(at: Self.celloBar1(0), visible: true)))
        #expect(!session.apply(.setBeamVisible(at: Self.celloBar1(0), visible: true)))
        #expect(!session.apply(.setBeamVisible(at: Self.celloBar1(1), visible: true)))
        #expect(session.apply(.setBeamVisible(at: Self.celloBar1(1), visible: false)))
        #expect(!session.apply(.setBeamVisible(at: Self.celloBar1(0), visible: false))) // the leader now reads hidden
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("a refused command surfaces its reason, not nothingToApply and not a crash")
    func refusalSurfaces() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let quarter = VoiceElementID(staff: Self.flute, measureIndex: 0, voiceIndex: 0, elementIndex: 1) // C4 q
        #expect(!session.apply(.setBeamVisible(at: quarter, visible: false)))
        #expect(session.lastRefusal?.reason == .notBeamed(at: quarter))
        let rest = VoiceElementID(staff: Self.flute, measureIndex: 3, voiceIndex: 0, elementIndex: 0)
        #expect(!session.apply(.setStemVisible(at: rest, visible: false)))
        #expect(session.lastRefusal?.reason == .wrongElementKind(at: rest, expected: .chord))
        let missing = VoiceElementID(staff: Self.flute, measureIndex: 9, voiceIndex: 0, elementIndex: 0)
        #expect(!session.apply(.setElementVisible(at: missing, visible: false)))
        #expect(session.lastRefusal?.reason == .targetNotFound(missing))
    }
}
