import Foundation
import SheetMusicBridgeCore
import SheetMusicRenderWindows
import WinSDK

/// The window, the surface and the laid-out generated score an `OnscreenProbe` run measures, and one method per
/// measurement.
final class OnscreenSession {
    struct Zoom {
        var gesture: [Double]
        var settleMs: Double
        var deltaMB: Double
        /// Visible tiles left to the background, summed over every frame drawn scaled (the gestures and their settle
        /// delays): a tile missing for three frames counts three times.
        var deferredTiles: Int
    }

    struct Cursor {
        var work: [Double]
        /// Infinite when the process's CPU time could not be read, or did not move (a failure is recorded).
        var cpuPercent: Double
    }

    struct Parity {
        var zoom: Double
        /// Percentage of pixels whose color differs by more than 2 in any of B, G, R from the untiled reference.
        var mean: Double
        var maxChannel: Int
        /// Percentage of the beam centre-line samples (`beamSamples(pxPerMM:)`) that are dark in the frame.
        var beamCoverage: Double
        var beamSamples: Int
    }

    struct DeviceLoss {
        var recreated: Bool
        var parity: Parity
    }

    private static let clientWidth = 1600
    private static let clientHeight = 1000
    private static let pageGapMM = 10.0
    /// `CD2D_E_RECREATE` (0x8899000C) as a signed HRESULT.
    private static let recreateHResult: Int32 = -2_003_238_900

    private let window: HWND
    private let surface: ScoreSurface
    private let pages: ScorePages
    private let pageOrigins: [(x: Double, y: Double)]
    private let documentHeightMM: Double
    private let width: Int
    private let height: Int
    private let displayScale: Double
    private let baselineBytes: Int
    private let clock = ContinuousClock()
    private var originY = 0.0
    let layoutMs: Double
    private(set) var failures: [String] = []

    /// `fontFiles` nil draws with the faces bundled with SheetMusicRenderWindows (`ScoreSurface()`).
    init(fontFiles: [String]?) throws {
        // Locals first: `self` cannot be read until every stored property is set.
        let clock = ContinuousClock()
        let start = clock.now
        // What a host does: load the score, lay it out through the public `ScorePages.compute`, hand the result to the
        // surface. The command count below and the beam samples are all that read past that API.
        let score = try ScoreBridge.loadScore(bytes: Data(GeneratedScore.musicXML().utf8))
        let laidOut = ScorePages.compute(
            score: score, pageWidthMM: 210, pageHeightMM: 297, options: ScorePageOptions(mode: .page),
        )
        let elapsed = Self.milliseconds(clock.now - start)
        let commands = laidOut.pages.map(\.commands.count).reduce(0, +)
        print("layout: \(laidOut.pageCount) pages, \(commands) commands, \(elapsed) ms")

        var origins: [(x: Double, y: Double)] = []
        var top = 0.0
        for page in 0 ..< laidOut.pageCount {
            origins.append((0, top))
            top += laidOut.pageSizeMM(page).height + Self.pageGapMM
        }

        let window = try Self.createWindow()
        var client = RECT()
        GetClientRect(window, &client)
        let width = Int(client.right - client.left)
        let height = Int(client.bottom - client.top)
        let displayScale = Double(GetDpiForWindow(window)) / 96
        print("window: \(width) x \(height) px, display scale \(displayScale)")

        let surface: ScoreSurface
        if let fontFiles {
            surface = try ScoreSurface(fontFiles: fontFiles)
        } else {
            surface = try ScoreSurface()
        }
        try surface.attach(hwnd: UnsafeMutableRawPointer(window), widthPx: width, heightPx: height)
        surface.setPages(laidOut)

        baselineBytes = Self.privateBytes()
        layoutMs = elapsed
        pages = laidOut
        pageOrigins = origins
        documentHeightMM = top
        self.window = window
        self.width = width
        self.height = height
        self.displayScale = displayScale
        self.surface = surface
    }

    var pageCount: Int {
        pages.pageCount
    }

    var cacheSummary: String {
        "tiles: \(surface.tileCount), \(surface.tileBytes / 1_048_576) MB in the cache (cap 64 MB); "
            + "glyph outlines cached: \(surface.glyphCacheCount)"
    }

