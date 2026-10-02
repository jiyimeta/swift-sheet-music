import Foundation
import SheetMusicAudioCore
import SheetMusicAudioWindows

/// One pass / fail line of the probe, and its row in the JSON summary.
struct Check: Codable {
    let step: String
    let name: String
    let ok: Bool
    let value: String
    let limit: String
}

/// The checks and notes of one run, printed as they happen and summarized as JSON at the end.
final class ProbeReport {
    private(set) var checks: [Check] = []
    private(set) var notes: [String: [String]] = [:]

    /// Records and prints `ok   <step>  <name>  <value> (limit)` or `FAIL <step> …`.
    func check(_ step: String, _ name: String, _ ok: Bool, value: String, limit: String) {
        checks.append(Check(step: step, name: name, ok: ok, value: value, limit: limit))
        let mark = ok ? "ok  " : "FAIL"
        print("\(mark) \(step.padding(toLength: 13, withPad: " ", startingAt: 0)) \(name): \(value)  [\(limit)]")
    }

    /// A measurement or an instruction that is not itself a pass / fail.
    func note(_ step: String, _ text: String) {
        notes[step, default: []].append(text)
        print("info \(step.padding(toLength: 13, withPad: " ", startingAt: 0)) \(text)")
    }

    struct Summary: Codable {
        let passed: Int
        let failed: Int
        let checks: [Check]
        let notes: [String: [String]]
        let diagnostics: DiagnosticsRow
    }

    struct DiagnosticsRow: Codable {
        let sampleRate: Double
        let bufferFrames: Int
        let latencyMilliseconds: Double
        let underruns: Int
        let hasOutputDevice: Bool
        let deviceRebuilds: Int
        let lastDeviceRebuildMilliseconds: Double?
        let loopWraps: Int
        let soundFontLoaded: Bool

        init(_ diagnostics: WindowsPlaybackEngine.Diagnostics) {
            sampleRate = diagnostics.sampleRate
            bufferFrames = diagnostics.bufferFrames
            latencyMilliseconds = diagnostics.latencySeconds * 1000
            underruns = diagnostics.underruns
            hasOutputDevice = diagnostics.hasOutputDevice
            deviceRebuilds = diagnostics.deviceRebuilds
            lastDeviceRebuildMilliseconds = diagnostics.lastDeviceRebuildSeconds.map { $0 * 1000 }
            loopWraps = diagnostics.loopWraps
            soundFontLoaded = diagnostics.soundFontLoaded
        }
    }

    func summaryJSON(diagnostics: WindowsPlaybackEngine.Diagnostics) -> Data {
        let summary = Summary(
            passed: checks.count(where: \.ok), failed: checks.count(where: { !$0.ok }), checks: checks, notes: notes,
            diagnostics: DiagnosticsRow(diagnostics),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(summary)) ?? Data("{}".utf8)
    }
}

/// Collects what the engine reports on other threads — levels, events — for the probe's main thread to read.
final class ProbeInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Float = 0
    private var levelCount = 0
    private var events: [WindowsPlaybackEngine.Event] = []
    private var removals = 0

    func record(_ level: MixLevel) {
        lock.lock()
        peak = max(peak, level.peak)
        levelCount += 1
        lock.unlock()
    }

    func record(_ event: WindowsPlaybackEngine.Event) {
        lock.lock()
        events.append(event)
        lock.unlock()
        print("event \(event)")
    }

    func recordDeviceRemoved() {
        lock.lock()
        removals += 1
        lock.unlock()
        print("event outputDeviceRemoved")
    }

    /// `onOutputDeviceRemoved` calls since the last call, and resets the count.
    func takeRemovals() -> Int {
        lock.lock()
        defer {
            removals = 0
            lock.unlock()
        }
        return removals
    }

    /// The largest pre-shaping peak and the number of readings since the last call, and resets both.
    func takeLevels() -> (peak: Float, readings: Int) {
        lock.lock()
        defer {
            peak = 0
            levelCount = 0
            lock.unlock()
        }
        return (peak, levelCount)
    }

    func takeEvents() -> [WindowsPlaybackEngine.Event] {
        lock.lock()
        defer {
            events = []
            lock.unlock()
        }
        return events
    }
}

/// Resolves every lookup to the one SoundFont the probe was given.
struct FileResolver: SoundfontResolver {
    let url: URL

    func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
        url
    }

    var defaultGMSoundfontURL: URL? {
        url
    }
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

func formatted(_ value: Double, _ digits: Int = 3) -> String {
    String(format: "%.\(digits)f", value)
}
