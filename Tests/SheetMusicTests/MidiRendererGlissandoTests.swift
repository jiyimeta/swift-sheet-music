import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Verifies Glissando rendering to MIDI. Every `Glissando.Style` is covered:
///   - chromatic, whiteKeys, blackKeys, diatonic (discrete note sweeps);
///   - portamento (continuous pitch-bend ramp).
/// The renderer devotes ~33% of the start chord to the sweep and the leading
/// 67% to the held start pitch, matching MuseScore's `compatmidirender.cpp`.
@Suite struct MidiRendererGlissandoTests {
    // MARK: - Fixtures

    private static func makeScore(
        division: Int = 480,
        keySignature: Int = 0,
        chords: [Chord]
    ) -> Score {
        let instrument = Instrument(
            id: "test",
            articulations: [InstrumentArticulation()]
        )
        let part = Part(id: "P1", instrument: instrument)
        var elements: [VoiceElement] = []
        if keySignature != 0 {
            elements.append(.keySignature(KeySignature(concertKey: keySignature)))
        }
        elements.append(contentsOf: chords.map { .chord($0) })
        let voice = Voice(elements: elements)
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        return Score(division: division, parts: [part], staves: [staff])
    }

    private static func noteOns(in track: MidiTrack) -> [(tick: Int, pitch: Int)] {
        track.events.compactMap { ev in
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 { return (ev.tick, pitch) }
            return nil
        }
    }

    private static func noteOffs(in track: MidiTrack) -> [(tick: Int, pitch: Int)] {
        track.events.compactMap { ev in
            if case let .noteOff(_, pitch, _) = ev.event { return (ev.tick, pitch) }
            if case let .noteOn(_, pitch, vel) = ev.event, vel == 0 { return (ev.tick, pitch) }
            return nil
        }
    }

    /// Every pitch that was struck (note-on with vel > 0) must also be released
    /// (note-off or note-on vel 0) exactly once. Matched by pitch because the
    /// unison resolver is FIFO by (channel, pitch).
    private static func assertBalancedNoteEvents(
        track: MidiTrack, file: StaticString = #filePath, line: UInt = #line
    ) {
        let ons = noteOns(in: track).map(\.pitch).sorted()
        let offs = noteOffs(in: track).map(\.pitch).sorted()
        #expect(ons == offs, "unmatched note-on/off: ons=\(ons) offs=\(offs)")
    }

    // MARK: - Discrete rendering

