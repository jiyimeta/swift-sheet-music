#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicCore
        import Testing

        /// The score, the warp, the recording, the engine and the measurements `RecordingExportTests` uses.
        extension AudioEngineSerial.RecordingExportTests {
            static let sampleRate = 44100.0
            /// One offline render call (`AudioFileExporter.bufferFrames`): how far a length may be off.
            static let buffer = Int(AudioFileExporter.bufferFrames)
            static let millisecond = 44

            /// Where the recording's impulses are, in reference seconds: the warped downbeats of the second to fourth
            /// measures, and one 5 ms before the body ends.
            static let impulseSeconds = [2.5, 4.5, 7.5, 9.995]

            /// The whole recording heard from warped second 0 on, at its own time.
            static let segments = [RecordingSegment(sourceStart: 0, sourceEnd: 10.5, outputStart: 0)]

            static func frame(_ seconds: Double) -> Int {
                Int((seconds * sampleRate).rounded())
            }

            // MARK: Fixtures

            /// Four 4/4 measures of quarters at 120 BPM: 8 s on the transport.
            static func makeScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let measures = (0 ..< 4).map { index -> Measure in
                    var elements: [VoiceElement] = []
                    if index == 0 { elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4))) }
                    elements += Array(repeating: VoiceElement.chord(quarter), count: 4)
                    return Measure(voices: [Voice(elements: elements)])
                }
                let part = Part(
                    id: "p0", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: measures)],
                )
                let tempo = SystemMeasure(elements: [
                    PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
                ])
                let systemMeasures = [tempo] + Array(repeating: SystemMeasure(), count: 3)
                return Score(
                    division: 480, parts: [part], systemMeasures: IdentifiedArray(systemMeasures), metaTags: [:],
                )
            }

            /// The measures last 2.5, 2, 3 and 2.5 s: 10 s in all, with the stretch changing at every barline.
            static func warp() throws -> PlaybackTimeWarp {
                try PlaybackTimeWarp(spans: [
                    .init(start: 0, end: 2, duration: 2.5), .init(start: 2, end: 4, duration: 2),
                    .init(start: 4, end: 6, duration: 3), .init(start: 6, end: 8, duration: 2.5),
                ])
            }

            /// 10.5 s at 44.1 kHz: 0.5 for the first 50 ms, so its first audible frame is plain to find, then silence
            /// with a 4-frame impulse of 0.9 at each of `impulseSeconds`.
            static func writeRecording() throws -> URL {
                let starts = impulseSeconds.map(frame)
                return try PCMCacheFixture.write(rate: 44100, frames: frame(10.5)) { index in
                    if index < frame(0.05) { return 16384 }
                    return starts.contains { index >= $0 && index < $0 + 4 } ? 29490 : 0
                }
            }

            /// 10.5 s at 44.1 kHz: 0.5 up to reference second `step`, silence from there, so the frame the level drops
            /// is where the transport reached `step`'s warped second.
            static func writeStepRecording(at step: Double) throws -> URL {
                try PCMCacheFixture.write(rate: 44100, frames: frame(10.5)) { $0 < frame(step) ? 16384 : 0 }
            }

            /// The last frame whose level reaches 0.25, or nil.
            static func lastLoud(in samples: [Float]) -> Int? {
                samples.indices.last { abs(samples[$0]) >= 0.25 }
            }

            /// A `PlaybackEngine` on a real `SwiftySynthBackend` with the click font for score and metronome alike, the
            /// score prepared and its one instrument muted, so only a recording and the click can sound. The metronome
            /// strip is muted, at `metronomeVolume`.
            static func makeEngine(font: URL, score: Score, metronomeVolume: Float = 0) throws -> PlaybackEngine {
                let engine = PlaybackEngine(
                    soundfontResolver: FixedSoundfontResolver(url: font),
                    backend: SwiftySynthBackend(sampleRate: sampleRate),
                )
                try engine.prepare(score: score)
                engine.setMuted(forChannel: .instrument(partIndex: 0, ordinal: 0), to: true)
                engine.setMuted(forChannel: .metronome, to: true)
                engine.setVolume(forChannel: .metronome, to: metronomeVolume)
                return engine
            }

            /// The left channel of `engine`'s export to a 44.1 kHz float WAV.
            static func export(
                _ engine: PlaybackEngine, _ score: Score, range: AudioExportRange = .full, countIn: Bool,
            ) async throws -> [Float] {
                let url = AudioExportProbe.temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(
                    to: url, score: score,
                    format: .wav(PCMOptions(sampleRate: sampleRate, bitDepth: .float32, channels: .stereo)),
                    range: range, includesCountIn: countIn,
                )
                let file = try AVAudioFile(forReading: url)
                let buffer = try #require(AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length),
                ))
                try file.read(into: buffer)
                let channels = try #require(buffer.floatChannelData)
                return Array(UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
            }

            // MARK: Measurements

            /// The first frame at or after `start` whose level reaches `threshold`, or nil.
            static func firstAudible(in samples: [Float], from start: Int = 0, threshold: Float = 1e-4) -> Int? {
                (max(0, start) ..< samples.count).first { abs(samples[$0]) >= threshold }
            }

            /// How far (frames) the first impulse within 0.1 s of `expected` is from it, or nil when there is none.
            static func impulseOffset(in samples: [Float], expected: Int) -> Int? {
                let window = frame(0.1)
                let range = max(0, expected - window) ..< min(samples.count, expected + window)
                return range.first { samples[$0] >= 0.5 }.map { $0 - expected }
            }

            static func peak(_ samples: ArraySlice<Float>) -> Float {
                samples.reduce(0) { max($0, abs($1)) }
            }
        }
    #endif
#endif
