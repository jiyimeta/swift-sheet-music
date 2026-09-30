import Foundation
import SheetMusicBridgeCore
import SheetMusicRenderWindows
import WinSDK

/// `windows-render-probe --onscreen`: measures `ScoreSurface` in a plain Win32 window on `GeneratedScore` (about 40
/// A4 pages), checks the gates of the C spec (folino
/// `docs/superpowers/specs/2026-09-30-ssm-4-c-windows-onscreen-render-design.md` §10), and writes `onscreen.json`.
///
/// Times are the surface's own work per frame — rasterizing tiles, composing, overlays — without the wait in `Present`,
/// which only paces the loop to the display. Pixel parity reads the frame back before it is presented, so it does not
/// depend on the display being on, and compares it with the same page rendered untiled on the same device: what it
/// proves is that the tiles compose to the untiled page. (The Windows-versus-Mac parity is the PNG path's gate.)
struct OnscreenProbe {
    let outputDirectory: URL
    let metricsPath: String
    let fontFiles: [String]

    /// One gate: its name, the measured value, and whether it passed.
    struct Gate {
        let name: String
        let value: String
        let passed: Bool

        /// A gate on a measured number that must not exceed `bound`.
        static func atMost(_ name: String, _ value: Double, _ bound: Double) -> Gate {
            Gate(name: name, value: String(format: "%.3f", value), passed: value <= bound)
        }
    }

    /// Everything one run measured.
    struct Results {
        var pageCount: Int
        var layoutMs: Double
        var firstFrameMs: Double
        var scroll: [Double]
        var zoom: OnscreenSession.Zoom
        var cursor: OnscreenSession.Cursor
        var parity: [OnscreenSession.Parity]
        var deviceLoss: OnscreenSession.DeviceLoss
        var failures: [String]
    }

    func run() throws -> Bool {
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
        _ = SetThreadExecutionState(EXECUTION_STATE(ES_CONTINUOUS | ES_DISPLAY_REQUIRED))
        // The table for Bravura and Edwin, DirectWrite for the system face the labels are drawn in.
        try installWindowsFontMetrics(tableBytes: Data(contentsOf: URL(fileURLWithPath: metricsPath)))
        let session = try OnscreenSession(fontFiles: fontFiles)
        defer { session.close() }

        let firstFrameMs = session.firstFrame()
        let scroll = session.scroll(frames: 600, stepPx: 20)
        let zoom = session.zoom()
        let cursor = session.cursor(seconds: 60)
        let parity = try [1.0, 1.5, 2.0].map { try session.parity(zoom: $0) }
        let deviceLoss = try session.deviceLoss()
        let results = Results(
            pageCount: session.pageCount, layoutMs: session.layoutMs, firstFrameMs: firstFrameMs, scroll: scroll,
            zoom: zoom, cursor: cursor, parity: parity, deviceLoss: deviceLoss, failures: session.failures,
        )

        let gates = gates(for: results)
        for gate in gates {
            print("\(gate.passed ? "ok  " : "FAIL") \(gate.name): \(gate.value)")
        }
        print(session.cacheSummary)
        let passed = gates.allSatisfy(\.passed)
        try writeJSON(results, passed: passed)
        return passed
    }

    /// The gates of the C spec's §10.
    private func gates(for results: Results) -> [Gate] {
        let scroll = results.scroll
        let over = Double(scroll.count(where: { $0 > 16.7 })) / Double(max(1, scroll.count)) * 100
        var gates = [
            Gate.atMost("first frame <= 300 ms", results.firstFrameMs, 300),
            Gate.atMost("layout + first frame <= 3 s", results.layoutMs + results.firstFrameMs, 3000),
            Gate.atMost("scroll work p50 <= 4 ms", percentile(scroll, 0.5), 4),
            Gate.atMost("scroll work p99 <= 16 ms", percentile(scroll, 0.99), 16),
            Gate.atMost("scroll frames over 16.7 ms <= 1 %", over, 1),
            Gate.atMost("zoom gesture work p99 <= 16 ms", percentile(results.zoom.gesture, 0.99), 16),
            Gate.atMost("zoom settle re-raster <= 150 ms", results.zoom.settleMs, 150),
            Gate.atMost("cursor work p99 <= 8 ms", percentile(results.cursor.work, 0.99), 8),
            Gate.atMost("cursor CPU <= 25 % of one core", results.cursor.cpuPercent, 25),
            Gate.atMost("private bytes at 200 % <= +150 MB", results.zoom.deltaMB, 150),
            Gate(
                name: "device loss recreated the device", value: "\(results.deviceLoss.recreated)",
                passed: results.deviceLoss.recreated,
            ),
            Gate.atMost("parity after device loss <= 0.1 %", results.deviceLoss.parity.mean, 0.1),
            Gate(
                name: "no draw failed", value: results.failures.joined(separator: "; "),
                passed: results.failures.isEmpty,
            ),
        ]
        for result in results.parity {
            gates.append(Gate(
                name: "parity at \(Int(result.zoom * 100)) % <= 0.1 %",
                value: "\(format(result.mean)) (max channel \(result.maxChannel))", passed: result.mean <= 0.1,
            ))
            // A hollow figure strokes but fills nothing, silently, and parity cannot see it (both sides draw the same
            // nothing). Filled beams darken every centre-line sample; hollow ones only those a stem happens to cross.
            gates.append(Gate(
                name: "beam coverage at \(Int(result.zoom * 100)) % >= 90 %",
                value: "\(format(result.beamCoverage)) % of \(result.beamSamples) samples",
                passed: result.beamSamples > 0 && result.beamCoverage >= 90,
            ))
        }
        return gates
    }

    private func writeJSON(_ results: Results, passed: Bool) throws {
        let parity = results.parity.map {
            "{\"zoom\": \($0.zoom), \"mean\": \(number($0.mean)), \"beamCoverage\": \(number($0.beamCoverage)), "
                + "\"beamSamples\": \($0.beamSamples)}"
        }
        let json = """
        {
          "pages": \(results.pageCount), "layoutMs": \(number(results.layoutMs)), \
        "firstFrameMs": \(number(results.firstFrameMs)),
          "scroll": {"p50": \(number(percentile(results.scroll, 0.5))), \
        "p99": \(number(percentile(results.scroll, 0.99)))},
          "zoom": {"gestureP99": \(number(percentile(results.zoom.gesture, 0.99))), \
        "settleMs": \(number(results.zoom.settleMs)), "privateBytesDeltaMB": \(number(results.zoom.deltaMB)), \
        "deferredTiles": \(results.zoom.deferredTiles)},
          "cursor": {"p99": \(number(percentile(results.cursor.work, 0.99))), \
        "cpuPercentOfOneCore": \(number(results.cursor.cpuPercent))},
          "parity": [\(parity.joined(separator: ", "))],
          "deviceLoss": {"recreated": \(results.deviceLoss.recreated), \
        "afterMean": \(number(results.deviceLoss.parity.mean))},
          "passed": \(passed)
        }
        """
        try json.write(to: outputDirectory.appendingPathComponent("onscreen.json"), atomically: true, encoding: .utf8)
    }

    /// `format` for the JSON, where a value that was not measured (infinite) has to be `null`: `inf` is not JSON.
    private func number(_ value: Double) -> String {
        value.isFinite ? format(value) : "null"
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .infinity }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