    @Test func chromaticGlissando_emitsAllIntermediatePitches() throws {
        // 60 → 64 over a quarter note (480 ticks). Held portion ≈ 67%,
        // sweep ≈ 33% hosting pitches [60, 61, 62, 63]. End 64 plays next.
        let start = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .chromatic))]
        )
        let end = Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])
        let file = try MidiRenderer.render(score: Self.makeScore(chords: [start, end]))
        let track = try #require(file.tracks.first)

        let ons = Self.noteOns(in: track)
        let pitches = ons.map(\.pitch)
        #expect(pitches == [60, 61, 62, 63, 64])
        // Held portion occupies 67% of 480 = ~321 ticks; first intermediate
        // (pitch 61) kicks in right after.
        #expect(ons[0].tick == 0)
        #expect(ons[1].tick >= 300 && ons[1].tick <= 340)
        #expect(ons[4].tick == 480) // end chord plays on time
        Self.assertBalancedNoteEvents(track: track)
    }

    /// The glissando's target note (the end pitch of the sweep, played as the
    /// next chord) must receive a proper note-off — its note-on at the chord
    /// boundary and the note-off at the end of its own duration. Regression
    /// guard after feedback that the target note sounded open-ended.
    @Test func chromaticGlissando_targetNoteHasNoteOff() throws {
        let start = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .chromatic))]
        )
        let end = Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])
        let file = try MidiRenderer.render(score: Self.makeScore(chords: [start, end]))
        let track = try #require(file.tracks.first)

        let targetOffs = Self.noteOffs(in: track).filter { $0.pitch == 64 }
        #expect(targetOffs.count == 1, "target pitch 64 must have exactly one note-off")
        #expect(targetOffs.first?.tick == 959) // 480 (start) + 480 (duration) − 1
    }

    @Test func whiteKeysGlissando_skipsBlackKeys() throws {
        // 60 → 72 over a quarter note. White keys sweep: [60, 62, 64, 65, 67, 69, 71].
        let start = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .whiteKeys))]
        )
        let end = Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)])
        let file = try MidiRenderer.render(score: Self.makeScore(chords: [start, end]))
        let track = try #require(file.tracks.first)

        let pitches = Self.noteOns(in: track).map(\.pitch)
        #expect(pitches == [60, 62, 64, 65, 67, 69, 71, 72])
        Self.assertBalancedNoteEvents(track: track)
    }

    @Test func blackKeysGlissando_skipsWhiteKeys() throws {
        let start = Chord(
            duration: .quarter,
            notes: [Note(pitch: 61, tpc: 11, glissando: Glissando(style: .blackKeys))]
        )
        let end = Chord(duration: .quarter, notes: [Note(pitch: 73, tpc: 11)])
        let file = try MidiRenderer.render(score: Self.makeScore(chords: [start, end]))
        let track = try #require(file.tracks.first)

        let pitches = Self.noteOns(in: track).map(\.pitch)
        #expect(pitches == [61, 63, 66, 68, 70, 73])
        Self.assertBalancedNoteEvents(track: track)
    }

    @Test func diatonicGlissando_respectsKeySignature() throws {
        // G major: sweep from G4 to G5 uses G A B C D E F# (not F natural).
        let start = Chord(
            duration: .quarter,
            notes: [Note(pitch: 67, tpc: 15, glissando: Glissando(style: .diatonic))]
        )
        let end = Chord(duration: .quarter, notes: [Note(pitch: 79, tpc: 15)])
        let file = try MidiRenderer.render(
            score: Self.makeScore(keySignature: 1, chords: [start, end])
        )
        let track = try #require(file.tracks.first)

        let pitches = Self.noteOns(in: track).map(\.pitch)
        #expect(pitches == [67, 69, 71, 72, 74, 76, 78, 79])
        Self.assertBalancedNoteEvents(track: track)
    }

    @Test func glissandoWithNoFollowingChord_playsStartNoteNormally() throws {
        // No end chord means no end pitch → renderer falls back to normal note.
        let lone = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .chromatic))]
        )
        let file = try MidiRenderer.render(score: Self.makeScore(chords: [lone]))
        let track = try #require(file.tracks.first)

        let ons = Self.noteOns(in: track)
        #expect(ons.count == 1)
        #expect(ons[0].pitch == 60)
        Self.assertBalancedNoteEvents(track: track)
    }

    @Test func easeCurve_nonZero_shiftsSweepTiming() throws {
        // With easeIn=0/easeOut=0 the sweep is evenly spaced. A strong easeIn
        // bunches the early part of the sweep so later pitches fire SOONER
        // after the sweep starts (they're compressed toward the beginning).
        // We assert that the last intermediate pitch's on-tick arrives earlier
        // when ease-in is applied.
        let division = 1920 // bigger division amplifies sub-tick differences
        func sweepOnTicks(easeIn: Int) throws -> [Int] {
            let start = Chord(
                duration: .quarter,
                notes: [Note(
                    pitch: 60, tpc: 14,
                    glissando: Glissando(style: .chromatic, easeIn: easeIn, easeOut: 0)
                ), ]
            )
            let end = Chord(duration: .quarter, notes: [Note(pitch: 66, tpc: 14)])
            let file = try MidiRenderer.render(
                score: Self.makeScore(division: division, chords: [start, end])
            )
            return try Self.noteOns(in: #require(file.tracks.first))
                .filter { $0.pitch < 66 } // drop the final chord
                .map(\.tick)
        }
        let linear = try sweepOnTicks(easeIn: 0)
        let eased = try sweepOnTicks(easeIn: 100)
        #expect(linear.count == 6)
        #expect(eased.count == 6)
        // Both share tick[0]=0 (held-pitch start) and tick[1]=heldDuration.
        #expect(linear[0] == 0 && eased[0] == 0)
        #expect(linear[1] == eased[1])
        // With max easeIn, indices 2…5 are pulled earlier than linear — their
        // event separations are compressed toward the sweep's start.
        for i in 2 ..< linear.count {
            #expect(eased[i] < linear[i], "index \(i): eased=\(eased[i]) linear=\(linear[i])")
        }
    }

    // MARK: - Portamento

    @Test func portamento_emitsPitchBendRamp() throws {
        // 60 → 67 portamento over a quarter note. Expect:
        //   - note-on for pitch 60 at tick 0
        //   - pitch-bend events in between (>= 4 samples)
        //   - pitch-bend returns to 8192 after the note
        //   - next chord plays pitch 67 with no bend
        let start = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .portamento))]
        )
        let end = Chord(duration: .quarter, notes: [Note(pitch: 67, tpc: 15)])
        let file = try MidiRenderer.render(score: Self.makeScore(chords: [start, end]))
        let track = try #require(file.tracks.first)

        let ons = Self.noteOns(in: track)
        // Only the start pitch (60) and the end chord's pitch (67).
        #expect(ons.map(\.pitch) == [60, 67])

        let bends: [(tick: Int, value: Int)] = track.events.compactMap {
            if case let .pitchBend(_, value) = $0.event { return ($0.tick, value) }
            return nil
        }
        #expect(bends.count >= 5)
        // First bend is the centre reset at tick 0.
        #expect(bends[0].value == MidiEvent.pitchBendCenter)
        // Ramp ends at +7 semitones ≈ 8192 + (7/12)*8191 ≈ 8192 + 4778 = 12970.
        let approxPeak = bends.dropLast().last?.value ?? 0
        #expect(approxPeak > MidiEvent.pitchBendCenter + 3000)
        #expect(approxPeak <= MidiEvent.pitchBendCenter + 8191)
        // Final bend resets to centre so the next chord plays unbent.
        #expect(bends.last?.value == MidiEvent.pitchBendCenter)
        // And the target (end) pitch 67 receives a note-off like any chord.
        let targetOffs = Self.noteOffs(in: track).filter { $0.pitch == 67 }
        #expect(targetOffs.count == 1, "portamento target must get a note-off")
        Self.assertBalancedNoteEvents(track: track)
    }

    // MARK: - mscx parse

    @Test func parsesMuseScoreGlissandoXML() throws {
        // Shape matches MuseScore 4's writer (`TWrite::write(const Glissando*)`
        // at `twrite.cpp:1519`): <Spanner type="Glissando"> with nested
        // <Glissando> block carrying glissandoStyle, easeInSpin, easeOutSpin.
        let xml = """
        <voice>
          <Chord>
            <durationType>quarter</durationType>
            <Note>
              <Spanner type="Glissando">
                <Glissando>
                  <text>gliss.</text>
                  <easeInSpin>25</easeInSpin>
                  <easeOutSpin>75</easeOutSpin>
                  <glissandoStyle>WHITE_KEYS</glissandoStyle>
                  <subtype>1</subtype>
                </Glissando>
                <next><location><fractions>1/4</fractions></location></next>
              </Spanner>
              <pitch>60</pitch>
              <tpc>14</tpc>
            </Note>
          </Chord>
          <Chord>
            <durationType>quarter</durationType>
            <Note>
              <Spanner type="Glissando">
                <prev><location><fractions>-1/4</fractions></location></prev>
              </Spanner>
              <pitch>72</pitch>
              <tpc>14</tpc>
            </Note>
          </Chord>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        guard case let .chord(first) = voice.elements[0] else {
            Issue.record("expected chord"); return
        }
        let glissando = try #require(first.notes.first?.glissando)
        #expect(glissando.style == .whiteKeys)
        #expect(glissando.easeIn == 25)
        #expect(glissando.easeOut == 75)
        #expect(glissando.text == "gliss.")
        #expect(glissando.visualType == .wavy)
        // The end note only carries <prev>, so no glissando block decoded there.
        guard case let .chord(second) = voice.elements[1] else {
            Issue.record("expected chord"); return
        }
        #expect(second.notes.first?.glissando == nil)
    }
}