    func close() {
        DestroyWindow(window)
    }

    /// The first frame of the score, from nothing rasterized: wall time, `Present` included.
    func firstFrame() -> Double {
        let start = clock.now
        draw(zoom: 1, originY: 0)
        return Self.milliseconds(clock.now - start)
    }

    /// `frames` frames scrolling down `stepPx` pixels each; the surface's work per frame.
    func scroll(frames: Int, stepPx: Double) -> [Double] {
        var work: [Double] = []
        var tiles: [Int] = []
        var readAhead: [Int] = []
        let stepMM = stepPx / pxPerMM(zoom: 1)
        let bottom = documentHeightMM - Double(height) / pxPerMM(zoom: 1)
        for _ in 0 ..< frames {
            originY = min(originY + stepMM, bottom)
            draw(zoom: 1, originY: originY)
            work.append(surface.lastDrawTiming.workMs)
            tiles.append(surface.lastDrawTiming.rasterizedTiles)
            readAhead.append(surface.lastDrawTiming.prefetchedTiles)
        }
        // The slowest frames with how many tiles each rasterized, visible + read ahead: a p99 over budget reads as
        // "two tiles in one frame" or as "one tile got slower" only with this beside it. A frame that rasterized more
        // than one visible tile is a row the read-ahead did not reach in time.
        let slowest = work.indices.sorted { work[$0] > work[$1] }.prefix(8)
        let listed = slowest.map {
            String(format: "%.2f ms/%d+%d", work[$0], tiles[$0] - readAhead[$0], readAhead[$0])
        }.joined(separator: ", ")
        let rasterizing = zip(work, tiles).filter { $0.1 > 0 }
        let perTile = rasterizing.map { $0.0 / Double($0.1) }.sorted()
        let median = perTile.isEmpty ? 0 : perTile[perTile.count / 2]
        let crowded = zip(tiles, readAhead).count(where: { $0.0 - $0.1 > 1 })
        print(
            "scroll: slowest frames (work/visible+read-ahead tiles) \(listed); \(rasterizing.count) frames rasterized, "
                + "\(readAhead.reduce(0, +)) tiles read ahead, \(crowded) frames with more than one visible tile; "
                + String(format: "median %.2f ms per tile", median),
        )
        return work
    }

    /// 100 → 200 → 100 % as two 30-frame gestures, each followed by frames at the new scale until the surface draws
    /// at it (100 ms after the gesture's last frame): that frame's work is the settle.
    func zoom() -> Zoom {
        var gesture: [Double] = []
        var settle: [Double] = []
        var deferred = 0
        var zoomedBytes = baselineBytes
        for (from, to) in [(1.0, 2.0), (2.0, 1.0)] {
            for step in 1 ... 30 {
                draw(zoom: from + (to - from) * Double(step) / 30, originY: originY, gesture: true)
                gesture.append(surface.lastDrawTiming.workMs)
                deferred += surface.lastDrawTiming.deferredTiles
            }
            let start = clock.now
            var settled = false
            while !settled, clock.now - start < .seconds(2) {
                draw(zoom: to, originY: originY)
                deferred += surface.lastDrawTiming.deferredTiles
                // Not "rasterized a tile": a frame in the settle delay may rasterize one at the old scale, and the
                // settle itself may find every tile of the new scale still cached.
                if !surface.lastDrawTiming.isScaled {
                    settle.append(surface.lastDrawTiming.workMs)
                    settled = true
                }
            }
            if !settled { failures.append("zoom to \(to) never settled") }
            if to == 2 { zoomedBytes = Self.privateBytes() }
        }
        print("zoom: \(deferred) visible tiles deferred to a later frame, summed over the scaled frames")
        return Zoom(
            gesture: gesture, settleMs: settle.max() ?? .infinity,
            deltaMB: Double(zoomedBytes - baselineBytes) / 1_048_576, deferredTiles: deferred,
        )
    }

