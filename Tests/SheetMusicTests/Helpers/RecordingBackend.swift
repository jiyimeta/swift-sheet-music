#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
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
    final class RecordingBackend: SynthBackendTestDouble {
        let outputNode: AVAudioNode = AVAudioMixerNode()
        /// Whether the SoundFont has landed. A test sets it false to stand in for an asynchronous load still running.
        var isReady = true
        var currentPositionSeconds: TimeInterval = 0
        var isAtEnd = false
        private(set) var volumeSends: [(channel: UInt8, cc7: UInt8)] = []
        private(set) var programSends: [(channel: UInt8, program: UInt8)] = []
        private(set) var prepareCallCount = 0
        private(set) var stopCallCount = 0
        private(set) var teardownCallCount = 0
        private(set) var rateValues: [Float] = []
        private(set) var tuningValues: [(cents: Double, semitones: Int)] = []
        /// Pre-roll length the last `play` was given, or nil when it was a plain one.
        private(set) var countInSeconds: TimeInterval?
        /// Offset the last-loaded metronome sequence declared.
        private(set) var metronomeOffsetSeconds: TimeInterval = 0
        private(set) var seekCalls: [Int] = []
        /// The SMFs the engine last handed to each transport, so a test can assert
        /// which one a count-in's clicks were written into.
        private(set) var lastSequence: MidiFile?
        private(set) var lastMetronomeSequence: MidiFile?
        /// `true` once the transport was started by a plain `play` or a count-in one.
        private(set) var didPlay = false
        /// Metronome state the last `setMetronomeMuted` / `setMetronomeVolume` set.
        private(set) var metronomeMuted: Bool?
        private(set) var metronomeVolume: Float?
        /// The offline double handed back by `makeOfflineInstance`, and the sample
        /// rate it was asked for — this is how an export test reaches the instance
        /// the export built for itself.
        private(set) var offlineInstance: RecordingBackend?
        private(set) var offlineSampleRate: Double?
        private(set) var timeline: PlaybackTimeline?

        /// A transport call whose place in the order decides what a start sounds like.
        enum TransportEvent: Equatable {
            case seek(tick: Int)
            case loadMetronomeSequence(offsetSeconds: TimeInterval)
            case setMetronomeMuted(Bool)
            case play
            case playAfterCountIn(seconds: TimeInterval)

            var isSeek: Bool {
                if case .seek = self { true } else { false }
            }

            var isPlay: Bool {
                switch self {
                case .play, .playAfterCountIn: true
                default: false
                }
            }
        }

        /// The transport calls in the order they arrived. A count-in is heard only in one order — the seek, which
        /// moves both transports; the count's metronome load, which re-parks that transport at the count's first
        /// click; the mute; the held play — and nothing else the recorder keeps can tell the orders apart.
        private(set) var transportEvents: [TransportEvent] = []

        /// The last start: the calls from the last seek through the first play after it (to the end of the log when
        /// none followed). Empty when nothing seeked.
        var lastStart: [TransportEvent] {
            guard let seek = transportEvents.lastIndex(where: \.isSeek) else { return [] }
            let tail = transportEvents[seek...]
            guard let play = tail.firstIndex(where: \.isPlay) else { return Array(tail) }
            return Array(tail[...play])
        }

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
        ) {
            prepareCallCount += 1
        }

        func loadSequence(_ midi: MidiFile, timeline: PlaybackTimeline) {
            lastSequence = midi
            self.timeline = timeline
        }

        func loadMetronomeSequence(_ midi: MidiFile, offsetSeconds: TimeInterval) {
            lastMetronomeSequence = midi
            metronomeOffsetSeconds = offsetSeconds
            transportEvents.append(.loadMetronomeSequence(offsetSeconds: offsetSeconds))
        }

        func setMetronomeMuted(_ muted: Bool) {
            metronomeMuted = muted
            transportEvents.append(.setMetronomeMuted(muted))
        }

        func setMetronomeVolume(_ volume: Float) {
            metronomeVolume = volume
        }

        func play() {
            countInSeconds = nil
            didPlay = true
            transportEvents.append(.play)
        }

        func play(afterCountInSeconds seconds: TimeInterval) {
            countInSeconds = seconds
            didPlay = true
            transportEvents.append(.playAfterCountIn(seconds: seconds))
        }

        /// A second recorder, so an export test can assert what the offline
        /// pipeline pushed onto the instance it built for itself.
        func makeOfflineInstance(sampleRate: Double) -> (any SynthBackend)? {
            offlineSampleRate = sampleRate
            let instance = RecordingBackend()
            offlineInstance = instance
            return instance
        }

        func pause() {}
        func stop() {
            stopCallCount += 1
            currentPositionSeconds = 0
        }

        func seek(toTick tick: Int) {
            seekCalls.append(tick)
            transportEvents.append(.seek(tick: tick))
            guard let timeline else { return }
            currentPositionSeconds = timeline.seconds(atTick: Double(tick))
        }

        func setRate(_ rate: Float) {
            rateValues.append(rate)
        }

        func setTuning(cents: Double, transposeSemitones: Int) {
            tuningValues.append((cents, transposeSemitones))
        }

        func setProgram(channel: UInt8, program: UInt8) {
            programSends.append((channel, program))
        }

        func sendVolume(channel: UInt8, cc7: UInt8) {
            volumeSends.append((channel, cc7))
        }

        /// Live note and pitch-wheel traffic in the order it arrived — an audition's wheel has to come before its key.
        enum LiveEvent: Equatable {
            case noteOn(channel: UInt8, pitch: UInt8)
            case bend(channel: UInt8, value: UInt16)
        }

        private(set) var liveEvents: [LiveEvent] = []

        func startNote(channel: UInt8, pitch: UInt8, velocity _: UInt8) {
            liveEvents.append(.noteOn(channel: channel, pitch: pitch))
        }

        func stopNote(channel _: UInt8, pitch _: UInt8) {}

        func sendPitchBend(channel: UInt8, value: UInt16) {
            liveEvents.append(.bend(channel: channel, value: value))
        }

        func teardown() {
            teardownCallCount += 1
        }
    }
#endif
