import SheetMusicFoundation

/// A part by position in `Score.parts`. Member of the closed reference family; see `MeasureRef`.
public struct PartRef: Hashable, Sendable {
    public var partIndex: Int

    public init(partIndex: Int) {
        self.partIndex = partIndex
    }
}
