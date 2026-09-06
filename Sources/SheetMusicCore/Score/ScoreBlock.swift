import SheetMusicFoundation

/// A score-level MuseScore box carried in document order among measures.
///
/// The cases are deliberately asymmetric. `<VBox>` is modeled because
/// `LayoutEngine` renders the title block from its `ScoreFrame`; `<HBox>`,
/// `<TBox>`, and `<FBox>` are not laid out anywhere in this library, so typing
/// their fields would add semantics that no consumer uses. A future slice that
/// teaches the layout engine about those boxes is what would justify modeling
/// their properties.
public enum ScoreBlock: Sendable, Equatable {
    /// `<VBox>` — modeled because the layout engine draws the title block from it.
    case verticalFrame(ScoreFrame)
    /// `<HBox>` / `<TBox>` / `<FBox>` — carried whole for source fidelity.
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
