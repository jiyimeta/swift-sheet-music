import Foundation
import SheetMusicRenderWindows
import WinSDK

/// `windows-render-probe --pdf <file.pdf> <out dir>`: `ScoreSurface` showing a PDF (`setPDF`) in a plain Win32 window,
/// the measurement folino's P4b plan asks of it (`docs/superpowers/plans/2026-10-05-windows-p4b-pdf-scores.md`, Task
/// 2): opening the file, the first frame, a scroll from the first page to the last, a zoom gesture, and the frame read
/// back against the page drawn straight at 100, 200 and 800 % — the last past the page cap, where a stretched bitmap
/// would show — and after a device loss.
///
/// The pages are drawn on the surface's worker thread, so what is gated of the time is a frame's own work (uploads and
/// blits) through the scroll and the gesture; how long the pages take to arrive — the first frame, the settles — is
/// reported, since a PDF page costs what its content costs. The other checks are the ones a wrong cache would fail:
/// parity, the cache staying within its budget, the device coming back, and no frame failing. Writes
/// `<out dir>/pdf.json` and exits 1 when a check fails.
struct PDFProbe {
    let pdfPath: String
    let outputDirectory: URL

    func run() throws -> Bool {
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
        _ = SetThreadExecutionState(EXECUTION_STATE(ES_CONTINUOUS | ES_DISPLAY_REQUIRED))
        let session = try PDFSession(path: pdfPath)
        defer { session.close() }
        print("pdf: \(session.pageCount) pages, opened in \(format(session.openMs)) ms")

        let firstFrameMs = session.firstFrame()
        print("first frame with its pages: \(format(firstFrameMs)) ms")
        let scroll = session.scroll(stepPx: 60)
        let zoom = session.zoom()
        let parity = try [(1.0, 0.0, 0.0), (2.0, 40.0, 60.0), (8.0, 70.0, 120.0)].map {
            try session.parity(zoom: $0.0, originMM: ($0.1, $0.2))
        }
        let deviceLoss = try session.deviceLoss()

        var gates = [
            OnscreenProbe.Gate.atMost(
                "cache through the scroll <= 64 MB", Double(scroll.maxCacheBytes) / 1_048_576, 64,
            ),
            // The pages are drawn on the worker: a frame only uploads and blits, so the scroll keeps the frame rate.
            OnscreenProbe.Gate.atMost("scroll work p99 <= 16.7 ms", percentile(scroll.work, 0.99), 16.7),
            OnscreenProbe.Gate.atMost("zoom gesture work p99 <= 16.7 ms", percentile(zoom.gesture, 0.99), 16.7),
            OnscreenProbe.Gate(
                name: "device loss recreated the device", value: "\(deviceLoss.recreated)",
                passed: deviceLoss.recreated,
            ),
            OnscreenProbe.Gate.atMost("parity after device loss <= 0.1 %", deviceLoss.parity.mean, 0.1),
        ]
        for result in parity {
            gates.append(OnscreenProbe.Gate(
                name: "parity at \(Int(result.zoom * 100)) % <= 0.1 %",
                value: "\(format(result.mean)) (max channel \(result.maxChannel))", passed: result.mean <= 0.1,
            ))
        }
        gates.append(OnscreenProbe.Gate(
            name: "no draw failed", value: session.failures.joined(separator: "; "), passed: session.failures.isEmpty,
        ))
        for gate in gates {
            print("\(gate.passed ? "ok  " : "FAIL") \(gate.name): \(gate.value)")
        }
        print(session.cacheSummary)
        let passed = gates.allSatisfy(\.passed)
        let parityJSON = parity.map { "{\"zoom\": \($0.zoom), \"mean\": \(format($0.mean))}" }
        let json = """
        {
          "pages": \(session.pageCount), "openMs": \(format(session.openMs)), "firstFrameMs": \(format(firstFrameMs)),
          "scroll": {"frames": \(scroll.work.count), "p50": \(format(percentile(scroll.work, 0.5))), \
        "p99": \(format(percentile(scroll.work, 0.99))), "max": \(format(scroll.work.max() ?? 0)), \
        "pagesUploaded": \(scroll.drawn), "lateFrames": \(scroll.late), \
        "maxCacheMB": \(format(Double(scroll.maxCacheBytes) / 1_048_576)), \
        "privateBytesDeltaMB": \(format(scroll.privateDeltaMB))},
          "zoom": {"gestureP99": \(format(percentile(zoom.gesture, 0.99))), "settleMs": \(format(zoom.settleMs)), \
        "deferredPages": \(zoom.deferredTiles)},
          "parity": [\(parityJSON.joined(separator: ", "))],
          "deviceLoss": {"recreated": \(deviceLoss.recreated), "afterMean": \(format(deviceLoss.parity.mean))},
          "passed": \(passed)
        }
        """
        try json.write(to: outputDirectory.appendingPathComponent("pdf.json"), atomically: true, encoding: .utf8)
        return passed
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.3f", value) : "null"
    }
}
