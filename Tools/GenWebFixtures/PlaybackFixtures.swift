// The playback half of the browser fixtures: a score with a repeat, and what
// the Apple build computes for it.
//
// A repeat is the point. `PlaybackClock` projects between the score's own clock
// and the UNROLLED one the synth plays, and on a score without repeats those are
// the same clock — every conversion is the identity and an implementation that
// dropped the projection entirely would still match. `sampleScore` (one measure,
// four quarter notes) cannot tell the difference; this one can.
//
// Built in code rather than copied from Tests/SheetMusicTests/Resources: those
// are GPL-3.0 copies of MuseScore's own fixtures and must stay confined to the
// test target — see CLAUDE.md.
import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicMIDI
import SheetMusicMSCX

extension GenWebFixtures {
    /// Three measures, the middle one repeated: the unrolled order is
    /// m0, m1, m1, m2.
    static var repeatScore: Score {
        func quarters(_ pitches: [Int]) -> [VoiceElement] {
            pitches.map { pitch in
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
            }
        }
        return Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [
                        Staff(measures: [
                            Measure(voices: [Voice(elements: quarters([60, 62, 64, 65]))]),
                            Measure(
                                voices: [Voice(elements: quarters([67, 69, 71, 72]))],
                                startRepeat: true,
                                endRepeatCount: 2,
                            ),
                            Measure(voices: [Voice(elements: quarters([64, 62, 60, 60]))]),
                        ]),
                    ],
                ),
            ],
            metaTags: ["workTitle": "web playback", "composer": "swift-sheet-music"],
            titleFrame: ScoreFrame(
                heightSp: 10,
                texts: [FrameText(style: .title, text: "web playback")],
            ),
        )
    }

    /// Two melodic parts on different patches plus a drum part.
    ///
    /// The mixer needs its own fixture because `repeatScore` is all piano, and
    /// on a piano part program 0 is both what the score asks for and what a
    /// channel falls back to when nobody asserts anything — the exact bug the
    /// mixer exists to prevent would pass unnoticed. The volumes differ from
    /// each other and from `InstrumentChannel`'s default 100 for the same
    /// reason.
    static var mixerScore: Score {
        func part(id: String, name: String, program: Int, drums: Bool, volume: Int) -> Part {
            let elements: [VoiceElement] = [60, 62, 64, 65].map { pitch in
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)])))
            }
            return Part(
                id: id,
                instrument: Instrument(
                    id: id,
                    longName: name,
                    channels: [InstrumentChannel(program: program, volume: volume)],
                    useDrumset: drums,
                ),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: elements)])])],
            )
        }
        return Score(
            division: 480,
            parts: [
                part(id: "bass", name: "Bass", program: 33, drums: false, volume: 92),
                part(id: "lead", name: "Lead", program: 84, drums: false, volume: 64),
                part(id: "drums", name: "Drums", program: 0, drums: true, volume: 110),
            ],
            metaTags: ["workTitle": "web mixer", "composer": "swift-sheet-music"],
            titleFrame: ScoreFrame(
                heightSp: 10,
                texts: [FrameText(style: .title, text: "web mixer")],
            ),
        )
    }

    struct CursorProbe: Encodable {
        let playerSeconds: Double
        let xMM: Double
        let yMM: Double
        let widthMM: Double
        let heightMM: Double
        let measureIndex: Int
        let notatedSeconds: Double
    }

    struct PlaybackExpectations: Encodable {
        let totalNotatedSeconds: Double
        let totalPlayerSeconds: Double
        let measureCount: Int
        let division: Int
        let openingQuarterBpm: Double
        /// Digests rather than the payloads: the test only needs to detect
        /// divergence, and a committed SMF would make every renderer change look
        /// like a fixture conflict.
        let midiByteCount: Int
        let midiDigest: UInt32
        let metronomeMidiByteCount: Int
        let metronomeMidiDigest: UInt32
        let metronomeBeatCount: Int
        let measureStartPlayerSeconds: [Double]
        let cursorProbes: [CursorProbe]
    }

    /// Everything `Web/sheet-music-web/test/playback.test.ts` compares the
    /// browser against.
    ///
    /// The cursor probes deliberately repeat the steps
    /// `cursorRectAtPlayerSeconds` takes — clock → frame → hidden-staff
    /// translation → `cursorFrame` → pt-to-mm. Calling the `@JS` function is not
    /// an option here (it only exists in the wasm manifest shape), and the
    /// duplication is what gives the comparison its value: two independent walks
    /// of the same rule agreeing is evidence, one walk compared against itself
    /// is not.
    static func makePlaybackExpectations(score: Score) -> PlaybackExpectations {
        let clock = PlaybackClock(score: score)
        let layout = LayoutBridge.computeWithPages(
            score: score, pageWidthMM: 210, pageHeightMM: 297, options: .verticalDefault,
        )

        let midi: Data
        let metronomeMidi: Data
        do {
            midi = try AudioMidiBridge.renderMidi(score: score)
            metronomeMidi = try AudioMidiBridge.renderMetronomeMidi(score: score)
        } catch {
            fail("could not render the repeat fixture's MIDI: \(error)", code: 9)
        }

        let measureStarts = (0 ..< clock.measureCount).map { index in
            clock.playerSeconds(atMeasureIndex: index) ?? -1
        }

        // Three points on the player clock: the top, the middle (which lands
        // inside the repeat on this fixture) and near the end.
        let total = clock.totalPlayerSeconds
        let probePositions = [0, total * 0.5, total * 0.9]
        let probes = probePositions.map { position in
            cursorProbe(
                at: position,
                clock: clock,
                score: score,
                document: layout.document,
                filteredScore: layout.filteredScore,
            )
        }

        return PlaybackExpectations(
            totalNotatedSeconds: clock.totalNotatedSeconds,
            totalPlayerSeconds: total,
            measureCount: clock.measureCount,
            division: clock.division,
            openingQuarterBpm: score.openingQuarterBpm,
            midiByteCount: midi.count,
            midiDigest: digest(midi),
            metronomeMidiByteCount: metronomeMidi.count,
            metronomeMidiDigest: digest(metronomeMidi),
            metronomeBeatCount: PlaybackTimeline.unrolledMetronomeBeats(score: score).count,
            measureStartPlayerSeconds: measureStarts,
            cursorProbes: probes,
        )
    }

    private static func cursorProbe(
        at playerSeconds: Double,
        clock: PlaybackClock,
        score: Score,
        document: LayoutDocument,
        filteredScore: Score,
    ) -> CursorProbe {
        guard let frame = clock.frame(atPlayerSeconds: playerSeconds) else {
            fail("no frame at player second \(playerSeconds)", code: 10)
        }
        // The fixture hides no staves, so the translation is a no-op here — kept
        // because the wasm side performs it and the two walks have to stay the
        // same walk.
        let translated = score.translateCursorForHiddenStaves(frame.cursor, hiddenStaves: [])
            ?? frame.cursor
        guard let rect = document.cursorFrame(for: translated, in: filteredScore) else {
            fail("no cursor frame at player second \(playerSeconds)", code: 10)
        }
        let ptToMM = 25.4 / 72.0
        return CursorProbe(
            playerSeconds: playerSeconds,
            xMM: Double(rect.origin.x) * ptToMM,
            yMM: Double(rect.origin.y) * ptToMM,
            widthMM: Double(rect.size.width) * ptToMM,
            heightMM: Double(rect.size.height) * ptToMM,
            measureIndex: frame.cursor.measureIndex,
            notatedSeconds: frame.timeSeconds,
        )
    }

    /// No expectations file for this one: what it has to say — the programs and
    /// volumes — is read back through `mixerStrips()` and pinned on the Swift
    /// side by `MixerStripTests`. The browser test only needs a score whose
    /// parts are NOT all the same patch.
    static func writeMixerScore(to directory: URL) {
        let container: Data
        do {
            container = try MSCZWriter.write(score: mixerScore)
        } catch {
            fail("could not write the mixer score: \(error)", code: 5)
        }
        do {
            try container.write(to: directory.appendingPathComponent("mixer.mscz"))
        } catch {
            fail("could not write mixer.mscz: \(error)", code: 11)
        }
        print("wrote mixer.mscz (\(container.count)B)")
    }

    static func writePlayback(
        container: Data,
        expectations: PlaybackExpectations,
        to directory: URL,
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try container.write(to: directory.appendingPathComponent("repeat.mscz"))
            try encoder.encode(expectations)
                .write(to: directory.appendingPathComponent("repeat-playback.json"))
        } catch {
            fail("could not write playback fixtures to \(directory.path): \(error)", code: 11)
        }
    }
}
