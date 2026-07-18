#if canImport(SwiftySynth)
    import Foundation
    import SheetMusic
    import SheetMusicMIDI
    import SwiftySynth
    import Testing

    /// Stage-1 proof that SwiftySynth (pure-Swift, MIT SF2 synth) plays the dense
    /// all-piano `shinogono` texture WITHOUT the AUMIDISynth voice-stealing
    /// pathology: with a generous polyphony its active-voice count rises to the
    /// true demand and never pins at the ceiling (MeltySynth-style quietest-first
    /// stealing, no process-global recycler). Local, copyrighted assets → gated.
    struct SwiftySynthVoiceTests {
        static let soundfontPath =
            "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/App/Resources/Soundfonts/GeneralUser-GS.sf2"
        static let shinogonoPath =
            NSString(string: "~/Downloads/shinogono.mscz").expandingTildeInPath

        static var assetsAvailable: Bool {
            let fm = FileManager.default
            return fm.fileExists(atPath: soundfontPath)
                && fm.fileExists(atPath: shinogonoPath)
        }

        /// Rewrite every non-drum `programChange` to Acoustic Grand Piano (0) —
        /// the mixer action that provokes AUMIDISynth stealing.
        private func forcePiano(_ midi: inout SheetMusicMIDI.MidiFile) {
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

        @Test(.enabled(if: assetsAvailable))
        func pianoTextureDoesNotPinTheVoicePool() throws {
            let score = try SheetMusic.loadScore(
                msczURL: URL(fileURLWithPath: Self.shinogonoPath),
            )
            var midi = try MidiRenderer.render(score: score)
            forcePiano(&midi)
            let smf = try MidiWriter.write(midi)

            let soundFont = try SoundFont(
                data: Data(contentsOf: URL(fileURLWithPath: Self.soundfontPath)),
            )
            let settings = try SynthesizerSettings(
                sampleRate: 44100, maximumPolyphony: 256,
            )
            let synthesizer = try Synthesizer(soundFont: soundFont, settings: settings)
            let sequencer = MidiFileSequencer(synthesizer: synthesizer)
            try sequencer.play(SwiftySynth.MidiFile(data: smf), loop: false)

            var peak = 0
            var left = [Float](repeating: 0, count: 512)
            var right = [Float](repeating: 0, count: 512)
            let blocks = Int(10.0 * 44100 / 512) // ~10 s
            for _ in 0 ..< blocks {
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        sequencer.render(left: l, right: r)
                    }
                }
                peak = max(peak, synthesizer.activeVoiceCount)
            }

            #expect(peak > 10) // real polyphony, not a single stuck voice
            #expect(peak < 200) // demand-driven, never near the 256 ceiling
        }
    }
#endif
