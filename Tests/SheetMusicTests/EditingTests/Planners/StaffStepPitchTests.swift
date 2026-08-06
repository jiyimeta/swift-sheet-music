@testable import SheetMusicCore
import Testing

@Suite("StaffStepPitch")
struct StaffStepPitchTests {
    // MARK: - diatonicShift, C major (keySig 0)

    @Test func `up one staff step from C4 in C major lands on D4`() {
        let result = StaffStepPitch.diatonicShift(from: Note(pitch: 60, tpc: 14), bySteps: 1, keySig: 0)

        #expect(result?.pitch == 62)
        #expect(result?.tpc == 16)
    }

    @Test func `up two staff steps from C4 in C major lands on E4`() {
        let result = StaffStepPitch.diatonicShift(from: Note(pitch: 60, tpc: 14), bySteps: 2, keySig: 0)

        #expect(result?.pitch == 64)
        #expect(result?.tpc == 18)
    }

    @Test func `down one staff step from C4 in C major lands on B3`() {
        let result = StaffStepPitch.diatonicShift(from: Note(pitch: 60, tpc: 14), bySteps: -1, keySig: 0)

        #expect(result?.pitch == 59)
        #expect(result?.tpc == 19)
    }

    @Test func `up seven staff steps from C4 in C major carries the octave to C5`() {
        let result = StaffStepPitch.diatonicShift(from: Note(pitch: 60, tpc: 14), bySteps: 7, keySig: 0)

        #expect(result?.pitch == 72)
        #expect(result?.tpc == 14)
    }

    // MARK: - diatonicShift, other keys

    @Test func `up one staff step from E4 in G major lands on F sharp 4`() {
        let result = StaffStepPitch.diatonicShift(from: Note(pitch: 64, tpc: 18), bySteps: 1, keySig: 1)

        #expect(result?.pitch == 66)
        #expect(result?.tpc == 20)
    }

    @Test func `up one staff step from A4 in F major lands on B flat 4`() {
        let result = StaffStepPitch.diatonicShift(from: Note(pitch: 69, tpc: 17), bySteps: 1, keySig: -1)

        #expect(result?.pitch == 70)
        #expect(result?.tpc == 12)
    }

    // MARK: - diatonicShift, range

    @Test func `a shift past MIDI 127 returns nil`() {
        // G9, the top of the MIDI range in this app's octave convention (C4 = 60).
        let result = StaffStepPitch.diatonicShift(from: Note(pitch: 127, tpc: 15), bySteps: 1, keySig: 0)

        #expect(result == nil)
    }

    // MARK: - inKeyTpc

    @Test func `inKeyTpc leaves a C natural unchanged in C major`() {
        #expect(StaffStepPitch.inKeyTpc(naturalTpc: 14, keySig: 0) == 14)
    }

    @Test func `inKeyTpc sharps an F natural in G major`() {
        #expect(StaffStepPitch.inKeyTpc(naturalTpc: 13, keySig: 1) == 20)
    }

    @Test func `inKeyTpc flats a B natural in F major`() {
        #expect(StaffStepPitch.inKeyTpc(naturalTpc: 19, keySig: -1) == 12)
    }
}
