@testable import SheetMusicCore
import Testing

@Suite("Mark planning")
struct MarkPlanningTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let m3 = MeasureRef(measureIndex: 3)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static let allegro = SetTempo.Marking(beatsPerSecond: 2.5)
    private static let fine = Marker(kind: .fine, label: "fine", text: "Fine")
    private static let daCapo = Jump(jumpTo: "start", playUntil: "fine", text: "D.C. al Fine")

    @Test("each mark intent applies through the session and undoes")
    func appliesAndUndoes() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        let before = session.score
        // m2: [E4, E4] → clef at 0 → [clef, E4, E4]; the E4s are elements 1 and 2 from here on.
        #expect(session.apply(.setClef(before: Self.slot(2, 0), clef: .bass)))
        #expect(session.apply(.setTempo(anchor: Self.slot(2, 1), marking: Self.allegro)))
        #expect(session.apply(.setStaffText(anchor: Self.slot(2, 1), text: "pizz.", isSystemText: false)))
        #expect(session.apply(.setDynamic(at: Self.slot(2, 1), subtype: "f"))) // [clef, dyn, E4, E4]
        #expect(session.apply(.setFermata(at: Self.slot(2, 3), subtype: "fermataAbove", timeStretch: 1.5)))
        #expect(session.apply(.setBreath(after: Self.slot(2, 4), kind: .breathMark(.comma), pause: 0)))
        #expect(session.apply(.setJumps(at: Self.m3, jumps: [Self.daCapo])))
        #expect(session.apply(.setMarkers(at: Self.m3, markers: [Self.fine])))
        #expect(session.apply(.removeClef(at: Self.slot(2, 0))))
        for _ in 0 ..< 9 {
            #expect(session.undo())
        }
        #expect(session.score == before)
    }

    @Test("restating what the score already says plans to nothing")
    func restatingIsNothingToApply() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(session.apply(.setClef(before: Self.slot(2, 0), clef: .bass)))
        #expect(!session.apply(.setClef(before: Self.slot(2, 1), clef: .bass)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(!session.apply(.setTempo(anchor: Self.slot(0, 1), marking: nil)))
        #expect(session.apply(.setTempo(anchor: Self.slot(0, 1), marking: Self.allegro)))
        #expect(!session.apply(.setTempo(anchor: Self.slot(0, 1), marking: Self.allegro)))
        #expect(!session.apply(.setStaffText(anchor: Self.slot(0, 1), text: nil, isSystemText: true)))
        #expect(session.apply(.setStaffText(anchor: Self.slot(0, 1), text: "rit.", isSystemText: true)))
        #expect(!session.apply(.setStaffText(anchor: Self.slot(0, 1), text: " rit. ", isSystemText: true)))
        #expect(!session.apply(.setDynamic(at: Self.slot(0, 1), subtype: nil)))
        #expect(session.apply(.setDynamic(at: Self.slot(0, 1), subtype: "p")))
        #expect(!session.apply(.setDynamic(at: Self.slot(0, 2), subtype: "p")))
        #expect(!session.apply(.setFermata(at: Self.slot(0, 2), subtype: nil, timeStretch: 1)))
        #expect(!session.apply(.setBreath(after: Self.slot(0, 2), kind: nil, pause: 0)))
        #expect(!session.apply(.setJumps(at: Self.m3, jumps: [])))
        #expect(!session.apply(.setMarkers(at: Self.m3, markers: [])))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test("a refused command surfaces its reason, not nothingToApply and not a crash")
    func refusalSurfaces() {
        let session = ScoreEditSession(score: EditingFixtures.parityFixture())
        #expect(!session.apply(.removeClef(at: Self.slot(0, 1))))
        #expect(session.lastRefusal?.reason == .wrongElementKind(at: Self.slot(0, 1), expected: .clef))
        #expect(!session.apply(.setStaffText(anchor: Self.slot(0, 1), text: "  ", isSystemText: false)))
        #expect(session.lastRefusal?.reason == .emptyStaffText)
        #expect(!session.apply(.setJumps(at: MeasureRef(measureIndex: 9), jumps: [])))
        #expect(session.lastRefusal?.reason == .targetNotFound(
            VoiceElementID(staff: Self.flute, measureIndex: 9, voiceIndex: 0, elementIndex: 0),
        ))
    }
}
