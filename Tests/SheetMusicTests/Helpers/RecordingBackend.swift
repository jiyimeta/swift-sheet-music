#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudioApple
    import SheetMusicAudioCore
    import SheetMusicMIDI

    /// Transport-only `SynthBackend` double that also records the
    /// per-channel mixer traffic it receives, so a test can assert what
    /// the engine actually sent. Shared by every test that needs to
    /// observe program-change / CC 7 delivery without a real synth —
    /// extend this in place rather than writing another fake backend.
    @MainActor
    final class RecordingBackend: SynthBackend {
        let outputNode: AVAudioNode = AVAudioMixerNode()
        var currentPositionSeconds: TimeInterval = 0
        var isAtEnd = false
        private(set) var volumeSends: [(channel: UInt8, cc7: UInt8)] = []
        private(set) var programSends: [(channel: UInt8, program: UInt8)] = []
        /// Pre-roll length the last `play` was given, or nil when it was a plain one.
        private(set) var countInSeconds: TimeInterval?
        /// Offset the last-loaded metronome sequence declared.
        private(set) var metronomeOffsetSeconds: TimeInterval = 0
        private(set) var seekCalls: [Int] = []
        /// The SMFs the engine last handed to each transport, so a test can assert
        /// which one a count-in's clicks were written into.
        private(set) var lastSequence: MidiFile?
        private(set) var lastMetronomeSequence: MidiFile?
        private var timeline: PlaybackTimeline?

        func clearRecordings() {
            volumeSends.removeAll()
            programSends.removeAll()
        }

        var currentTick: Int {
            guard let timeline else { return 0 }
            return timeline.frame(atTime: currentPositionSeconds)?.tick ?? 0
        }

        func attach(to engine: AVAudioEngine) {
            engine.attach(outputNode)
        }

        func prepare(
            soundfontURL _: URL?, metronomeSoundfontURL _: URL?, drumChannels _: Set<UInt8>,
        ) {}
        func loadSequence(_ midi: MidiFile, timeline: PlaybackTimeline) {
            lastSequence = midi
            self.timeline = timeline
        }

        func loadMetronomeSequence(_ midi: MidiFile, offsetSeconds: TimeInterval) {
            lastMetronomeSequence = midi
            metronomeOffsetSeconds = offsetSeconds
        }

        func setMetronomeMuted(_: Bool) {}
        func play() {
            countInSeconds = nil
        }

        func play(afterCountInSeconds seconds: TimeInterval) {
            countInSeconds = seconds
        }

        func pause() {}
        func stop() {}
        func seek(toTick tick: Int) {
            seekCalls.append(tick)
            guard let timeline else { return }
            currentPositionSeconds = timeline.seconds(atTick: Double(tick))
        }

        func setRate(_: Float) {}
        func setTuning(cents _: Double, transposeSemitones _: Int) {}
        func setProgram(channel: UInt8, program: UInt8) {
            programSends.append((channel, program))
        }

        func sendVolume(channel: UInt8, cc7: UInt8) {
            volumeSends.append((channel, cc7))
        }

        func startNote(channel _: UInt8, pitch _: UInt8, velocity _: UInt8) {}
        func stopNote(channel _: UInt8, pitch _: UInt8) {}
        func teardown() {}
    }
#endif
