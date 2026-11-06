#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    import SheetMusicAudioSwiftySynth
    import SheetMusicCore
    import SheetMusicLoader
    import Testing

    /// The Mac's reference row of the Windows SwiftySynth switch's calibration table (folino spec
    /// `2026-11-04-windows-swiftysynth-design.md` §5): the same two generated scores `SheetMusicAudioWindowsTests`'
    /// `CalibrationTests` exports on Windows, exported here through the Apple engine on `SwiftySynthBackend`, offline,
    /// measured the same way — integrated RMS, peak, the struck window, and the tail after a ringing chord. Prints one
    /// line per score; runs only with `SSM_TEST_SF2` (the font) and `SSM_CALIBRATION=1`.
    extension AudioEngineSerial {
        @Suite(.enabled(if: ProcessInfo.processInfo.environment["SSM_TEST_SF2"] != nil
                && ProcessInfo.processInfo.environment["SSM_CALIBRATION"] == "1"))
        @MainActor
        struct AppleCalibrationTests {
            @Test func theMacReferenceRow() async throws {
                let font = try #require(ProcessInfo.processInfo.environment["SSM_TEST_SF2"])
                var scores: [(String, URL)] = []
                for (name, mscx) in [("piano chord, then rests", Self.pianoChord), ("drum groove", Self.drumGroove)] {
                    let source = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ssm-apple-calibration-\(UUID().uuidString).mscx")
                    try mscx.write(to: source, atomically: true, encoding: .utf8)
                    scores.append((name, source))
                }
                defer { scores.prefix(2).forEach { try? FileManager.default.removeItem(at: $0.1) } }
                // `SSM_CALIBRATION_SCORES` adds scores by path, `;`-separated, as on Windows.
                let extra = ProcessInfo.processInfo.environment["SSM_CALIBRATION_SCORES"] ?? ""
                for path in extra.split(separator: ";") where !path.isEmpty {
                    let url = URL(fileURLWithPath: String(path))
                    scores.append((url.lastPathComponent, url))
                }
                for (name, source) in scores {
                    let score = try ScoreLoader.loadScore(contentsOf: source)
                    let engine = PlaybackEngine(
                        soundfontResolver: FixedSoundfontResolver(url: URL(fileURLWithPath: font)),
                        backend: SwiftySynthBackend(),
                    )
                    try engine.prepare(score: score)
                    let wav = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ssm-apple-calibration-\(UUID().uuidString).wav")
                    defer { try? FileManager.default.removeItem(at: wav) }
                    try await engine.exportAudioFile(
                        to: wav, score: score,
                        format: .wav(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo)),
                    )
                    let samples = try Self.interleaved(wav)
                    let struck = Self.rmsDB(samples, from: 0.05, to: 0.45)
                    print("[calibration-mac] \(name): " + String(
                        format: "rms %.1f dBFS, peak %.1f dBFS, struck %.1f dBFS, tail 0.75-1.5 s %+.1f dB",
                        Self.rmsDB(samples, from: 0, to: .infinity), Self.peakDB(samples), struck,
                        Self.rmsDB(samples, from: 0.75, to: 1.5) - struck,
                    ))
                    #expect(Self.peakDB(samples) > -60, "\(name) rendered silence")
                }
            }

            static let sampleRate = 44100.0

            /// The file's frames, interleaved stereo, as floats.
            static func interleaved(_ url: URL) throws -> [Float] {
                let file = try AVAudioFile(forReading: url)
                let buffer = try #require(AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length),
                ))
                try file.read(into: buffer)
                let channels = Int(buffer.format.channelCount)
                guard let data = buffer.floatChannelData else { return [] }
                var out = [Float](repeating: 0, count: Int(buffer.frameLength) * channels)
                for frame in 0 ..< Int(buffer.frameLength) {
                    for channel in 0 ..< channels {
                        out[frame * channels + channel] = data[channel][frame]
                    }
                }
                return out
            }

            static func peakDB(_ samples: [Float]) -> Double {
                let peak = Double(samples.map(abs).max() ?? 0)
                return peak > 0 ? 20 * log10(peak) : -240
            }

            static func rmsDB(_ samples: [Float], from start: Double, to end: Double) -> Double {
                let first = min(samples.count, Int(start * sampleRate) * 2)
                let last = end.isFinite ? min(samples.count, Int(end * sampleRate) * 2) : samples.count
                guard last > first else { return -240 }
                let sum = samples[first ..< last].reduce(0.0) { $0 + Double($1) * Double($1) }
                let rms = (sum / Double(last - first)).squareRoot()
                return rms > 0 ? 20 * log10(rms) : -240
            }

            // The same scores as `SheetMusicAudioWindowsTests/CalibrationTests.swift`; keep the two in step.

            static let pianoChord = score(
                part: "<Staff id=\"1\"></Staff><Instrument><longName>Piano</longName>"
                    + "<Channel><program value=\"0\"/></Channel></Instrument>",
                voice: "<Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note>"
                    + "<Note><pitch>64</pitch><tpc>18</tpc></Note><Note><pitch>67</pitch><tpc>15</tpc></Note></Chord>"
                    + String(repeating: "<Rest><durationType>quarter</durationType></Rest>", count: 3),
            )

            static let drumGroove = score(
                part: "<Staff id=\"1\"><StaffType group=\"percussion\"><name>perc5Line</name></StaffType></Staff>"
                    + "<Instrument><longName>Drumset</longName><instrumentId>drum.group.set</instrumentId>"
                    + "<useDrumset>1</useDrumset><Channel><program value=\"0\"/><midiChannel>9</midiChannel>"
                    + "</Channel></Instrument>",
                voice: (0 ..< 8).map { index in
                    let pitch = index.isMultiple(of: 2) ? 36 : 38
                    return "<Chord><durationType>eighth</durationType><Note><pitch>\(pitch)</pitch><tpc>14</tpc>"
                        + "</Note><Note><pitch>42</pitch><tpc>14</tpc></Note></Chord>"
                }.joined(),
            )

            private static func score(part: String, voice: String) -> String {
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <museScore version="4.20"><Score><Division>480</Division>
                <Part id="P1">\(part)</Part>
                <Staff id="1"><Measure><voice><TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>\(voice)</voice></Measure>
                <Measure><voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice>
                </Measure></Staff></Score></museScore>
                """
            }
        }
    }
#endif
