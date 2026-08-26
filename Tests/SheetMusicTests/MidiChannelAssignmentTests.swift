#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// Regression tests for melodic MIDI channel assignment.
    ///
    /// A score with more melodic playback flavours than there are usable MIDI
    /// channels used to let the assignment counter run unbounded. Downstream
    /// `& 0x0F` masking (in `MidiWriter` and the live synth's
    /// `MusicDeviceMIDIEvent`) then aliased high channels back down — the 25th
    /// melodic flavour landed on wire channel 9 (GM percussion), and a melodic
    /// program-change there faulted AUMIDISynth (`SamplerElement::UpdateState`
    /// → `[caulk] CAVerboseAbort`, seen in Crashlytics). Assignment must now stay
    /// within the 15 melodic channels and never collide with the reserved drum
    /// channel, reusing channels (wrapping) once they are exhausted.
    struct MidiChannelAssignmentTests {
        /// A minimal, valid single-note staff. `assignChannels` ignores staff
        /// content, but `Part` requires a staff — reuse one value across parts.
        private static let sampleStaff: Staff = {
            let note = Note(pitch: 60, tpc: 14)
            let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
            return Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])
        }()

        private func melodicPart(id: String, flavours: Int) -> Part {
            let channels = (0 ..< flavours).map { _ in InstrumentChannel() }
            return Part(
                id: id,
                instrument: Instrument(id: id, longName: id, channels: channels),
                staves: [Self.sampleStaff],
            )
        }

        private func drumPart(id: String) -> Part {
            Part(
                id: id,
                instrument: Instrument(id: id, longName: id, useDrumset: true),
                staves: [Self.sampleStaff],
            )
        }

        private func assignedChannels(_ parts: [Part]) -> [Int] {
            MidiRenderer.assignChannels(score: Score(division: 480, parts: parts))
                .flatMap(\.self)
                .map(\.channel)
        }

        /// 30 melodic flavours (double the 15 available channels) must all land on
        /// valid, non-drum channels — no aliasing onto channel 9, none above 15.
        /// This is the direct guard against the CAVerboseAbort crash.
        @Test func manyMelodicFlavoursStayWithinValidChannels() {
            // 10 parts × 3 flavours = 30 melodic flavours.
            let channels = assignedChannels((0 ..< 10).map { melodicPart(id: "P\($0)", flavours: 3) })
            #expect(channels.count == 30)
            for ch in channels {
                #expect(ch >= 0 && ch <= 15, "channel \(ch) is outside the MIDI range 0…15")
                #expect(
                    ch != MidiRenderer.drumChannel,
                    "a melodic flavour was assigned the reserved drum channel \(ch)",
                )
            }
        }

        /// Within 15 melodic flavours, assignment is unchanged from the original
        /// skip-9 counter: 0…8, then 10…15.
        @Test func firstFifteenMatchLegacySkipNineOrder() {
            let channels = assignedChannels((0 ..< 15).map { melodicPart(id: "P\($0)", flavours: 1) })
            #expect(channels == [0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15])
        }

        /// The 16th melodic flavour wraps back to channel 0 (reuse) rather than
        /// spilling to an out-of-range 16.
        @Test func sixteenthMelodicFlavourWrapsToZero() {
            let channels = assignedChannels((0 ..< 16).map { melodicPart(id: "P\($0)", flavours: 1) })
            #expect(channels.count == 16)
            #expect(channels.last == 0)
        }

        /// A drumset part is still routed to the reserved percussion channel.
        @Test func drumsetPartUsesDrumChannel() {
            let channels = assignedChannels([drumPart(id: "Drums")])
            #expect(channels == [MidiRenderer.drumChannel])
        }
    }
#endif
