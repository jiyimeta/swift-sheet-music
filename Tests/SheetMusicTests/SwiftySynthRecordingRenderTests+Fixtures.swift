#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicMIDI
        import SheetMusicMSCX
        import Testing

        /// The fixtures, the offline rig and the measurements `SwiftySynthRecordingRenderTests` uses.
        extension AudioEngineSerial.SwiftySynthRecordingRenderTests {
            // MARK: Fixtures

            /// A click SF2 whose sample is a 10 ms square burst, so every note is a sharp, separate onset.
            static func writeClickSoundFont() throws -> URL {
                let wave = (0 ..< 441).map { i -> Int16 in (i / 20) % 2 == 0 ? 16000 : -16000 }
                let sf2 = ClickSoundFontBuilder.build(strong: wave, strongRate: 44100, weak: wave, weakRate: 44100)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-click-\(UUID()).sf2")
                try sf2.write(to: url)
                return url
            }

            /// A PCM cache file (`RecordingPCMCache`'s format: "SMPC", version 1, frame count, rate, then interleaved
            /// Int16 left / right) holding `frames` frames of `sample(frame)` on both channels, mapped.
            static func recording(rate: Int, frames: Int, sample: (Int) -> Int16) throws -> MappedRecording {
                var bytes = Data(Array("SMPC".utf8))
                for word in [UInt32(1), UInt32(frames), UInt32(rate)] {
                    withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
                }
                var samples: [Int16] = []
                samples.reserveCapacity(frames * 2)
                for frame in 0 ..< frames {
                    let value = sample(frame)
                    samples.append(value.littleEndian)
                    samples.append(value.littleEndian)
                }
                samples.withUnsafeBytes { bytes.append(contentsOf: $0) }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID()).pcm")
                try bytes.write(to: url)
                defer { try? FileManager.default.removeItem(at: url) }
                return try MappedRecording(pcmFile: url)
            }

            /// 4-frame impulses of 0.9 at each of `seconds`, silence elsewhere.
            static func impulses(at seconds: [Double], rate: Int, length: Double) throws -> MappedRecording {
                let starts = seconds.map { Int(($0 * Double(rate)).rounded()) }
                return try recording(rate: rate, frames: Int(length * Double(rate))) { frame in
                    starts.contains { frame >= $0 && frame < $0 + 4 } ? 29490 : 0
                }
            }

            /// A 220 Hz sine at half scale.
            static func tone(_ frame: Int) -> Int16 {
                Int16((16384 * sin(2 * Double.pi * 220 * Double(frame) / 44100)).rounded())
            }

            /// A score SMF at 120 BPM (a 4/4 measure is 2 s) with nothing in it, so all that sounds is the recording.
            static func silentScore() -> SheetMusicMIDI.MidiFile {
                SheetMusicMIDI.MidiFile(division: 480, tracks: [MidiTrack(events: [
                    TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
                    TimedMidiEvent(tick: 480 * 40, event: .endOfTrack),
                ])])
            }

            /// 120 BPM with a click on channel 9 at each of `ticks`, reverb send off so the onsets stand clear.
            static func clickScore(ticks: [Int]) -> SheetMusicMIDI.MidiFile {
                var events = [
                    TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
                    TimedMidiEvent(tick: 0, event: .controlChange(channel: 9, controller: 91, value: 0)),
                ]
                for tick in ticks {
                    events.append(TimedMidiEvent(tick: tick, event: .noteOn(channel: 9, pitch: 76, velocity: 127)))
                    events.append(TimedMidiEvent(tick: tick + 240, event: .noteOff(channel: 9, pitch: 76, velocity: 0)))
                }
                events.append(TimedMidiEvent(tick: 480 * 40, event: .endOfTrack))
                return SheetMusicMIDI.MidiFile(division: 480, tracks: [MidiTrack(events: events)])
            }

            /// The whole recording heard from warped second 0 on, at its own time.
            static func wholeRecording(_ seconds: Double) -> [RecordingSegment] {
                [RecordingSegment(sourceStart: 0, sourceEnd: seconds, outputStart: 0)]
            }

            // MARK: Rig

            /// A prepared backend in an offline engine, with `score` loaded and the transport parked at 0.
            @MainActor
            struct Rig {
                let backend: SwiftySynthBackend
                let engine: AVAudioEngine
                let buffer: AVAudioPCMBuffer
                let slice: AVAudioFrameCount

                static func make(
                    score: SheetMusicMIDI.MidiFile, font: URL, slice: AVAudioFrameCount = sliceFrames,
                    stretcherFactory: RecordingStretcherFactory? = nil,
                ) async throws -> Rig {
                    let backend = SwiftySynthBackend(sampleRate: sampleRate, stretcherFactory: stretcherFactory)
                    backend.prepare(soundfontURL: font, metronomeSoundfontURL: font, drumChannels: [])
                    for _ in 0 ..< 250 where !backend.isReady {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try #require(backend.isReady, "SwiftySynthBackend never became ready")
                    let scoreURL = try #require(TestResources.url(forResource: "midi01", withExtension: "mscx"))
                    let timeline = try PlaybackTimeline(score: MSCXParser.parse(contentsOf: scoreURL))
                    backend.loadSequence(score, timeline: timeline)

                    let engine = AVAudioEngine()
                    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
                    engine.attach(backend.sourceNode)
                    engine.connect(backend.sourceNode, to: engine.mainMixerNode, format: format)
                    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: slice)
                    try engine.start()
                    let buffer = try #require(AVAudioPCMBuffer(
                        pcmFormat: engine.manualRenderingFormat, frameCapacity: slice,
                    ))
                    return Rig(backend: backend, engine: engine, buffer: buffer, slice: slice)
                }

                /// The left channel of the next `frames` frames, rendered in `slice`-frame calls.
                func render(frames: Int) throws -> [Float] {
                    var out: [Float] = []
                    out.reserveCapacity(frames)
                    while out.count < frames {
                        let count = AVAudioFrameCount(min(Int(slice), frames - out.count))
                        let status = try engine.renderOffline(count, to: buffer)
                        let channels = try #require(buffer.floatChannelData)
                        try #require(status == .success)
                        out.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
                    }
                    return out
                }

                func render(seconds: Double) throws -> [Float] {
                    try render(frames: Int((seconds * sampleRate).rounded()))
                }

                func finish() {
                    engine.stop()
                    engine.disableManualRenderingMode()
                }
            }

            // MARK: Measurements

            /// How far (frames) the first sample reaching `threshold` within `window` frames of `expected` is from it,
            /// or nil when nothing there reaches it.
            static func onsetOffset(in samples: [Float], expected: Int, window: Int, threshold: Float) -> Int? {
                let range = max(0, expected - window) ..< min(samples.count, expected + window)
                return range.first { abs(samples[$0]) >= threshold }.map { $0 - expected }
            }

            /// The longest run of consecutive samples below 1e-4 — P1's dropout measure.
            static func longestSilentRun(_ samples: [Float]) -> Int {
                var longest = 0
                var run = 0
                for sample in samples {
                    run = abs(sample) < 1e-4 ? run + 1 : 0
                    longest = max(longest, run)
                }
                return longest
            }

            static func frame(_ seconds: Double) -> Int {
                Int((seconds * sampleRate).rounded())
            }
        }
    #endif
#endif
