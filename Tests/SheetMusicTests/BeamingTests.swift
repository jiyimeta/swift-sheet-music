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

    @Test("4 eighths in 4/4 → one beam group (half-note boundary)")
    func fourEighthsOneGroup() {
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
        // 4/4: beam group = half note (960 ticks). 4 8ths span exactly
        // one half-note — one group, not two.
        #expect(groups.count == 1)
        #expect(groups.first?.memberIndices.count == 4)
    }

    @Test("8 eighths in 4/4 → two beam groups at half-bar boundary")
    func eightEighthsTwoGroups() {
        guard #available(macOS 15.0, *) else { return }
        let c = Chord(
            duration: .eighth,
            notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: Array(
            repeating: .chord(c), count: 8))
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(
                numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.count == 2)
        #expect(groups[0].memberIndices.count == 4)
        #expect(groups[1].memberIndices.count == 4)
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
