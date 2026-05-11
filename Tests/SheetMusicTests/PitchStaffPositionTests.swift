#if os(macOS)
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("PitchStaffPosition")
    struct PitchStaffPositionTests {
        // MuseScore TPC convention (natural subset):
        //   F=13, C=14, G=15, D=16, A=17, E=18, B=19.
        // sharp = +7 on TPC, flat = -7.

        @Test("Treble clef: middle C (C4) is step -6")
        func middleCTreble() {
            guard #available(macOS 15.0, *) else { return }
            let result = PitchStaffPosition.step(
                midiPitch: 60, tpc: 14, clef: .treble,
            )
            #expect(result.step == -6)
        }

        @Test("Treble clef: bottom line E4 is step -4")
        func e4Treble() {
            guard #available(macOS 15.0, *) else { return }
            let result = PitchStaffPosition.step(
                midiPitch: 64, tpc: 18, clef: .treble,
            )
            #expect(result.step == -4)
        }

        @Test("Treble clef: top line F5 is step 4")
        func f5Treble() {
            guard #available(macOS 15.0, *) else { return }
            let result = PitchStaffPosition.step(
                midiPitch: 77, tpc: 13, clef: .treble,
            )
            #expect(result.step == 4)
        }

        @Test("Bass clef: D3 is step 0 (middle line)")
        func d3Bass() {
            guard #available(macOS 15.0, *) else { return }
            let result = PitchStaffPosition.step(
                midiPitch: 50, tpc: 16, clef: .bass,
            )
            #expect(result.step == 0)
        }

        @Test("Bass clef: C4 is step 6 (two steps above top line)")
        func middleCBass() {
            guard #available(macOS 15.0, *) else { return }
            let result = PitchStaffPosition.step(
                midiPitch: 60, tpc: 14, clef: .bass,
            )
            #expect(result.step == 6)
        }

        @Test("Alto clef: C4 is step 0 (middle line)")
        func c4Alto() {
            guard #available(macOS 15.0, *) else { return }
            let result = PitchStaffPosition.step(
                midiPitch: 60, tpc: 14, clef: .alto,
            )
            #expect(result.step == 0)
        }

        @Test("Sharp vs flat spelling picks the correct diatonic line")
        func accidentalSpellingAffectsLine() {
            guard #available(macOS 15.0, *) else { return }
            // MIDI 61 spelled as C♯4 (tpc 21): same line as C4 → step -6
            // MIDI 61 spelled as D♭4 (tpc 9):  same line as D4 → step -5
            let cSharp = PitchStaffPosition.step(
                midiPitch: 61, tpc: 21, clef: .treble,
            )
            let dFlat = PitchStaffPosition.step(
                midiPitch: 61, tpc: 9, clef: .treble,
            )
            #expect(cSharp.step == -6)
            #expect(dFlat.step == -5)
        }

        @Test("NotatedClef parses treble/bass/alto/tenor + fallback")
        func clefParsing() {
            guard #available(macOS 15.0, *) else { return }
            #expect(NotatedClef(rawType: "G") == .treble)
            #expect(NotatedClef(rawType: "F") == .bass)
            #expect(NotatedClef(rawType: "C3") == .alto)
            #expect(NotatedClef(rawType: "C4") == .tenor)
            #expect(NotatedClef(rawType: "unknown") == .treble)
        }

        @Test("PERC and PERC2 parse and round-trip distinctly")
        func percussionClefRoundTrip() {
            guard #available(macOS 15.0, *) else { return }
            #expect(NotatedClef(rawType: "PERC") == .percussion)
            #expect(NotatedClef(rawType: "PERC2") == .percussion2)
            #expect(NotatedClef(rawType: "percussion") == .percussion)
            #expect(NotatedClef.percussion.rawType == "PERC")
            #expect(NotatedClef.percussion2.rawType == "PERC2")
        }
    }
#endif
