@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// Verifies the two ways a bend chain reaches past a plain chord-to-chord
/// link: through a **grace note**, and through a **tie**.
///
/// Both are one mechanism in MuseScore. `collectGuitarBend`
/// (`engraving/compat/midi/compatmidirenderinternal.cpp`) walks
/// `while (note->bendFor() || note->tieFor())`, so a tie continues the chain
/// with the wheel held where it is, and it never asks whether the note it
/// landed on is a grace — a `GRACE_NOTE_BEND` merely moves the wheel segment's
/// start back to the grace's onset (`curPitchBendSegmentStart -= graceOffset`).
/// The two suppression rules — a bend's `bendBack` and a tie's `tieBack`, which
/// each cancel a note's attack — therefore have to be decided in one pass or
/// each re-decides the other's release.
@Suite("MIDI guitar bends: graces and ties")
struct MidiRendererGuitarBendGraceTests {
    private typealias Probe = GuitarBendMidiProbe

    // MARK: - MuseScore's own fixtures

    @Test("guitarbend_tied: ties interleaved with bends stay one sounding key")
    func tiedFixture_soundsOneKeyThroughTheTies() throws {
        // Five written chords — E3 bends up to G♯3, holds across a tie,
        // releases back to E3, and is tied into a closing half note. The whole
        // measure is a single struck key whose wheel does all the moving.
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("guitarbend_tied"))
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        let ons = Probe.noteOns(in: track)
        #expect(ons.map(\.pitch) == [52])
        #expect(ons.map(\.tick) == [0])
        let offs = Probe.noteOffs(in: track)
        #expect(offs.map(\.pitch) == [52])
        // The closing tied half note ends the measure; nothing is lost.
        #expect(offs.map(\.tick) == [1919])

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 4) // 52 → 56
        #expect(wheelEvents.map(\.value).max() == peak)
        // The bend completes inside the first eighth …
        #expect(wheelEvents.last { $0.tick < 240 }?.value == peak)
        // … and the TIED eighth holds it: no reset, no re-attack mid-chain.
        let acrossTie = wheelEvents.filter { $0.tick >= 240 && $0.tick < 480 }
        #expect(!acrossTie.isEmpty)
        #expect(acrossTie.allSatisfy { $0.value == peak })
        // The release finishes inside the third eighth …
        #expect(wheelEvents.last { $0.tick < 720 }?.value == MidiEvent.pitchBendCenter)
        // … and the final tie holds center right up to the release.
        #expect(wheelEvents.last?.tick == 1919)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
    }

    @Test("guitarbend_gracebend: the grace key sounds through its parent")
    func graceBendFixture_soundsTheGraceKeyThroughTheParent() throws {
        // Three `GRACE_NOTE_BEND`s, each on an appoggiatura before its parent.
        // The parent's attack is suppressed because it carries `bendBack`
        // (`collectNote`: `if (bendBack && … i == 0) continue;`).
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("guitarbend_gracebend"))
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        // Only the lone unbent chord at the top of measure 2 keeps its 54.
        #expect(Probe.noteOns(in: track).map(\.pitch) == [52, 52, 54, 52])
        #expect(Probe.noteOns(in: track).map(\.tick) == [480, 1440, 1920, 2400])
        // Each chain releases at its PARENT's end, on the GRACE's key.
        let offs = Probe.noteOffs(in: track)
        #expect(offs.map(\.pitch) == [52, 52, 54, 52])
        #expect(offs.map(\.tick) == [959, 1919, 2399, 2879])

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 2) // 52 → 54
        #expect(wheelEvents.map(\.value).max() == peak)
        // The ramp lives inside the grace's own 240 ticks; the parent holds.
        #expect(wheelEvents.last { $0.tick < 720 }?.value == peak)
        #expect(wheelEvents.last { $0.tick < 960 }?.value == MidiEvent.pitchBendCenter)
    }

    @Test("guitarbend_release_twice: an after-grace chain sounds one key")
    func releaseTwiceFixture_soundsOneKeyAcrossGraceAfterChain() throws {
        // main → after-grace → main → after-grace → after-grace, alternating
        // `BEND` and `GRACE_NOTE_BEND`, with the second pair on non-default
        // time factors. Two full releases back to the written pitch, and one
        // struck key for the lot.
        let score = try MSCXParser.parse(
            MSCXFixtureLoader.mscxData("guitarbend_release_twice"),
        )
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        let ons = Probe.noteOns(in: track)
        #expect(ons.map(\.pitch) == [60])
        #expect(ons.map(\.tick) == [0])
        let offs = Probe.noteOffs(in: track)
        #expect(offs.map(\.pitch) == [60])
        // The last after-grace runs 960..1199; the chain releases there.
        #expect(offs.map(\.tick) == [1199])

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 2) // 60 → 62
        #expect(wheelEvents.map(\.value).max() == peak)
        #expect(wheelEvents.allSatisfy { $0.value >= MidiEvent.pitchBendCenter })
        // Release #1 completes by the second main chord …
        #expect(wheelEvents.last { $0.tick < 480 }?.value == MidiEvent.pitchBendCenter)
        // … which bends up again inside its 0.25–0.75 window …
        #expect(wheelEvents.last { $0.tick < 720 }?.value == peak)
        // … and release #2 completes inside the 0–0.5 window of its grace.
        #expect(wheelEvents.last { $0.tick < 960 }?.value == MidiEvent.pitchBendCenter)
        #expect(wheelEvents.last?.tick == 1199)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
    }

    // MARK: - Hand-built cases

    @Test("a grace-note bend attacks on the grace key and holds the parent")
    func graceNoteBend_soundsOnTheGraceKey() throws {
        // The grace strikes its own pitch and ramps into the parent's across
        // the grace's duration; the parent never re-attacks and the key is
        // released at the parent's end.
        let grace = GraceChord(
            graceType: .appoggiatura,
            duration: .eighth,
            notes: [Note(
                pitch: 60, tpc: 14, guitarBend: GuitarBend(type: .graceNoteBend),
            )],
        )
        let parent = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
            graceNotesBefore: [grace],
        )
        let file = try MidiRenderer.render(score: Probe.makeScore(chords: [parent]))
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60])
        #expect(Probe.noteOns(in: track).map(\.tick) == [0])
        let offs = Probe.noteOffs(in: track)
        #expect(offs.map(\.pitch) == [60])
        // An appoggiatura takes half the parent: grace 0..239, parent 240..479.
        #expect(offs.map(\.tick) == [479])

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 2)
        #expect(wheelEvents.map(\.value).max() == peak)
        // Reached by the parent's onset, then held to the release.
        #expect(wheelEvents.last { $0.tick < 240 }?.value == peak)
        #expect(wheelEvents.first { $0.tick == 240 }?.value == peak)
        #expect(wheelEvents.last?.tick == 479)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
    }

    @Test("a tie inside a bend chain neither re-attacks nor resets the wheel")
    func tieInsideChain_holdsTheWheel() throws {
        // C4 bends to D4, and the D4 is tied onward. The tied chord is a chain
        // interior: no note-on, no wheel reset, and the chain's release moves
        // to the tie's end.
        let start = Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])
        let bent = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, tieForward: 0, guitarBendBack: true)],
        )
        let tied = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, tieBack: 0)],
        )
        let file = try MidiRenderer.render(
            score: Probe.makeScore(chords: [start, bent, tied]),
        )
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60])
        let offs = Probe.noteOffs(in: track)
        #expect(offs.map(\.pitch) == [60])
        #expect(offs.map(\.tick) == [1439]) // 960 + 480 − 1: the tie's end

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 2)
        // Everything from the bend's completion to the release holds the peak.
        let held = wheelEvents.filter { $0.tick >= 480 && $0.tick < 1439 }
        #expect(!held.isEmpty)
        #expect(held.allSatisfy { $0.value == peak })
        #expect(wheelEvents.last?.tick == 1439)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
    }

    @Test("a chain tied INTO is struck where the tie starts, not at the bend")
    func chainTiedInto_strikesAtTheTiesHead() throws {
        // A held C4 tied into the note that bends. The tie's head already
        // suppressed its own release, so striking the key again at the bend
        // would double-attack a string that never stopped ringing.
        let held = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, tieForward: 0)],
        )
        let bendStart = Chord(
            duration: .quarter,
            notes: [Note(
                pitch: 60, tpc: 14, tieBack: 0, guitarBend: GuitarBend(type: .bend),
            )],
        )
        let bendEnd = Chord(
            duration: .quarter,
            notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
        )
        let file = try MidiRenderer.render(
            score: Probe.makeScore(chords: [held, bendStart, bendEnd]),
        )
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60])
        #expect(Probe.noteOns(in: track).map(\.tick) == [0])
        let offs = Probe.noteOffs(in: track)
        #expect(offs.map(\.pitch) == [60])
        #expect(offs.map(\.tick) == [1439])

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 2)
        // The held quarter stays unbent; the bend lives in the second.
        #expect(wheelEvents.last { $0.tick < 480 }?.value == MidiEvent.pitchBendCenter)
        #expect(wheelEvents.last { $0.tick < 960 }?.value == peak)
        #expect(wheelEvents.last?.tick == 1439)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
    }

    @Test("a slight bend tied onward holds its quarter tone across the tie")
    func slightBendTiedForward_holdsAcrossTheTie() throws {
        // Both spanner sides sit on the same note, which is then tied. The
        // scoop must not release at its own end — the tie is still sounding.
        let scoop = Chord(
            duration: .quarter,
            notes: [Note(
                pitch: 60, tpc: 14, tieForward: 0,
                guitarBend: GuitarBend(type: .slightBend), guitarBendBack: true,
            )],
        )
        let tied = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14, tieBack: 0)],
        )
        let file = try MidiRenderer.render(
            score: Probe.makeScore(chords: [scoop, tied]),
        )
        let track = try #require(file.tracks.first)

        #expect(Probe.noteOns(in: track).map(\.pitch) == [60])
        let offs = Probe.noteOffs(in: track)
        #expect(offs.map(\.pitch) == [60])
        #expect(offs.map(\.tick) == [959])

        let wheelEvents = Probe.bends(in: track)
        let peak = Probe.wheel(semitones: 0.5)
        #expect(wheelEvents.map(\.value).max() == peak)
        let acrossTie = wheelEvents.filter { $0.tick >= 480 && $0.tick < 959 }
        #expect(!acrossTie.isEmpty)
        #expect(acrossTie.allSatisfy { $0.value == peak })
        #expect(wheelEvents.last?.tick == 959)
        #expect(wheelEvents.last?.value == MidiEvent.pitchBendCenter)
    }

    // MARK: - Chain-map shape

    /// A grace note is an ordinary chain member, so one element can own several
    /// slots. `guitarbend_release_twice`'s second chord holds three: its
    /// principal plus both of its after-graces.
    @Test("the chain map keys grace members by their grace index")
    func chainMap_keysGraceMembersSeparately() throws {
        let score = try MSCXParser.parse(
            MSCXFixtureLoader.mscxData("guitarbend_release_twice"),
        )
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        let slots = MidiRenderer.guitarBendChains(voiceElements: elements)
        #expect(slots.count == 2)

        let first = try #require(slots[3])
        #expect(first.parent?.isChainStart == true)
        #expect(first.parent?.basePitch == 60)
        #expect(first.parent?.targetOffsetQuarterTones == 4) // 60 → 62
        #expect(first.before.isEmpty)
        // The after-grace releases back to the next chord's written 60.
        #expect(first.after[0]?.startOffsetQuarterTones == 4)
        #expect(first.after[0]?.targetOffsetQuarterTones == 0)
        #expect(first.after[0]?.isChainStart == false)

        let second = try #require(slots[4])
        #expect(second.parent?.isChainEnd == false)
        #expect(second.parent?.startTimeFactor == 0.25)
        #expect(second.parent?.endTimeFactor == 0.75)
        #expect(second.after[0]?.endTimeFactor == 0.5)
        #expect(second.after[0]?.targetOffsetQuarterTones == 0)
        // Only the LAST after-grace releases the key.
        #expect(second.after[1]?.isChainEnd == true)
        #expect(second.after[1]?.targetOffsetQuarterTones == nil)
        #expect(second.after[1]?.basePitch == 60)
    }

    /// A chain member tied onward must hand the key to its tie partner. When
    /// it cannot the whole chain is dropped rather than half-applied — the tie
    /// would otherwise suppress a note-on whose note-off the chain had already
    /// emitted somewhere else, and `resolveUnisonOverlap` would hide the loss.
    @Test("a chain whose tie leads nowhere is dropped whole")
    func chainMap_dropsChainWithDanglingTie() {
        let elements: [VoiceElement] = [
            .chord(Chord(duration: .quarter, notes: [Probe.bendNote(pitch: 60)])),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 62, tpc: 16, tieForward: 0, guitarBendBack: true)],
            )),
            // Same chord shape as the tie's partner, but nothing ties back.
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
        ]
        #expect(MidiRenderer.guitarBendChains(voiceElements: elements).isEmpty)
    }

    /// The tie into a chain head can lead out of reach — its partner sits in
    /// the previous measure, and the walk sees one measure's voice elements at
    /// a time. The chain is then dropped whole; striking it anyway would add a
    /// second attack on a key the previous measure is still holding.
    @Test("a chain tied in from out of reach is dropped whole")
    func chainMap_dropsChainTiedInFromAnotherMeasure() {
        let elements: [VoiceElement] = [
            .chord(Chord(
                duration: .quarter,
                notes: [Note(
                    pitch: 60, tpc: 14, tieBack: 0,
                    guitarBend: GuitarBend(type: .bend),
                )],
            )),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
            )),
        ]
        #expect(MidiRenderer.guitarBendChains(voiceElements: elements).isEmpty)
    }

    /// A note-less chord hosts no chain position at all, its graces included.
    /// The renderer's grace path hangs off the parent chord's notes, so a slot
    /// on a grace whose parent strikes nothing would never be reached, and an
    /// unreached slot emits a note-off with no note-on. The parser cannot build
    /// such a chord today; the guard is structural.
    @Test("a note-less chord hosts no chain position, graces included")
    func chainMap_skipsGracesOfANoteLessChord() {
        let grace = GraceChord(
            graceType: .appoggiatura,
            duration: .eighth,
            notes: [Note(
                pitch: 60, tpc: 14, guitarBend: GuitarBend(type: .graceNoteBend),
            )],
        )
        let elements: [VoiceElement] = [
            .chord(Chord(duration: .quarter, notes: [], graceNotesBefore: [grace])),
            .chord(Chord(
                duration: .quarter,
                notes: [Note(pitch: 62, tpc: 16, guitarBendBack: true)],
            )),
        ]
        #expect(MidiRenderer.guitarBendChains(voiceElements: elements).isEmpty)
    }
}
