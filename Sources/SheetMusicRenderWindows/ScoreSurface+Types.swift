extension ScoreSurface {
    /// What one frame shows.
    public struct Frame {
        /// Pixels per document millimetre on the swap chain: zoom × composition scale × 96 / 25.4.
        public var pxPerMM: Double
        /// The document point, in millimetres, at the surface's top-left corner.
        public var originMM: (x: Double, y: Double)
        /// Where each page's top-left sits in the document, in millimetres — the app lays the pages out.
        public var pageOrigins: [(x: Double, y: Double)]
        public var overlays: [Overlay]
        /// True while the scale is changing: the settled tiles are drawn scaled rather than rasterized again.
        public var isGesture: Bool
        public var backgroundARGB: UInt32

        public init(
            pxPerMM: Double, originMM: (x: Double, y: Double), pageOrigins: [(x: Double, y: Double)],
            overlays: [Overlay] = [], isGesture: Bool = false, backgroundARGB: UInt32 = 0xFFFF_FFFF,
        ) {
            self.pxPerMM = pxPerMM
            self.originMM = originMM
            self.pageOrigins = pageOrigins
            self.overlays = overlays
            self.isGesture = isGesture
            self.backgroundARGB = backgroundARGB
        }
    }

    /// Drawn over the pages each frame — a playback cursor, selection frames — in page `page`'s millimetres, in the
    /// order the frame lists them. Colors are 0xAARRGGBB.
    public enum Overlay: Sendable, Equatable {
        case fillRect(page: Int, rect: PageRectMM, argb: UInt32)
        /// The rectangle's outline, `widthMM` wide and centered on its edges (at least 1.5 px on screen).
        case strokeRect(page: Int, rect: PageRectMM, widthMM: Double, argb: UInt32)
    }

    public enum DrawOutcome {
        case presented
        /// The device was lost and has been rebuilt; every tile is gone and will be rasterized again. A composition
        /// surface has a new swap chain, with a reference the app releases after `ISwapChainPanelNative::SetSwapChain`.
        case deviceRecreated(newSwapChain: UnsafeMutableRawPointer?)
        case failed(hresult: Int32)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let step: String
        public let hresult: Int32

        public var description: String {
            "\(step) failed (HRESULT 0x\(String(UInt32(bitPattern: hresult), radix: 16, uppercase: true)))"
        }
    }

    /// `lastDrawTiming`'s shape.
    package struct DrawTiming {
        package var workMs = 0.0
        package var presentMs = 0.0
        package var rasterizedTiles = 0
        /// Visible tiles the frame left to the background: while the scale moves, only one missing tile is
        /// rasterized per frame.
        package var deferredTiles = 0
        /// Whether the tiles were drawn stretched from another raster scale (a gesture, or the settle delay after
        /// one) rather than rasterized at the frame's own.
        package var isScaled = false
    }
}