    /// A bar moving across the view, paced by the display, for `seconds`. The CPU share fails rather than reads zero
    /// when the process's CPU time cannot be read or does not move: a run of thousands of frames cannot cost nothing.
    func cursor(seconds: Int) -> Cursor {
        var work: [Double] = []
        _ = Self.cyclesPerSecond // calibrate before the clock starts, not inside the measured run
        let cpuStart = Self.processCPUSeconds()
        let start = clock.now
        var tick = 0
        while clock.now - start < .seconds(seconds) {
            let bar = ScoreSurface.Overlay.fillRect(
                page: 0, rect: PageRectMM(x: 20 + Double(tick % 600) * 0.3, y: 20, width: 1.5, height: 60),
                argb: 0xC000_7AFF,
            )
            draw(zoom: 1, originY: originY, overlays: [bar])
            work.append(surface.lastDrawTiming.workMs)
            tick += 1
        }
        let elapsed = Self.milliseconds(clock.now - start) / 1000
        let cpuEnd = Self.processCPUSeconds()
        func describe(_ read: Result<Double, ProbeError>) -> String {
            switch read {
            case let .success(seconds): String(format: "%.6f s", seconds)
            case let .failure(error): error.description
            }
        }
        let wall = String(format: "%.3f", elapsed)
        print(
            "cursor: process CPU \(describe(cpuStart)) at the start, \(describe(cpuEnd)) at the end; "
                + "\(wall) s wall, \(work.count) frames",
        )
        let cpuPercent: Double
        switch (cpuStart, cpuEnd) {
        case let (.success(from), .success(to)) where to > from:
            cpuPercent = (to - from) / elapsed * 100
        case (.success, .success):
            failures.append("the process CPU time did not move over the cursor run")
            cpuPercent = .infinity
        case let (.failure(error), _), let (_, .failure(error)):
            failures.append("reading the process CPU time: \(error)")
            cpuPercent = .infinity
        }
        return Cursor(work: work, cpuPercent: cpuPercent)
    }

