import SheetMusicFoundation

/// A score-level MuseScore box carried in document order among measures.
///
/// `<VBox>`, `<TBox>` and `<HBox>` are typed because the layout engine lays them out: the leading `<VBox>` is the title
/// block, a later `<VBox>` or `<TBox>` is a frame between systems, and an `<HBox>` is horizontal room between two
/// measures. `<FBox>` (a fret-diagram table) has no consumer in this library and is carried whole for source fidelity.
public enum ScoreBlock: Sendable, Equatable {
    /// `<VBox>` — the title block when it leads the score, otherwise a frame between systems.
    case verticalFrame(ScoreFrame)
    /// `<TBox>` — a frame holding one text (MS `boxlayout.cpp:337-362`).
    case textFrame(TextFrame)
    /// `<HBox>` — horizontal room between two measures (MS `box.cpp:593-603`).
    case horizontalFrame(HorizontalFrame)
    /// `<FBox>` (and, for source compatibility, an `OpaqueFrame` of any kind) — carried whole for source fidelity.
    case opaqueFrame(OpaqueFrame)
}

/// A box whose fields have no semantic consumer in this library.
public struct OpaqueFrame: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        case horizontal = "HBox"
        case text = "TBox"
        case fret = "FBox"
    }

    public var kind: Kind
    /// Every child of the element, verbatim. This is fidelity, not semantics:
    /// layout, playback, and editing do not inspect it.
    public var preservedMarkup: [PreservedXML]

    public init(kind: Kind, preservedMarkup: [PreservedXML] = []) {
        self.kind = kind
        self.preservedMarkup = preservedMarkup
    }
}

/// A score-level box positioned relative to the measure stream.
public struct PositionedScoreBlock: Sendable, Equatable {
    /// This block sits immediately before the measure at this index. It equals
    /// the measure count when the block trails every measure.
    ///
    /// A "before" index keeps measure deletion simple: deleting measure `n`
    /// decrements every block index greater than `n`, and a leading block needs
    /// no sentinel value.
    public var beforeMeasureIndex: Int
    public var block: ScoreBlock

    public init(beforeMeasureIndex: Int, block: ScoreBlock) {
        self.beforeMeasureIndex = beforeMeasureIndex
        self.block = block
    }
}
