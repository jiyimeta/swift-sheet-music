import Foundation
import SheetMusicRenderWindows
import WinSDK

/// The window, the surface and the PDF a `PDFProbe` run measures, and one method per measurement. The pages are
/// stacked top to bottom, 10 mm apart, as a reader in vertical mode lays them out.
final class PDFSession {
    struct Scroll {
        var work: [Double]
        /// Pages drawn over the scroll, visible and read ahead alike, and of those the ones read ahead.
        var drawn: Int
        var readAhead: Int
        var maxCacheBytes: Int
        var privateDeltaMB: Double
    }

    private static let pageGapMM = 10.0
    /// `CD2D_E_RECREATE` (0x8899000C) as a signed HRESULT.
    private static let recreateHResult: Int32 = -2_003_238_900

    let surface: ScoreSurface
    let pdf: ScorePDF
    let openMs: Double
    private let window: HWND
    private let width: Int
    private let height: Int
    private let displayScale: Double
    private let pageOrigins: [(x: Double, y: Double)]
    private let documentHeightMM: Double
    private let baselineBytes: Int
    private let clock = ContinuousClock()
    private(set) var failures: [String] = []

    init(path: String) throws {
        let clock = ContinuousClock()
        let start = clock.now
        let pdf = try ScorePDF(path: path)
        openMs = OnscreenSession.milliseconds(clock.now - start)
        var origins: [(x: Double, y: Double)] = []
        var top = 0.0
        for page in 0 ..< pdf.pageCount {
            origins.append((0, top))
            top += pdf.pageSizeMM(page).height + Self.pageGapMM
        }

        let window = try OnscreenSession.createWindow()
        var client = RECT()
        GetClientRect(window, &client)
        width = Int(client.right - client.left)
        height = Int(client.bottom - client.top)
        displayScale = Double(GetDpiForWindow(window)) / 96
        print("window: \(width) x \(height) px, display scale \(displayScale)")

        let surface = try ScoreSurface()
        try surface.attach(hwnd: UnsafeMutableRawPointer(window), widthPx: width, heightPx: height)
        surface.setPDF(pdf)
        baselineBytes = OnscreenSession.privateBytes()
        self.window = window
        self.surface = surface
        self.pdf = pdf
        pageOrigins = origins
        documentHeightMM = top
    }

    var pageCount: Int {
        pdf.pageCount
    }

    var cacheSummary: String {
        "pages drawn in the cache: \(surface.tileCount), \(surface.tileBytes / 1_048_576) MB (cap 64 MB)"
    }

    func close() {
        DestroyWindow(window)
    }

    /// The first frame, from nothing drawn: wall time, `Present` included.
    func firstFrame() -> Double {
        let start = clock.now
        draw(zoom: 1, originMM: (0, 0))
        return OnscreenSession.milliseconds(clock.now - start)
    }

    /// From the top of the first page to the bottom of the last, `stepPx` per frame at 100 %; the surface's work per
    /// frame, and the most the cache held.
    func scroll(stepPx: Double) -> Scroll {
        var result = Scroll(work: [], drawn: 0, readAhead: 0, maxCacheBytes: 0, privateDeltaMB: 0)
        var perFrame: [(inView: Int, ahead: Int)] = []
        var maxPrivate = baselineBytes
        let stepMM = stepPx / pxPerMM(zoom: 1)
        let bottom = documentHeightMM - Double(height) / pxPerMM(zoom: 1)
        var originY = 0.0
        while originY < bottom {
            originY = min(originY + stepMM, bottom)
            draw(zoom: 1, originMM: (0, originY))
            let timing = surface.lastDrawTiming
            result.work.append(timing.workMs)
            result.drawn += timing.rasterizedTiles
            result.readAhead += timing.prefetchedTiles
            perFrame.append((timing.rasterizedTiles - timing.prefetchedTiles, timing.prefetchedTiles))
            result.maxCacheBytes = max(result.maxCacheBytes, surface.tileBytes)
            maxPrivate = max(maxPrivate, OnscreenSession.privateBytes())
        }
        result.privateDeltaMB = Double(maxPrivate - baselineBytes) / 1_048_576
        // The slowest frames with how many pages each drew in view and ahead of it: a slow frame that drew a page in
        // view is one the read-ahead did not reach in time.
        let slowest = result.work.indices.sorted { result.work[$0] > result.work[$1] }.prefix(8)
        let listed = slowest.map {
            String(format: "%.1f ms/%d+%d", result.work[$0], perFrame[$0].inView, perFrame[$0].ahead)
        }.joined(separator: ", ")
        print(
            "scroll: \(result.work.count) frames; slowest (work/pages drawn in view+ahead) \(listed); "
                + "\(result.drawn) pages drawn, \(result.readAhead) of them read ahead; "
                + "cache at most \(result.maxCacheBytes / 1_048_576) MB, private bytes +"
                + String(format: "%.1f MB", result.privateDeltaMB),
        )
        return result
    }

