import CFluidSynth
import Foundation
@testable import SheetMusicAudioWindows
import SheetMusicMIDI
import Testing

/// The choke on FluidSynth against a real General MIDI SoundFont, which `SSM_TEST_SF2` names (GeneralUser-GS in
/// folino); skipped without one, as the SwiftySynth oracle tests are. A crash cymbal (key 49, channel 10) struck at
/// 0.1 s and released at 0.6 s rings on through FluidSynth's own note-off; with the choke marker at 0.6 s it is gone
/// within `FluidChoke.releaseSeconds`. Dry (no reverb or chorus), so what is left after the choke is the voice itself.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SSM_TEST_SF2"] != nil))
struct FluidChokeTests {
    static let sampleRate = 44100.0

    @Test func aChokedCrashFadesWithinTheChokeRelease() throws {
        let plain = try Self.render(choke: false)
        let choked = try Self.render(choke: true)
        let struck = Self.energy(plain, from: 0.1, to: 0.6)
        func level(_ samples: [Float], _ start: Double, _ end: Double) -> Double {
            10 * log10(max(Self.energy(samples, from: start, to: end), 1e-20) / struck)
        }
        let windows = [(0.6, 0.65), (0.65, 0.75), (0.75, 1.5), (1.5, 3.0)]
        let report = windows.map { start, end in
            String(
                format: "%.2f-%.2fs plain %+.0f choked %+.0f",
                start,
                end,
                level(plain, start, end),
                level(choked, start, end),
            )
        }
        print("[fluid-choke] dB against the struck 0.1-0.6 s: " + report.joined(separator: ", "))
        // The plain crash rings on past the note-off; the choked one is down by 60 dB a few releases later.
        #expect(level(plain, 0.75, 1.5) > -40)
        #expect(level(choked, 0.75, 1.5) < -60)
        // Until the marker the two are the same render.
        #expect(abs(level(choked, 0.1, 0.6)) < 0.01)
    }

    /// Renders the crash through a synth and a player made as the engine makes them, interleaved stereo for 3 s.
    static func render(choke: Bool) throws -> [Float] {
        let path = try #require(ProcessInfo.processInfo.environment["SSM_TEST_SF2"])
        let synth = try SynthHandle.make(
            sampleRate: sampleRate, soundFontURL: URL(fileURLWithPath: path), effects: false,
        )
        defer { synth.delete() }
        let player = try PlayerHandle.make(on: synth, midi: midi(choke: choke), rate: 1)
        defer { player.delete() }
        player.play()
        let frames = Int(sampleRate * 3)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var done = 0
        while done < frames {
            let count = min(1024, frames - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    _ = fluid_synth_write_float(
                        synth.synth, Int32(count), l.baseAddress?.advanced(by: done), 0, 1,
                        r.baseAddress?.advanced(by: done), 0, 1,
                    )
                }
            }
            done += count
        }
        return zip(left, right).flatMap { [$0, $1] }
    }

    /// Format 0, 480 ticks a quarter at 120 bpm (960 ticks a second): the crash on at 0.1 s, off at 0.6 s, and with
    /// `choke` the marker beside the note-off; the track ends at 3 s.
    static func midi(choke: Bool) -> Data {
        var track: [UInt8] = [0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20]
        track += [0x00, 0xB9, 7, 100]
        track += [0x60, 0x99, 49, 100] // 96 ticks: 0.1 s
        track += Self.delta(480) + [0x89, 49, 0] // 0.6 s
        if choke {
            track += [0x00, 0xB9, UInt8(ChokeMarker.controller), 49]
        }
        track += Self.delta(2304) + [0xFF, 0x2F, 0x00] // 3.0 s
        var file: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xE0]
        file += Array("MTrk".utf8) + withUnsafeBytes(of: UInt32(track.count).bigEndian) { Array($0) } + track
        return Data(file)
    }

    static func delta(_ ticks: Int) -> [UInt8] {
        var bytes = [UInt8(ticks & 0x7F)]
        var rest = ticks >> 7
        while rest > 0 {
            bytes.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return bytes
    }

    static func energy(_ samples: [Float], from start: Double, to end: Double) -> Double {
        let first = Int(start * sampleRate) * 2
        let last = min(Int(end * sampleRate) * 2, samples.count)
        return samples[first ..< last].reduce(0) { $0 + Double($1) * Double($1) }
    }
}
