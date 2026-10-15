#if canImport(CoreGraphics)
    import CoreGraphics
#elseif !os(WASI)
    // See `ScoreFrame.swift` for why this file may reach past `SheetMusicFoundation`.
    // swiftlint:disable:next no_foundation_umbrella
    import Foundation
#endif

/// An `<Image>` inside a `<VBox>` (MS `image.cpp`, written by `rw/write/twrite.cpp`). The bytes live in
/// `Score.pictures`, keyed by `path`.
public struct FrameImage: Sendable, Equatable {
    /// The `<path>` value: the name of the entry under `Pictures/` in the archive.
    public var path: String
    /// `<size w= h=>` as written; `nil` means the picture's native size.
    public var size: CGSize?
    /// `<sizeIsSpatium>`: whether `size` is in spatium (true) or millimetres (MS `image.cpp:51-69`, default true).
    public var sizeIsSpatium: Bool
    /// `<autoScale>`: fit the box (MS default false).
    public var autoScale: Bool
    /// `<lockAspectRatio>` (MS default true).
    public var lockAspectRatio: Bool
    /// `<offset>` in spatium; `nil` is none.
    public var offsetSp: CGPoint?
    /// Source children that the typed model does not represent.
    public var preservedMarkup: [PreservedXML]

    public init(
        path: String,
        size: CGSize? = nil,
        sizeIsSpatium: Bool = true,
        autoScale: Bool = false,
        lockAspectRatio: Bool = true,
        offsetSp: CGPoint? = nil,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.path = path
        self.size = size
        self.sizeIsSpatium = sizeIsSpatium
        self.autoScale = autoScale
        self.lockAspectRatio = lockAspectRatio
        self.offsetSp = offsetSp
        self.preservedMarkup = preservedMarkup
    }
}
