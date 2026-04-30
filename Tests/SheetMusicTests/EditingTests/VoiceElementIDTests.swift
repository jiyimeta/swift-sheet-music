@testable import SheetMusicCore
import Testing

@Suite("VoiceElementID")
struct VoiceElementIDTests {
    @Test("Subscript getter resolves a valid path")
    func getterValid() {
        let score = EditingFixtures.fourQuarterRests()
        let id = VoiceElementID(staffIndex: 0, measureIndex: 0,
                                voiceIndex: 0, elementIndex: 1)
        guard case let .rest(rest) = score[id] else {
            Issue.record("expected a rest at index 1")
            return
        }
        #expect(rest.duration == .quarter)
    }

    @Test("Subscript getter returns nil for out-of-range path")
    func getterOutOfRange() {
        let score = EditingFixtures.fourQuarterRests()
        let id = VoiceElementID(staffIndex: 0, measureIndex: 0,
                                voiceIndex: 0, elementIndex: 99)
        #expect(score[id] == nil)
    }

    @Test("Subscript setter replaces the element at the given path")
    func setterReplaces() {
        var score = EditingFixtures.fourQuarterRests()
        let id = VoiceElementID(staffIndex: 0, measureIndex: 0,
                                voiceIndex: 0, elementIndex: 1)
        let chord = Chord(duration: .quarter,
                          notes: [Note(pitch: 60, tpc: 14)])
        score[id] = .chord(chord)
        guard case let .chord(c) = score[id] else {
            Issue.record("expected chord after set")
            return
        }
        #expect(c.notes.first?.pitch == 60)
    }

    @Test("RestID converts to VoiceElementID with same indices")
    func fromRestID() {
        let restID = RestID(staffIndex: 0, measureIndex: 0,
                            voiceIndex: 0, elementIndex: 1)
        let veID = VoiceElementID(restID)
        #expect(veID.staffIndex == 0)
        #expect(veID.measureIndex == 0)
        #expect(veID.voiceIndex == 0)
        #expect(veID.elementIndex == 1)
    }
}