    /// 100 → 200 → 100 % as two 30-frame gestures at the top of the first page, each followed by frames at the new
    /// scale until the surface draws at it: that frame's work is the settle.
    func zoom() -> OnscreenSession.Zoom {
        var gesture: [Double] = []
        var settle: [Double] = []
        var deferred = 0
        for (from, to) in [(1.0, 2.0), (2.0, 1.0)] {
            for step in 1 ... 30 {
                draw(zoom: from + (to - from) * Double(step) / 30, originMM: (0, 0), gesture: true)
                gesture.append(surface.lastDrawTiming.workMs)
                deferred += surface.lastDrawTiming.deferredTiles
            }
            let start = clock.now
            var settled = false
            while !settled, clock.now - start < .seconds(5) {
                draw(zoom: to, originMM: (0, 0))
                deferred += surface.lastDrawTiming.deferredTiles
                if !surface.lastDrawTiming.isScaled {
                    settle.append(surface.lastDrawTiming.workMs)
                    settled = true
                }
            }
            if !settled { failures.append("zoom to \(to) never settled") }
        }
        let p99 = gesture.sorted()[Int(Double(gesture.count - 1) * 0.99)]
        print(
            "zoom: gesture work p99 \(String(format: "%.1f", p99)) ms, settles "
                + settle.map { String(format: "%.1f ms", $0) }.joined(separator: " and ")
                + ", \(deferred) pages left to a later frame",
        )
        return OnscreenSession.Zoom(
            gesture: gesture, settleMs: settle.max() ?? .infinity, deltaMB: 0, deferredTiles: deferred,
        )
    }

    /// The frame at `zoom` with the view's top-left at `originMM` on page 1, read back before it is presented, against
    /// page 1 drawn straight at the frame's scale into one band on the surface's own device
    /// (`ScoreSurface.referencePixels`). Each frame is drawn twice first, so the one read back is a settled frame drawn
    /// from the cache.
    func parity(zoom: Double, originMM: (x: Double, y: Double)) throws -> OnscreenSession.Parity {
        draw(zoom: zoom, originMM: originMM)
        draw(zoom: zoom, originMM: originMM)
        var frame = [UInt8](repeating: 0, count: width * height * 4)
        frame.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { surface.readBackNext(into: base, width: width, height: height) }
            draw(zoom: zoom, originMM: originMM)
        }
        let reference = try surface.referencePixels(page: 0, frame: makeFrame(zoom: zoom, originMM: originMM))
        guard reference.count == frame.count else {
            throw ProbeError("the reference is \(reference.count) bytes, the frame \(frame.count)")
        }
        // Every view here lies within page 1, so the frame shows no page the reference leaves out.
        var differing = 0
        var maxChannel = 0
        for pixel in 0 ..< width * height {
            var worst = 0
            for channel in 0 ..< 3 {
                worst = max(worst, abs(Int(frame[pixel * 4 + channel]) - Int(reference[pixel * 4 + channel])))
            }
            maxChannel = max(maxChannel, worst)
            if worst > 2 { differing += 1 }
        }
        let mean = Double(differing) / Double(width * height) * 100
        print("parity at \(Int(zoom * 100)) %: \(String(format: "%.4f", mean)) % differ, max channel \(maxChannel); "
            + "cache \(surface.tileCount) pages, \(surface.tileBytes / 1_048_576) MB")
        return OnscreenSession.Parity(zoom: zoom, mean: mean, maxChannel: maxChannel, beamCoverage: 0, beamSamples: 0)
    }

    /// A device loss mid-scroll through the debug hook, then parity at 100 % on the rebuilt device.
    func deviceLoss() throws -> OnscreenSession.DeviceLoss {
        surface.failNext(hresult: Self.recreateHResult)
        var recreated = false
        let stepMM = 20 / pxPerMM(zoom: 1)
        for step in 0 ..< 30 {
            OnscreenSession.pump()
            if case .deviceRecreated = surface.draw(makeFrame(zoom: 1, originMM: (0, Double(step) * stepMM))) {
                recreated = true
            }
        }
        return try OnscreenSession.DeviceLoss(recreated: recreated, parity: parity(zoom: 1, originMM: (0, 0)))
    }

    // MARK: - Frames

    private func pxPerMM(zoom: Double) -> Double {
        zoom * displayScale * 96 / 25.4
    }

    private func makeFrame(
        zoom: Double, originMM: (x: Double, y: Double), gesture: Bool = false,
    ) -> ScoreSurface.Frame {
        ScoreSurface.Frame(
            pxPerMM: pxPerMM(zoom: zoom), originMM: originMM, pageOrigins: pageOrigins, isGesture: gesture,
            backgroundARGB: 0xFFFF_FFFF,
        )
    }

    private func draw(zoom: Double, originMM: (x: Double, y: Double), gesture: Bool = false) {
        OnscreenSession.pump()
        switch surface.draw(makeFrame(zoom: zoom, originMM: originMM, gesture: gesture)) {
        case .presented: break
        case .deviceRecreated: failures.append("device recreated outside the device-loss check")
        case let .failed(hresult): failures.append(String(format: "draw failed 0x%08X", UInt32(bitPattern: hresult)))
        }
    }
}
