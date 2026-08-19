// `CGFloat` / `CGPoint` for WebAssembly.
//
// `ScoreFrame` describes a vertical frame's height in staff spaces and a text
// block's offset in millimetres, and has always spelled those `CGFloat` and
// `CGPoint`. On Apple platforms they come from CoreGraphics; on Android and
// Linux swift-corelibs-foundation vends its own value-type versions. Under
// `FoundationEssentials` — which is what the portable targets import on
// WebAssembly to stay off the ICU-carrying umbrella — neither exists, so this
// module has to supply them.
//
// Scoped to `os(WASI)` on purpose rather than `!canImport(CoreGraphics)`: on
// Android the incumbent type is Foundation's, and the JNI bridge depends on
// that identity (see the warning atop
// `SheetMusicLayout/Fonts/CGTypes+Android.swift`). WebAssembly is the only
// platform where no CG-shaped type exists at all.
//
// `SheetMusicLayout` keeps its own richer stand-ins — including the
// empirically reverse-engineered `CGRect` edge semantics — and those win inside
// that module, exactly as they already do on Android where Core's `CGPoint`
// likewise comes from elsewhere.
#if os(WASI)

    public typealias CGFloat = Double

    public struct CGPoint: Hashable, Sendable {
        public var x: CGFloat
        public var y: CGFloat

        public init(x: CGFloat = 0, y: CGFloat = 0) {
            self.x = x
            self.y = y
        }

        public static let zero = CGPoint()
    }

#endif
