#if canImport(CFluidSynth)
    import Foundation
    import SheetMusic
    @testable import SheetMusicAudioFluidSynth
    import SheetMusicMIDI
    import Testing

    /// Local, copyrighted score (not committed): the dense 4-part + bass + drums
    /// arrangement whose Acoustic Grand Piano voicing provokes AUMIDISynth's
    /// audible voice stealing.
    let shinogonoPath =
        NSString(string: "~/Downloads/shinogono.mscz").expandingTildeInPath

    var shinogonoAndSoundfontAvailable: Bool {
        generalUserGSAvailable
            && FileManager.default.fileExists(atPath: shinogonoPath)
    }

    extension AudioEngineSerial {
        /// Phase 1 acceptance test: the FluidSynth backend must play the dense
        /// all-piano texture WITHOUT the AUMIDISynth pathology. AUMIDISynth pins
        /// its shared 64-voice pool's working set at ~27–32 and recycles
        /// still-audible release tails (the audible steal). FluidSynth
        /// (polyphony 256, no process-global recycler) lets the count rise to
        /// true demand (~50–60) and never nears the ceiling, so no voice is
        /// force-stolen.
        struct FluidSynthVoiceTests {
            /// Rewrite every non-drum `programChange` to Acoustic Grand Piano
            /// (0), reproducing the user's "set the channel to piano" mixer
            /// action.
            private func forcePiano(_ midi: inout MidiFile) {
                for t in midi.tracks.indices {
                    for e in midi.tracks[t].events.indices {
                        guard case let .programChange(channel, _) =
                            midi.tracks[t].events[e].event, channel != 9
                        else { continue }
                        midi.tracks[t].events[e].event =
                            .programChange(channel: channel, program: 0)
                    }
                }
            }

            @Test(.enabled(if: shinogonoAndSoundfontAvailable))
            func pianoTextureDoesNotPinTheVoicePool() throws {
                let score = try SheetMusic.loadScore(
                    msczURL: URL(fileURLWithPath: shinogonoPath),
                )
                var midi = try MidiRenderer.render(score: score)
                forcePiano(&midi)

                let engine = FluidSynthEngine(sampleRate: 44100)
                #expect(engine.loadSoundFont(generalUserGSPath) >= 0)
                try engine.loadSMF([UInt8](MidiWriter.write(midi)))
                engine.playerPlay()

                var peak = 0
                var left = [Float](repeating: 0, count: 512)
                var right = [Float](repeating: 0, count: 512)
                let blocks = Int(10.0 * 44100 / 512) // ~10 s of playback
                for _ in 0 ..< blocks {
                    engine.render(frameCount: 512, left: &left, right: &right)
                    peak = max(peak, engine.activeVoiceCount)
                }

                #expect(peak > 10) // real polyphony, not a single stuck voice
                #expect(peak < 200) // never near the 256 ceiling → no forced steal
            }
        }
    }
#endif
