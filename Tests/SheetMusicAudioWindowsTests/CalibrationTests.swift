import Foundation
import SheetMusicAudioCore
@testable import SheetMusicAudioWindows
import SheetMusicCore
import SheetMusicLoader
import Testing

/// The Windows engine's output level and reverb tail, for the SwiftySynth switch's calibration table (folino spec
/// `2026-11-04-windows-swiftysynth-design.md` §5): the same scores exported offline before the switch (FluidSynth)
/// and after (SwiftySynth), and on the Mac through the Apple backend, must match within ±1 dB of level and show a
/// like reverb tail. A measurement, not a check — it prints one line per score and asserts only that something
/// sounded. Runs only with `SSM_TEST_SF2` (the font) and `SSM_CALIBRATION=1`; `SSM_CALIBRATION_SCORES` adds scores
/// by path, `;`-separated (folino's `Now_is_the_time.mscz`, for one).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SSM_TEST_SF2"] != nil
        && ProcessInfo.processInfo.environment["SSM_CALIBRATION"] == "1"))
struct CalibrationTests {
    static let sampleRate = 44100
    private let wav16 = AudioFileFormat.wav(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo))

    struct OneFont: SoundfontResolver {
        let url: URL

        func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
            url
        }

        var defaultGMSoundfontURL: URL? {
            url
        }
    }

    @Test func theCalibrationTable() async throws {
        let font = try #require(ProcessInfo.processInfo.environment["SSM_TEST_SF2"].map(URL.init(fileURLWithPath:)))
        var scores: [(String, URL)] = try [
            ("piano chord, then rests", Self.write(Self.pianoChord, "piano-chord")),
            ("drum groove", Self.write(Self.drumGroove, "drum-groove")),
        ]
        let extra = ProcessInfo.processInfo.environment["SSM_CALIBRATION_SCORES"] ?? ""
        for path in extra.split(separator: ";") where !path.isEmpty {
            scores.append((URL(fileURLWithPath: String(path)).lastPathComponent, URL(fileURLWithPath: String(path))))
        }
        for (name, url) in scores {
            let samples = try await render(url, font: font)
            let pcm = Measure(samples: samples, sampleRate: Self.sampleRate)
            let struck = pcm.rmsDB(from: 0.05, to: 0.45)
            print("[calibration] \(name): " + String(
                format: "rms %.1f dBFS, peak %.1f dBFS, struck %.1f dBFS, tail 0.75-1.5 s %+.1f dB",
                pcm.rmsDB(from: 0, to: .infinity), pcm.peakDB, struck, pcm.rmsDB(from: 0.75, to: 1.5) - struck,
            ))
            #expect(pcm.peakDB > -60, "\(name) rendered silence")
        }
    }

    private func render(_ url: URL, font: URL) async throws -> [Int16] {
        let engine = WindowsPlaybackEngine(
            soundfontResolver: OneFont(url: font), output: .offline(sampleRate: Double(Self.sampleRate)),
        )
        defer { engine.teardown() }
        let score = try ScoreLoader.loadScore(contentsOf: url)
        try engine.prepare(score: score)
        let wav = Fixtures.temporaryFile("wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try await engine.exportAudioFile(to: wav, score: score, format: wav16)
        let bytes = try Data(contentsOf: wav)
        return bytes[44...].withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    struct Measure {
        let samples: [Int16]
        let sampleRate: Int

        var peakDB: Double {
            let peak = samples.map { abs(Double($0)) / 32768 }.max() ?? 0
            return peak > 0 ? 20 * log10(peak) : -240
        }

        /// RMS over `start`..<`end` seconds of the interleaved stereo, in dBFS.
        func rmsDB(from start: Double, to end: Double) -> Double {
            let first = min(samples.count, Int(start * Double(sampleRate)) * 2)
            let last = end.isFinite ? min(samples.count, Int(end * Double(sampleRate)) * 2) : samples.count
            guard last > first else { return -240 }
            let sum = samples[first ..< last].reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
            let rms = (sum / Double(last - first)).squareRoot()
            return rms > 0 ? 20 * log10(rms) : -240
        }
    }

    // MARK: - The generated scores

    private static func write(_ mscx: String, _ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-calibration-\(name).mscx")
        try mscx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A C major chord, a quarter at 120 BPM (0.5 s), left to ring through three beats of rest: its release and the
    /// reverb are the tail.
    static let pianoChord = score(
        part: "<Staff id=\"1\"></Staff><Instrument><longName>Piano</longName><Channel><program value=\"0\"/></Channel>"
            + "</Instrument>",
        voice: "<Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note>"
            + "<Note><pitch>64</pitch><tpc>18</tpc></Note><Note><pitch>67</pitch><tpc>15</tpc></Note></Chord>"
            + String(repeating: "<Rest><durationType>quarter</durationType></Rest>", count: 3),
    )

    /// One bar of eighths: kick and hi-hat on the beats, snare and hi-hat off them.
    static let drumGroove = score(
        part: "<Staff id=\"1\"><StaffType group=\"percussion\"><name>perc5Line</name></StaffType></Staff>"
            + "<Instrument><longName>Drumset</longName><instrumentId>drum.group.set</instrumentId>"
            + "<useDrumset>1</useDrumset><Channel><program value=\"0\"/><midiChannel>9</midiChannel></Channel>"
            + "</Instrument>",
        voice: (0 ..< 8).map { index in
            let pitch = index.isMultiple(of: 2) ? 36 : 38
            return "<Chord><durationType>eighth</durationType><Note><pitch>\(pitch)</pitch><tpc>14</tpc></Note>"
                + "<Note><pitch>42</pitch><tpc>14</tpc></Note></Chord>"
        }.joined(),
    )

    private static func score(part: String, voice: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.20"><Score><Division>480</Division>
        <Part id="P1">\(part)</Part>
        <Staff id="1"><Measure><voice><TimeSig><sigN>4</sigN><sigD>4</sigD></TimeSig>\(voice)</voice></Measure>
        <Measure><voice><Rest><durationType>measure</durationType><duration>4/4</duration></Rest></voice></Measure>
        </Staff></Score></museScore>
        """
    }
}
