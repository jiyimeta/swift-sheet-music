import SheetMusicFoundation

/// A SMuFL engraving symbol attached directly to a note or segment.
/// C++: `mu::engraving::Symbol`. MuseScore 4.6 reads it with
/// `TRead::read(Symbol*, …)` (`rw/read460/tread.cpp:2364`) and dispatches the
/// note-attached form from `TRead::readProperties(Note*, …)` (`:3359`).
/// `TWrite::write(const Symbol*, …)` is shared by every parent
/// (`rw/write/twrite.cpp:3221`).
///
/// `<Symbol>` has many parents in the 4.6 reader. This type models the
/// note-attached form under `<Note>` (`rw/read460/tread.cpp:3359`) and the
/// segment-annotation form in `VoiceElement.symbol`
/// (`rw/read460/measureread.cpp:465`). The annotation branch always chooses a
/// ChordRest segment, unlike the shared annotation branch further down that can
/// choose a time-tick segment through `allowTimeAnchor()`; both add the element
/// to the selected segment. The remaining parents are `<BarLine>` (`:2053`,
/// inside `read(BarLine*)` at `:2032`), the box family — `HBox` / `VBox` /
/// `TBox` / `FBox` — (`:2203`, inside `readProperties(Box*)` at `:2166`),
/// `<MMRest>` (`:3236`), and the `BSymbol` branch at `:2342`, which puts a
/// `<Symbol>` inside another `<Symbol>` (`:2389`), inside an `<FSymbol>`, or
/// inside an `<Image>`. Clipboard paste reaches it too (`read460.cpp:689`).
///
/// It is never a `<Chord>` child: neither `TRead::readProperties(Chord*, …)`
/// (`rw/read460/tread.cpp:2458`) nor the `ChordRest` overload (`:2574`) has a
/// `Symbol` branch.
///
/// `name` deliberately stays a plain `String`, not a closed enum with an
/// `.unknown` case. MuseScore's `SymId` registry is roughly 2,600 open-ended
/// SMuFL glyph names and this package models no `SymId` type at all. This is a
/// conscious departure from the `ChordOrnament.Kind` and `Fingering.Role`
/// precedent rather than an oversight.
///
/// An unknown or future `name` round-trips verbatim. Upstream resolves it
/// through `SymNames::symIdByName`, then the translated user names, then
/// `SymId::noSym` with a log line (`tread.cpp:2370`, `types/symnames.cpp:50`) —
/// so keeping the raw string preserves *more* than MuseScore's own re-save,
/// which would write the resolved `noSym` back.
///
/// `<FSymbol>` is not a note child and is out of scope. In the 4.6 reader it
/// appears only through `TRead::readProperties(BSymbol*, …)`
/// (`tread.cpp:2346`) — nested inside a `<Symbol>`, an `<FSymbol>`, or an
/// `<Image>` — so it remains preserved markup with every other unmodeled child.
/// The shared base owns `<offset>` and `<placement>` through
/// `elementProperties`.
public struct EngravingSymbol: Sendable, Equatable {
    /// The SMuFL SymId name. `<name>`; an absent or empty tag decodes as `""`.
    public var name: String
    /// The score font name. `<font>`; `nil` means the tag was absent.
    public var scoreFont: String?
    /// Glyph scale. `<symbolsSize>`; `nil` means the tag was absent.
    public var size: Double?
    /// Glyph rotation in degrees. `<symbolAngle>`; `nil` means the tag was absent.
    public var angle: Double?
    /// Base element properties shared with every engravable element, including
    /// the spatium-unit `<offset>`.
    public var elementProperties: ElementProperties
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source XML children this model does not represent, including nested
    /// `<Symbol>`, `<Image>`, and `<FSymbol>` subtrees.
    public var preservedMarkup: [PreservedXML]

    public init(
        name: String,
        scoreFont: String? = nil,
        size: Double? = nil,
        angle: Double? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.name = name
        self.scoreFont = scoreFont
        self.size = size
        self.angle = angle
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }
}
