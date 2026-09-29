// Plays a score through WindowsPlaybackEngine and prints where playback is once a second — the probe behind the
// Windows roadmap's W0-5 ("a piece sounds and the cursor follows it"). The sound is for a person to hear. The
// printout is what shows the cursor keeping up: the wall clock, the device clock, their difference (it should hold
// steady — a drift means the cursor and the sound part ways) and the measure the device clock maps to.
//
//     windows-playback-probe <score> <soundfont.sf2> [--seconds N] [--pause-at S]
//
// --pause-at pauses for two seconds at S seconds of wall time: the device clock must hold still through it and the
// music resume where it stopped. Two seconds in, the probe also reads back each channel's program, to show that the
// programs the engine sets survived the player taking up the sequence.

import Foundation
import SheetMusicAudioWindows
import SheetMusicLoader

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("windows-playback-probe: \(message)\n".utf8))
    exit(1)
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

var positional: [String] = []
var limit: Double?
var pauseAt: Double?
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--seconds": limit = arguments.next().flatMap(Double.init)
    case "--pause-at": pauseAt = arguments.next().flatMap(Double.init)
    default: positional.append(argument)
    }
}

guard positional.count == 2 else {
    fail("usage: windows-playback-probe <score> <soundfont.sf2> [--seconds N] [--pause-at S]")
}

let scoreURL = URL(fileURLWithPath: positional[0])
let engine: WindowsPlaybackEngine
do {
    engine = try WindowsPlaybackEngine(soundFontPath: positional[1])
    try engine.load(ScoreLoader.loadScore(contentsOf: scoreURL))
} catch {
    fail("\(error)")
}

let setup = engine.diagnostics
let format: (String, Double) -> String = { String(format: $0, $1) }
print(
    "device   \(Int(setup.sampleRate)) Hz, buffer \(setup.bufferFrames) frames "
        + "(\(format("%.1f", Double(setup.bufferFrames) / setup.sampleRate * 1000)) ms), "
        + "latency \(format("%.1f", setup.latencySeconds * 1000)) ms",
)
print("score    \(scoreURL.lastPathComponent), \(format("%.1f", engine.totalPlayerSeconds)) s to play")

let clock = ContinuousClock()
let start = clock.now
do {
    try engine.play()
} catch {
    fail("\(error)")
}

var reportedPrograms = false
var paused = false
var pausedAudioSeconds = 0.0
while true {
    Thread.sleep(forTimeInterval: 1)
    let wall = seconds(clock.now - start)
    let position = engine.position

    if !reportedPrograms, wall >= 2 {
        reportedPrograms = true
        let programs = engine.channelPrograms.map { entry in
            let actual = entry.actual.map(String.init) ?? "?"
            let note = entry.actual == entry.expected ? "" : " (expected \(entry.expected))"
            return "ch\(entry.channel) \(actual)\(note)"
        }
        let held = engine.channelPrograms.allSatisfy { $0.actual == $0.expected }
        print("programs \(programs.joined(separator: ", ")) - \(held ? "all held" : "NOT all held")")
    }

    let measure = position.measureIndex.map { String($0 + 1) } ?? "-"
    print(
        "wall \(format("%7.2f", wall))  audio \(format("%7.2f", position.playerSeconds))  "
            + "diff \(format("%+7.3f", position.playerSeconds - wall))  measure \(measure)"
            + (paused ? "  (paused)" : ""),
    )

    if let pauseAt, !paused, wall >= pauseAt, wall < pauseAt + 1 {
        engine.pause()
        paused = true
        pausedAudioSeconds = engine.position.playerSeconds
    } else if paused, let pauseAt, wall >= pauseAt + 2 {
        let held = abs(engine.position.playerSeconds - pausedAudioSeconds) < 0.001
        print("pause    the device clock \(held ? "held" : "MOVED") while paused")
        do {
            try engine.play()
        } catch {
            fail("resuming: \(error)")
        }
        paused = false
    }

    if let limit, wall >= limit { break }
    if engine.isAtEnd { break }
}

do {
    try engine.stop()
} catch {
    fail("stopping: \(error)")
}

print("underruns \(engine.diagnostics.underruns)")