    /// Page 1 at the top-left: the frame, read back before it is presented, against the same page rendered untiled
    /// into one band on the surface's own device (`ScoreSurface.referencePixels`), placed from the same rounded page
    /// offset. The rasterizer is the same on both sides, so a differing pixel is the tiling's — not the hardware
    /// versus software antialiasing the PNG path's WIC render differs by along every edge.
    func parity(zoom: Double) throws -> Parity {
        var frame = [UInt8](repeating: 0, count: width * height * 4)
        frame.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { surface.readBackNext(into: base, width: width, height: height) }
            draw(zoom: zoom, originY: 0)
        }
        // Both BGRA: the frame's alpha is ignored and the reference is opaque, so B, G and R are compared.
        let reference = try surface.referencePixels(page: 0, frame: makeFrame(zoom: zoom, originY: 0))
        guard reference.count == frame.count else {
            throw ProbeError("the reference is \(reference.count) bytes, the frame \(frame.count)")
        }
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
        let samples = beamSamples(pxPerMM: pxPerMM(zoom: zoom))
        let dark = samples.count(where: { sample in
            let offset = (sample.y * width + sample.x) * 4
            return max(frame[offset], frame[offset + 1], frame[offset + 2]) < 128
        })
        return Parity(
            zoom: zoom, mean: Double(differing) / Double(width * height) * 100, maxChannel: maxChannel,
            beamCoverage: samples.isEmpty ? 0 : Double(dark) / Double(samples.count) * 100, beamSamples: samples.count,
        )
    }

    /// Frame pixels on the centre line of page 1's beams — each a `moveTo`, three `lineTo` and a `fillPath`, its
    /// corners inner-from, inner-to, outer-to, outer-from (`LayoutBridge`'s `.beam`) — at a quarter, half and three
    /// quarters of its length, for the beams wholly on screen with page 1 at the top-left. Half a beam's thickness
    /// from either edge, so a filled beam covers each sample fully at any zoom.
    private func beamSamples(pxPerMM: Double) -> [(x: Int, y: Int)] {
        let commands = pages.pages[0].commands
        var samples: [(x: Int, y: Int)] = []
        var index = 0
        while index + 4 < commands.count {
            guard case let .moveTo(x0, y0) = commands[index],
                  case let .lineTo(x1, y1) = commands[index + 1],
                  case let .lineTo(x2, y2) = commands[index + 2],
                  case let .lineTo(x3, y3) = commands[index + 3],
                  case .fillPath = commands[index + 4]
            else {
                index += 1
                continue
            }
            index += 5
            let corners = [(x0, y0), (x1, y1), (x2, y2), (x3, y3)].map { ($0.0 * pxPerMM, $0.1 * pxPerMM) }
            guard corners.allSatisfy({ $0.0 >= 0 && $0.0 < Double(width) && $0.1 >= 0 && $0.1 < Double(height) })
            else { continue }
            let from = ((corners[0].0 + corners[3].0) / 2, (corners[0].1 + corners[3].1) / 2)
            let to = ((corners[1].0 + corners[2].0) / 2, (corners[1].1 + corners[2].1) / 2)
            for t in [0.25, 0.5, 0.75] {
                samples.append((
                    x: Int((from.0 + (to.0 - from.0) * t).rounded(.down)),
                    y: Int((from.1 + (to.1 - from.1) * t).rounded(.down)),
                ))
            }
        }
        return samples
    }

    /// A device loss mid-scroll through the debug hook, then parity at 100 % on the rebuilt device.
    func deviceLoss() throws -> DeviceLoss {
        surface.failNext(hresult: Self.recreateHResult)
        var recreated = false
        let stepMM = 20 / pxPerMM(zoom: 1)
        for step in 0 ..< 30 {
            Self.pump()
            let frame = makeFrame(zoom: 1, originY: Double(step) * stepMM)
            if case .deviceRecreated = surface.draw(frame) { recreated = true }
        }
        return try DeviceLoss(recreated: recreated, parity: parity(zoom: 1))
    }

    // MARK: - Frames

    private func pxPerMM(zoom: Double) -> Double {
        zoom * displayScale * 96 / 25.4
    }

    private func makeFrame(
        zoom: Double, originY: Double, gesture: Bool = false, overlays: [ScoreSurface.Overlay] = [],
    ) -> ScoreSurface.Frame {
        ScoreSurface.Frame(
            pxPerMM: pxPerMM(zoom: zoom), originMM: (0, originY), pageOrigins: pageOrigins, overlays: overlays,
            isGesture: gesture, backgroundARGB: 0xFFFF_FFFF,
        )
    }

    private func draw(zoom: Double, originY: Double, gesture: Bool = false, overlays: [ScoreSurface.Overlay] = []) {
        Self.pump()
        switch surface.draw(makeFrame(zoom: zoom, originY: originY, gesture: gesture, overlays: overlays)) {
        case .presented: break
        case .deviceRecreated: failures.append("device recreated outside the device-loss check")
        case let .failed(hresult): failures.append(String(format: "draw failed 0x%08X", UInt32(bitPattern: hresult)))
        }
    }

    // MARK: - Win32

    private static func createWindow() throws -> HWND {
        let instance = GetModuleHandleW(nil)
        let className = "SheetMusicOnscreenProbe"
        let registered = className.withCString(encodedAs: UTF16.self) { name -> ATOM in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = { window, message, wParam, lParam in
                DefWindowProcW(window, message, wParam, lParam)
            }
            windowClass.hInstance = instance
            windowClass.lpszClassName = name
            return RegisterClassExW(&windowClass)
        }
        guard registered != 0 else { throw ProbeError("RegisterClassExW failed: \(GetLastError())") }
        var frame = RECT(left: 0, top: 0, right: LONG(clientWidth), bottom: LONG(clientHeight))
        _ = AdjustWindowRectEx(&frame, DWORD(WS_OVERLAPPEDWINDOW), false, 0)
        let window = className.withCString(encodedAs: UTF16.self) { name in
            "windows-render-probe --onscreen".withCString(encodedAs: UTF16.self) { title in
                CreateWindowExW(
                    0, name, title, DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_VISIBLE), 40, 40, frame.right - frame.left,
                    frame.bottom - frame.top, nil, nil, instance, nil,
                )
            }
        }
        guard let window else { throw ProbeError("CreateWindowExW failed: \(GetLastError())") }
        _ = SetForegroundWindow(window)
        pump()
        return window
    }

    private static func pump() {
        var message = MSG()
        while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) {
            TranslateMessage(&message)
            DispatchMessageW(&message)
        }
    }
}
