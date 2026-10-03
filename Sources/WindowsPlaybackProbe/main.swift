// Scripted checks of WindowsPlaybackEngine — the exit of ssm 4.0.0 sub-project D (its design's §7). Each step drives
// the engine the way folino will and reads back what FluidSynth and the transport actually did; every check prints
// one `ok` / `FAIL` line, and the run ends with a JSON summary.
//
//     windows-playback-probe <score> <soundfont.sf2> [--scenario NAME[,NAME…]] [--json PATH]
//
// Scenarios, in order: prepare, play, seek, rate, loop, tuning, mixer, preview, countin, device-fault, device-real.
// The default is every one but device-real, which waits for a person to switch the output device. device-fault needs
// the process to run with SSM_WASAPI_FAIL_ONCE=invalidated. The exit status is the number of failed checks (capped at
// 100), so a script can gate on it.

import Foundation
import SheetMusicAudioCore
import SheetMusicCore
@_spi(PlaybackProbe) import SheetMusicAudioWindows
import SheetMusicLoader

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("windows-playback-probe: \(message)\n".utf8))
    exit(200)
}

let allScenarios = [
    "prepare", "play", "seek", "rate", "loop", "tuning", "mixer", "preview", "countin", "device-fault", "device-real",
]
var positional: [String] = []
var scenarios = allScenarios.filter { $0 != "device-real" }
var jsonPath: String?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--scenario":
        scenarios = (arguments.next() ?? "").split(separator: ",").map(String.init)
        if let unknown = scenarios.first(where: { !allScenarios.contains($0) }) {
            fail("unknown scenario \(unknown); known: \(allScenarios.joined(separator: ", "))")
        }
    case "--json":
        jsonPath = arguments.next()
    default:
        positional.append(argument)
    }
}

guard positional.count == 2 else {
    fail("usage: windows-playback-probe <score> <soundfont.sf2> [--scenario NAME[,NAME…]] [--json PATH]")
}

let scoreURL = URL(fileURLWithPath: positional[0])
let score: Score
do {
    score = try ScoreLoader.loadScore(contentsOf: scoreURL)
} catch {
    fail("cannot load \(scoreURL.lastPathComponent): \(error)")
}

/// The engine loads a copy the probe owns, so asking whether a loaded SoundFont can be renamed touches nothing else.
let soundFontCopy = FileManager.default.temporaryDirectory
    .appendingPathComponent("windows-playback-probe-\(ProcessInfo.processInfo.processIdentifier).sf2")
do {
    if FileManager.default.fileExists(atPath: soundFontCopy.path) {
        try FileManager.default.removeItem(at: soundFontCopy)
    }
    try FileManager.default.copyItem(at: URL(fileURLWithPath: positional[1]), to: soundFontCopy)
} catch {
    fail("cannot copy the SoundFont: \(error)")
}

let report = ProbeReport()
let inbox = ProbeInbox()
let engine = WindowsPlaybackEngine(soundfontResolver: FileResolver(url: soundFontCopy))
engine.onEvent = { [inbox] event in inbox.record(event) }
engine.onOutputDeviceRemoved = { [inbox] in inbox.recordDeviceRemoved() }
do {
    try engine.prepare(score: score)
} catch {
    fail("prepare failed: \(error)")
}

report.note(
    "prepare",
    "\(scoreURL.lastPathComponent): \(formatted(engine.totalTimeSeconds, 1)) s, "
        + "\(engine.mixerChannels.count - 1) strips",
)

let probe = Probe(engine: engine, score: score, report: report, inbox: inbox, soundFontCopy: soundFontCopy)
let steps: [(String, () -> Void)] = [
    ("prepare", probe.prepare), ("play", probe.play), ("seek", probe.seek), ("rate", probe.rate),
    ("loop", probe.loop), ("tuning", probe.tuning), ("mixer", probe.mixer), ("preview", probe.preview),
    ("countin", probe.countIn), ("device-fault", probe.deviceFault), ("device-real", probe.deviceReal),
]
for (name, step) in steps where scenarios.contains(name) {
    step()
}

let diagnostics = engine.diagnostics
report.check(
    "summary",
    "underruns (whole run)",
    diagnostics.underruns == 0,
    value: "\(diagnostics.underruns)",
    limit: "0",
)
engine.teardown()
try? FileManager.default.removeItem(at: soundFontCopy)

let json = report.summaryJSON(diagnostics: diagnostics)
if let jsonPath {
    do {
        try json.write(to: URL(fileURLWithPath: jsonPath))
    } catch {
        fail("cannot write \(jsonPath): \(error)")
    }
} else {
    print(String(bytes: json, encoding: .utf8) ?? "{}")
}

let failed = report.checks.count(where: { !$0.ok })
print("\(report.checks.count - failed) passed, \(failed) failed")
exit(Int32(min(failed, 100)))
