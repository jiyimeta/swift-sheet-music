@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// Verifies guitar-bend playback: a bend chain sounds as ONE sustained MIDI
/// key whose pitch wheel is driven from the chain's first note to each
/// notated destination, instead of a fresh attack per notated pitch.
///
/// C++: `CompatMidiRender::collectBend` / the `GuitarBend` chain walk in
/// `engraving/compat/midi/compatmidirenderinternal.cpp` — the begin note
/// carries the payload, every `<prev>`-side note continues the same
/// sounding key.
@Suite("MIDI guitar bends")
struct MidiRendererGuitarBendTests {
    // MARK: - Fixtures

    private typealias Probe = GuitarBendMidiProbe

    private static func assertBalancedNoteEvents(track: MidiTrack) {
        let ons = Probe.noteOns(in: track).map(\.pitch).sorted()
        let offs = Probe.noteOffs(in: track).map(\.pitch).sorted()
        #expect(ons == offs, "unmatched note-on/off: ons=\(ons) offs=\(offs)")
    }

    // MARK: - 1. Two-chord bend

    @Test("bend chain sounds one key and bends the wheel to the target")
    func twoChordBend_playsAsOneNoteWithRamp() throws {
        // C4 → D4 over two quarter notes. The written D4 never re-attacks:
        // the C4 key sustains and the wheel climbs +2 semitones.
        let start = Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])
        let end = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
        )
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [start, end]))
        let track = try #require(file.tracks.first)

        let ons = Probe.noteOns(in: track)
        #expect(ons.map(\.pitch) == [60], "the bend chain must strike exactly one key")
        #expect(ons.first?.tick == 0)

        let offs = Probe.noteOffs(in: track)
        #expect(offs.count == 1)
        #expect(offs.first?.pitch == 60)
        // 480 (second chord onset) + 480 (its duration) − 1.
        #expect(offs.first?.tick == 959)

        let wheelEvents = Probe.bends(in: track)
        #expect(wheelEvents.first?.value == MidiEvent.pitchBendCenter)
        let peak = Probe.wheel(semitones: 2)
        #expect(peak == MidiEvent.pitchBendCenter + 1365)
        #expect(wheelEvents.map(\.value).max() == peak)
        // The ramp lives inside the FIRST chord; by its end the wheel holds.
        let atFirstChordEnd = wheelEvents.last { $0.tick < 480 }?.value
        #expect(atFirstChordEnd == peak)
        // Reset lands with the chain's note-off so the next chord is unbent.
        #expect(wheelEvents.last?.tick == 959)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
        Self.assertBalancedNoteEvents(track: track)
    }

    // MARK: - 2. Bend / release chain

    @Test("a bend-release chain keeps one key and returns the wheel to center")
    func bendReleaseChain_returnsToCenterMidChain() throws {
        // C4 → D4 → C4: bend up, then release back down. Three chords, two
        // bends, still ONE sounding key.
        let start = Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])
        let middle = Chord(
            duration: .quarter,
            notes: [Note(
                pitch: 62, tpc: 16,
                guitarBend: GuitarBend(type: .bend), guitarBendBack: true,
            )],
        )
        let end = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, guitarBendBack: true)],
        )
        let file = try MidiRenderer.render(
            score: Probe.makeScore(chords: [start, middle, end]),
        )
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60])
        let offs = Probe.noteOffs(in: track)
        #expect(offs.count == 1)
        #expect(offs.first?.tick == 1439) // 960 + 480 − 1

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 2)
        #expect(wheelEvents.map(\.value).max() == peak)
        // The middle chord ramps back down: its last sample is center again.
        let middleSamples = wheelEvents.filter { $0.tick >= 480 && $0.tick < 960 }
        #expect(middleSamples.first?.value == peak)
        #expect(middleSamples.last?.value == MidiEvent.pitchBendCenter)
        // The final chord holds center, then the chain releases.
        #expect(wheelEvents.last?.tick == 1439)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
        Self.assertBalancedNoteEvents(track: track)
    }

    // MARK: - 3. Slight bend

    @Test("a slight bend ramps a quarter tone and holds on one chord")
    func slightBend_rampsQuarterToneOnSameNote() throws {
        // MuseScore's slight bend begins and ends on the SAME note, so the
        // note carries both spanner sides. It ramps to +1 quarter tone and
        // holds — no comeback.
        let note = Note(
            pitch: 60, tpc: 14,
            guitarBend: GuitarBend(type: .slightBend), guitarBendBack: true,
        )
        let chord = Chord(duration: .quarter, notes: [note])
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [chord]))
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60])
        let offs = Probe.noteOffs(in: track)
        #expect(offs.count == 1)
        #expect(offs.first?.tick == 479)

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 0.5)
        #expect(peak == MidiEvent.pitchBendCenter + 341)
        #expect(wheelEvents.map(\.value).max() == peak)
        // Held at the peak right up to the release, then reset.
        #expect(wheelEvents.last?.tick == 479)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
        Self.assertBalancedNoteEvents(track: track)
    }

    // MARK: - 4. Unbent chord after a chain

    @Test("a plain chord after a bend chain plays unbent")
    func chordAfterChain_playsAtNaturalPitch() throws {
        let start = Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])
        let end = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
        )
        let plain = Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)])
        let file = try MidiRenderer.render(
            score: Probe.makeScore(chords: [start, end, plain]),
        )
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60, 65])
        // Every wheel event at or after the plain chord's onset is center.
        let after = Probe.bends(in: track).filter { $0.tick >= 960 }
        #expect(after.allSatisfy { $0.value == MidiEvent.pitchBendCenter })
        // …and the last wheel event before it is the chain's reset.
        #expect(Probe.bends(in: track).last { $0.tick < 960 }?.value
            == MidiEvent.pitchBendCenter)
        Self.assertBalancedNoteEvents(track: track)
    }

    // MARK: - 5. An orphaned `<prev>` side plays normally

    @Test("a bend-back note with no live chain attacks normally")
    func orphanBendBack_playsWithNormalAttack() throws {
        // A `<prev>`-only spanner can survive decoding when its begin side was
        // dropped (unknown `<guitarBendType>`, missing `<GuitarBend>` payload).
        // Suppression keys off the computed chain, never the raw flag: with no
        // chain the note must attack like any other, or it would be silent.
        let first = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        let second = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
        )
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [first, second]))
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60, 62])
        #expect(Probe.noteOffs(in: track).map(\.pitch).sorted() == [60, 62])
        #expect(Probe.bends(in: track).isEmpty, "no chain means no wheel traffic")
    }

    // MARK: - 6. Pre-bend plays straight (v1 limitation)

    @Test("a pre-bend is not curved in v1")
    func preBend_playsStraight() throws {
        // MuseScore derives a pre-bend's distance from the tab fret data this
        // model does not carry, so v1 leaves the wheel alone — see the comment
        // on `guitarBendChains`.
        let grace = Chord(duration: .eighth, notes: [Probe.bendNote(pitch: 50, type: .preBend)])
        let main = Chord(
            duration: .eighth,
            notes: [Note(pitch: 52, tpc: 18, guitarBendBack: true)],
        )
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [grace, main]))
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [50, 52])
        #expect(Probe.bends(in: track).isEmpty)
    }

    // MARK: - 7. Chain map shape

    @Test("the chain map records one slot per chain member")
    func chainMap_describesEachChainMember() {
        let elements: [VoiceElement] = [
            .chord(Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
            )),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)])),
        ]
        let slots = MidiRenderer.guitarBendChains(voiceElements: elements)
        #expect(slots.count == 2)
        #expect(slots[0]?.parent == MidiRenderer.BendChainSlot(
            basePitch: 60,
            startOffsetQuarterTones: 0,
            targetOffsetQuarterTones: 4,
            isChainStart: true,
            isChainEnd: false,
            startTimeFactor: 0,
            endTimeFactor: 1,
        ))
        #expect(slots[1]?.parent == MidiRenderer.BendChainSlot(
            basePitch: 60,
            startOffsetQuarterTones: 4,
            targetOffsetQuarterTones: nil,
            isChainStart: false,
            isChainEnd: true,
            startTimeFactor: 0,
            endTimeFactor: 1,
        ))
        #expect(slots[2] == nil)
        // Nothing hangs off a grace note here.
        #expect(slots.values.allSatisfy { $0.before.isEmpty && $0.after.isEmpty })
    }

    /// A `.between` tremolo swallows the FOLLOWING chord — which carries no
    /// tremolo of its own, so the "does this chord carry a tremolo" check
    /// cannot see it. The voice walker `continue`s past that index before
    /// `renderVoiceElement` runs, so a chain starting there would never emit
    /// its note-on while the chain end still emitted a note-off, and
    /// `resolveUnisonOverlap` would discard the orphan — silencing both notes
    /// instead of merely leaving them unbent.
    @Test("a chain starting on a tremolo-consumed chord is refused")
    func chainMap_dropsChainConsumedByBetweenTremolo() throws {
        let tremolo = Chord(
            duration: .quarter,
            notes: [Note(pitch: 67, tpc: 15)],
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        // Consumed by the tremolo above AND the would-be chain start.
        let bendStart = Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])
        let bendEnd = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
        )
        let elements: [VoiceElement] = [.chord(tremolo), .chord(bendStart), .chord(bendEnd)]
        #expect(MidiRenderer.guitarBendChains(voiceElements: elements).isEmpty)

        let file = try MidiRenderer.render(
            score: Probe.makeScore(chords: [tremolo, bendStart, bendEnd]),
        )
        let track = try #require(file.tracks.first)
        // The bend end falls back to a plain attack; without the guard it
        // emitted only an orphan note-off and never sounded at all.
        #expect(Probe.noteOns(in: track).filter { $0.pitch == 62 }.count == 1)
        #expect(Probe.noteOffs(in: track).filter { $0.pitch == 62 }.count == 1)
        #expect(Probe.bends(in: track).isEmpty, "a refused chain drives no wheel")
        Self.assertBalancedNoteEvents(track: track)
    }

    /// A chain whose destination is not reachable — the closing `<prev>` side
    /// is missing — is dropped whole, so every member keeps a plain attack and
    /// the note-on/off stream stays balanced.
    @Test("an unclosed chain yields no slots at all")
    func chainMap_dropsUnclosedChain() {
        let elements: [VoiceElement] = [
            .chord(Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ]
        #expect(MidiRenderer.guitarBendChains(voiceElements: elements).isEmpty)
    }

    // MARK: - 8. MuseScore's own fixtures

    /// Number of chords that actually sound (rests are note-less chords).
    private static func soundingChordCount(in score: Score) -> Int {
        score.allStaves.reduce(0) { total, entry in
            total + entry.staff.measures.reduce(0) { measureTotal, measure in
                measureTotal + measure.voices.reduce(0) { voiceTotal, voice in
                    voiceTotal + voice.elements.count { element in
                        guard case let .chord(chord) = element else { return false }
                        return !chord.notes.isEmpty
                    }
                }
            }
        }
    }

    @Test("guitarbend_simple: each of the three bends swallows one attack")
    func simpleFixture_playsThreeChainsAsThreeKeys() throws {
        // MuseScore's own playback fixture: three plain bends, each ending on
        // the following note (`GuitarBendDecodeTests.simpleBends`).
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("guitarbend_simple"))
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).count == Self.soundingChordCount(in: score) - 3)
        #expect(!Probe.bends(in: track).isEmpty)
        Self.assertBalancedNoteEvents(track: track)
    }

    @Test("guitarbend_slightbend: same-note chains keep every attack")
    func slightBendFixture_keepsAttacksAndBendsTheWheel() throws {
        // Three slight bends, each with both spanner sides on the SAME note,
        // so no attack is swallowed — only the wheel moves.
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("guitarbend_slightbend"))
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).count == Self.soundingChordCount(in: score))
        let peak = Probe.wheel(semitones: 0.5)
        #expect(Probe.bends(in: track).map(\.value).max() == peak)
        Self.assertBalancedNoteEvents(track: track)
    }

    // MARK: - 9. Portamento regression guard

    @Test("portamento glissando rendering is unchanged")
    func portamento_streamIsUnchanged() throws {
        // Cross-check of `MidiRendererGlissandoTests.portamento_emitsPitchBendRamp`:
        // the bend chain shares the pitch-wheel machinery, so any drift in the
        // glissando path has to fail here too.
        let start = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, glissando: Glissando(style: .portamento))],
        )
        let end = Chord(duration: .quarter, notes: [Note(pitch: 67, tpc: 15)])
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [start, end]))
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60, 67])
        let wheelEvents = Probe.bends(in: track)
        #expect(wheelEvents.count >= 5)
        #expect(wheelEvents.first?.value == MidiEvent.pitchBendCenter)
        let approxPeak = wheelEvents.dropLast().last?.value ?? 0
        #expect(approxPeak > MidiEvent.pitchBendCenter + 3000)
        #expect(approxPeak <= MidiEvent.pitchBendCenter + 8191)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
        #expect(Probe.noteOffs(in: track).filter { $0.pitch == 67 }.count == 1)
        Self.assertBalancedNoteEvents(track: track)
    }
}
