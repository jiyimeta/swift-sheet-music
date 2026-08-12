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
        func loadSequence(_: MidiFile, timeline: PlaybackTimeline) {
            self.timeline = timeline
        }

        func loadMetronomeSequence(_: MidiFile) {}
        func setMetronomeMuted(_: Bool) {}
        func play() {}
        func pause() {}
        func stop() {}
        func seek(toTick tick: Int) {
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
