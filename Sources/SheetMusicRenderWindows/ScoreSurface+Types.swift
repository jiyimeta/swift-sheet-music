import SheetMusicBridgeCore

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

    /// Drawn over the pages each frame, in the page's millimetres.
    public enum Overlay {
        case fillRect(page: Int, rect: DrawRect, argb: UInt32)
        case strokeRect(page: Int, rect: DrawRect, widthMM: Double, argb: UInt32)
        /// Draw-program commands, walked from the default state.
        case commands(page: Int, commands: [DrawCommand])
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
}
