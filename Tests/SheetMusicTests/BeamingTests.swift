#if os(macOS)
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("Beaming")
    struct BeamingTests {
        @Test("Two adjacent 8ths in 4/4 form one beam group of level 1")
        func twoEighths() {
            guard #available(macOS 15.0, *) else { return }
            let c = Chord(
                duration: .eighth, notes: [Note(pitch: 60, tpc: 14)]
            )
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(
                    numerator: 4, denominator: 4
                )),
                .chord(c),
                .chord(c),
            ])
            let groups = LayoutEngine.beamGroups(
                voice: voice,
                timeSignature: TimeSignature(
                    numerator: 4, denominator: 4
                ),
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
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let voice = Voice(elements: Array(
                repeating: .chord(c), count: 4
            ))
            let groups = LayoutEngine.beamGroups(
                voice: voice,
                timeSignature: TimeSignature(
                    numerator: 4, denominator: 4
                ),
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
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let voice = Voice(elements: Array(
                repeating: .chord(c), count: 4
            ))
            let groups = LayoutEngine.beamGroups(
                voice: voice,
                timeSignature: TimeSignature(
                    numerator: 4, denominator: 4
                ),
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
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let voice = Voice(elements: Array(
                repeating: .chord(c), count: 8
            ))
            let groups = LayoutEngine.beamGroups(
                voice: voice,
                timeSignature: TimeSignature(
                    numerator: 4, denominator: 4
                ),
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
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let voice = Voice(elements: [
                .chord(eighth),
                .rest(duration: .quarter),
                .chord(eighth),
            ])
            let groups = LayoutEngine.beamGroups(
                voice: voice,
                timeSignature: TimeSignature(
                    numerator: 4, denominator: 4
                ),
                division: 480
            )
            #expect(groups.isEmpty)
        }

        @Test("8 straight 16ths in 4/4 split at the beat (2 groups of 4)")
        func eightSixteenthsSplitAtBeat() {
            guard #available(macOS 15.0, *) else { return }
            let c = Chord(
                duration: .sixteenth,
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let voice = Voice(elements: Array(
                repeating: .chord(c), count: 8
            ))
            let groups = LayoutEngine.beamGroups(
                voice: voice,
                timeSignature: TimeSignature(
                    numerator: 4, denominator: 4
                ),
                division: 480
            )
            // Two uniform level-2 beats still flush because secondary
            // beams break at every beat — not a single merged run of 8.
            #expect(groups.count == 2)
            #expect(groups[0].memberIndices.count == 4)
            #expect(groups[1].memberIndices.count == 4)
            #expect(groups[0].level == 2)
            #expect(groups[1].level == 2)
        }

        @Test("16 straight 16ths in 4/4 → 4 groups of 4 (one per beat)")
        func sixteenSixteenthsFourGroups() {
            guard #available(macOS 15.0, *) else { return }
            let c = Chord(
                duration: .sixteenth,
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let voice = Voice(elements: Array(
                repeating: .chord(c), count: 16
            ))
            let groups = LayoutEngine.beamGroups(
                voice: voice,
                timeSignature: TimeSignature(
                    numerator: 4, denominator: 4
                ),
                division: 480
            )
            #expect(groups.count == 4)
            for g in groups {
                #expect(g.memberIndices.count == 4)
                #expect(g.level == 2)
            }
        }

        @Test("Two 16ths straddling a beat boundary are not beamed together")
        func sixteenthPairAcrossBeat() {
            guard #available(macOS 15.0, *) else { return }
            // User-reported pattern: half rest + sparse 16th figure over
            // beats 3-4. Elements 4 and 5 are the two consecutive 16th
            // notes that cross the beat 3→4 boundary and must NOT beam.
            // Only elements 7 and 8 (both inside beat 4) remain a pair.
            let c16 = Chord(
                duration: .sixteenth,
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let e16 = Chord(
                duration: .sixteenth,
                notes: [Note(pitch: 64, tpc: 18)]
            )
            let voice = Voice(elements: [
                .rest(duration: .half), // 0
                .rest(duration: .sixteenth), // 1
                .chord(c16), // 2
                .rest(duration: .sixteenth), // 3
                .chord(c16), // 4 — end of beat 3
                .chord(e16), // 5 — start of beat 4
                .rest(duration: .sixteenth), // 6
                .chord(c16), // 7
                .chord(e16), // 8
            ])
            let groups = LayoutEngine.beamGroups(
                voice: voice,
                timeSignature: TimeSignature(
                    numerator: 4, denominator: 4
                ),
                division: 480
            )
            #expect(groups.count == 1)
            #expect(groups.first?.memberIndices == [7, 8])
            #expect(groups.first?.level == 2)
        }
    }
#endif
