// Checks the committed browser fixtures against what this run produced — or
// rewrites them.
//
// CHECK is the default. Every file `GenWebFixtures` would write is compared
// byte for byte with the copy in the checkout, and a mismatch exits non-zero.
// Set `SM_WEB_FIXTURE_RECORD=1` to write instead:
//
//     SM_WEB_FIXTURE_RECORD=1 swift run GenWebFixtures \
//         Web/sheet-music-web/test/fixtures \
//         Web/sheet-music-web/assets/sheet-music.smft
//
// The default used to be "write, unconditionally", which meant nothing ever
// failed when a committed number went stale — the tool was run by hand, by
// whoever remembered. `repeat-playback.json` was recorded on 2026-08-18 and
// silently stopped describing the engine when start-/end-repeat barlines began
// taking horizontal space; the browser suite found it two weeks later, and only
// because the browser and the Apple build had by then disagreed. A recorded
// number nobody regenerates is not evidence, so the tool now asserts by default
// and CI runs it.
//
// Why the check lives in this executable rather than in a Swift Testing suite,
// which is how `EditReplayWebGoldenTests` records its goldens: these numbers
// depend on `FontMetrics.provider` being the `sheet-music.smft` TABLE provider —
// the one the browser installs, not CoreText. Measured on this fixture, the two
// providers put the first cursor rect 0.57 mm apart, so the choice is not
// cosmetic. `SheetMusicTests` runs under the CoreText provider and its suites
// run in parallel over that global, so a suite that swapped it would race every
// layout-running suite in the target — see the note at the top of
// `SheetMusicLayoutAppleInstallTests`. This process installs the table provider
// deliberately and owns it for its whole lifetime.
import Foundation

/// Writes or verifies one fixture file at a time, and remembers what drifted.
enum FixtureEmitter {
    /// Set to "1" to rewrite the fixtures instead of checking them.
    static let recordVariable = "SM_WEB_FIXTURE_RECORD"

    static let isRecording =
        ProcessInfo.processInfo.environment[recordVariable] == "1"

    /// Single-threaded by construction: `GenWebFixtures.run()` emits every
    /// file from the main thread, in order.
    private nonisolated(unsafe) static var checked = 0
    private nonisolated(unsafe) static var drifted: [String] = []

    /// "wrote" or "checked", so the tool's own log says which it did.
    static var verb: String {
        isRecording ? "wrote" : "checked"
    }

    /// Write `data` as `name` under `directory`, or compare it with the
    /// committed copy and remember any difference.
    static func emit(_ data: Data, as name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        guard !isRecording else {
            try data.write(to: url)
            return
        }
        checked += 1
        guard let committed = try? Data(contentsOf: url) else {
            drifted.append("\(name) — not in the checkout")
            return
        }
        if committed != data {
            drifted.append("\(name) — \(committed.count)B committed vs \(data.count)B generated")
        }
    }

    /// Report and exit. Nothing else in the tool calls `exit` on success, so a
    /// caller that forgets this would check nothing and still pass.
    static func finish() -> Never {
        guard !isRecording else {
            print("recorded the browser fixtures; commit them")
            exit(0)
        }
        guard drifted.isEmpty else {
            var message = "error: \(drifted.count) browser fixture(s) no longer match the "
            message += "Apple build:\n"
            for entry in drifted {
                message += "  \(entry)\n"
            }
            message += "re-record with \(recordVariable)=1 and commit the result, "
            message += "AFTER confirming the engine change that moved them was intended.\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(3)
        }
        print("\(checked) browser fixture(s) match the Apple build")
        exit(0)
    }
}
