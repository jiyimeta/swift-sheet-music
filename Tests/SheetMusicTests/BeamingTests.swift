#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import Testing

@Suite("Beaming")
struct BeamingTests {

    @Test("Two adjacent 8ths in 4/4 form one beam group of level 1")
    func twoEighths() {
        guard #available(macOS 15.0, *) else { return }
        let c = Chord(
            duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(
                numerator: 4, denominator: 4)),
            .chord(c),
            .chord(c),
        ])
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(
                numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.count == 1)
        #expect(groups.first?.level == 1)
        #expect(groups.first?.memberIndices.count == 2)
    }

    @Test("Four 16ths within one beat → one beam of level 2")
    func fourSixteenths() {
        guard #available(macOS 15.0, *) else { return }
        let c = Chord(
            duration: .sixteenth,
            notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: Array(
            repeating: .chord(c), count: 4))
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(
                numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.count == 1)
        #expect(groups.first?.level == 2)
    }

    @Test("4 eighths in 4/4 → two beam groups (2 + 2)")
    func twoGroupsAcrossBeats() {
        guard #available(macOS 15.0, *) else { return }
        let c = Chord(
            duration: .eighth,
            notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: Array(
            repeating: .chord(c), count: 4))
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(
                numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.count == 2)
    }

    @Test("Quarter rest between eighths breaks the beam group")
    func restBreaksBeam() {
        guard #available(macOS 15.0, *) else { return }
        let eighth = Chord(
            duration: .eighth,
            notes: [Note(pitch: 60, tpc: 14)])
        let rest = Rest(duration: .quarter)
        let voice = Voice(elements: [
            .chord(eighth),
            .rest(rest),
            .chord(eighth)
        ])
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(
                numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.isEmpty)
    }
}
#endif
