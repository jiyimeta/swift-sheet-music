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
    }

    struct Cursor {
        var work: [Double]
        var cpuPercent: Double
    }

    struct Parity {
        var zoom: Double
        /// Percentage of pixels whose color differs by more than 2 in any channel.
        var mean: Double
        var maxChannel: Int
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

    private let fontFiles: [String]
    private let window: HWND
    private let surface: ScoreSurface
    private let pages: [EncodablePage]
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

    init(fontFiles: [String]) throws {
        // Locals first: `self` cannot be read until every stored property is set.
        let clock = ContinuousClock()
        let start = clock.now
        let score = try ScoreBridge.loadScore(bytes: Data(GeneratedScore.musicXML().utf8))
        var options = LayoutOptionsWire.verticalDefault
        options.layoutMode = LayoutOptionsWire.Mode.page.rawValue
        let laidOut = LayoutBridge.computePages(score: score, pageWidthMM: 210, pageHeightMM: 297, options: options)
        let elapsed = Self.milliseconds(clock.now - start)
        let commands = laidOut.pages.map(\.commands.count).reduce(0, +)
        print("layout: \(laidOut.pages.count) pages, \(commands) commands, \(elapsed) ms")

        var origins: [(x: Double, y: Double)] = []
        var top = 0.0
        for page in laidOut.pages {
            origins.append((0, top))
            top += page.heightMM + Self.pageGapMM
        }

        let window = try Self.createWindow()
        var client = RECT()
        GetClientRect(window, &client)
        let width = Int(client.right - client.left)
        let height = Int(client.bottom - client.top)
        let displayScale = Double(GetDpiForWindow(window)) / 96
        print("window: \(width) x \(height) px, display scale \(displayScale)")

        let surface = try ScoreSurface(fontFiles: fontFiles)
        try surface.attach(hwnd: UnsafeMutableRawPointer(window), widthPx: width, heightPx: height)
        surface.setPages(laidOut.pages, spans: laidOut.spans)

        self.fontFiles = fontFiles
        baselineBytes = Self.privateBytes()
        layoutMs = elapsed
        pages = laidOut.pages
        pageOrigins = origins
        documentHeightMM = top
        self.window = window
        self.width = width
        self.height = height
        self.displayScale = displayScale
        self.surface = surface
    }

    var pageCount: Int {
        pages.count
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
        let stepMM = stepPx / pxPerMM(zoom: 1)
        let bottom = documentHeightMM - Double(height) / pxPerMM(zoom: 1)
        for _ in 0 ..< frames {
            originY = min(originY + stepMM, bottom)
            draw(zoom: 1, originY: originY)
            work.append(surface.lastDrawTiming.workMs)
        }
        return work
    }

    /// 100 → 200 → 100 % as two 30-frame gestures, each followed by frames at the new scale until the surface
    /// rasterizes it (100 ms after the gesture's last frame).
    func zoom() -> Zoom {
        var gesture: [Double] = []
        var settle: [Double] = []
        var zoomedBytes = baselineBytes
        for (from, to) in [(1.0, 2.0), (2.0, 1.0)] {
            for step in 1 ... 30 {
                draw(zoom: from + (to - from) * Double(step) / 30, originY: originY, gesture: true)
                gesture.append(surface.lastDrawTiming.workMs)
            }
            let start = clock.now
            var settled = false
            while !settled, clock.now - start < .seconds(2) {
                draw(zoom: to, originY: originY)
                if surface.lastDrawTiming.rasterizedTiles > 0 {
                    settle.append(surface.lastDrawTiming.workMs)
                    settled = true
                }
            }
            if !settled { failures.append("zoom to \(to) never settled") }
            if to == 2 { zoomedBytes = Self.privateBytes() }
        }
        return Zoom(
            gesture: gesture, settleMs: settle.max() ?? .infinity,
            deltaMB: Double(zoomedBytes - baselineBytes) / 1_048_576,
        )
    }

    /// A bar moving across the view, paced by the display, for `seconds`.
    func cursor(seconds: Int) -> Cursor {
        var work: [Double] = []
        let cpuStart = Self.processCPUSeconds()
        let start = clock.now
        var tick = 0
        while clock.now - start < .seconds(seconds) {
            let bar = ScoreSurface.Overlay.fillRect(
                page: 0, rect: DrawRect(x: 20 + Double(tick % 600) * 0.3, y: 20, width: 1.5, height: 60),
                argb: 0xC000_7AFF,
            )
            draw(zoom: 1, originY: originY, overlays: [bar])
            work.append(surface.lastDrawTiming.workMs)
            tick += 1
        }
        let elapsed = Self.milliseconds(clock.now - start) / 1000
        return Cursor(work: work, cpuPercent: (Self.processCPUSeconds() - cpuStart) / elapsed * 100)
    }

    /// Page 1 at the top-left, the frame read back before it is presented, against the PNG path's pixels at the
    /// same scale.
    func parity(zoom: Double) throws -> Parity {
        var frame = [UInt8](repeating: 0, count: width * height * 4)
        frame.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { surface.readBackNext(into: base, width: width, height: height) }
            draw(zoom: zoom, originY: 0)
        }
        let reference = try Direct2DPageRenderer.renderPixels(
            pages[0].commands, widthPx: width, heightPx: height, pxPerMM: pxPerMM(zoom: zoom), offsetPx: (0, 0),
            fontFiles: fontFiles,
        )
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
        return Parity(zoom: zoom, mean: Double(differing) / Double(width * height) * 100, maxChannel: maxChannel)
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

    private static func processCPUSeconds() -> Double {
        var creation = FILETIME()
        var exit = FILETIME()
        var kernel = FILETIME()
        var user = FILETIME()
        guard GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user) else { return 0 }
        func seconds(_ time: FILETIME) -> Double {
            Double(UInt64(time.dwHighDateTime) << 32 | UInt64(time.dwLowDateTime)) / 10_000_000
        }
        return seconds(kernel) + seconds(user)
    }

    private static func privateBytes() -> Int {
        var counters = PROCESS_MEMORY_COUNTERS_EX()
        counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS_EX>.size)
        let size = counters.cb
        let read = withUnsafeMutablePointer(to: &counters) { pointer in
            pointer.withMemoryRebound(to: PROCESS_MEMORY_COUNTERS.self, capacity: 1) {
                K32GetProcessMemoryInfo(GetCurrentProcess(), $0, size)
            }
        }
        return read ? Int(counters.PrivateUsage) : 0
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
