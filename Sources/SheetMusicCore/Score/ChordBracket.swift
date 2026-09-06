import SheetMusicFoundation

/// A vertical bracket attached to a chord.
/// C++: `mu::engraving::ChordBracket`, an `Arpeggio` subclass
/// (`dom/chordbracket.h:29`). It is read only as a direct `<Chord>` child, in
/// `TRead::readProperties(Chord*, …)` (`rw/read460/tread.cpp:2518`); a `<Rest>`
/// never carries one.
///
/// **This is a 4.7 element, not a 4.6 one.** Upstream added it on 2025-12-10
/// (`67b083e753`, "Create new ChordBracket type") and first shipped it in
/// `v4.7.0`; `v4.6.5` has zero occurrences of `ChordBracket` in its own
/// `rw/read460/tread.cpp`. The `read460` *module* gained the branch in 4.7.0,
/// and that module is what reads every file declaring 4.60–4.99
/// (`rw/rwregister.cpp:52`) — which is why the citation above is a `read460`
/// path even though 4.6 itself cannot parse the element.
///
/// The practical consequence: this package writes `version="4.60"`, so a
/// `<ChordBracket>` it emits round-trips through MuseScore 4.7+ but is dropped
/// as an unknown tag by 4.6.x. Emitting it is still right — the alternative is
/// losing it on every round trip here — but it is not lossless for a 4.6 reader.
///
/// The three bracket-specific properties are modeled. The inherited
/// `Arpeggio` tags — `<userLen1>`, `<userLen2>`, `<span>`, `<play>`, and
/// `<timeStretch>` — remain in `preservedMarkup`, matching how
/// `ChordOrnament` handles inherited `<direction>`. The shared base owns
/// `<offset>` and `<placement>` through `elementProperties`. `<subtype>` is
/// neither modeled nor emitted because
/// `TWrite::write(const ChordBracket*, …)` never writes one
/// (`rw/write/twrite.cpp:747`).
public struct ChordBracket: Sendable, Equatable {
    /// Hook length in spatium units. `<bracketHookLen>`; `nil` means absent.
    /// C++: `Pid::BRACKET_HOOK_LEN` (`dom/property.cpp:443`).
    ///
    /// It is a *styled* property: `ChordBracket` calls `initElementStyle`
    /// (`dom/chordbracket.cpp:6`) and `writeProperty` returns early while the
    /// value is still styled (`rw/write/twrite.cpp:402`), so an absent tag
    /// means "take the style default", which is `0.7` spatium
    /// (`style/styledef.cpp:607`) — not the `Spatium(1)` member initializer in
    /// `dom/chordbracket.h:52`. Reading the tag marks the property unstyled
    /// (`rw/read460/tread.cpp:525`). `nil` here is the same "no explicit value"
    /// state, so the round trip is faithful without modeling the default.
    public var hookLength: Double?
    /// Hook direction. `<bracketHookPos>`; `nil` means absent.
    /// C++: `Pid::BRACKET_HOOK_POS` (`dom/property.cpp:444`).
    public var hookPosition: HookPosition?
    /// Whether the bracket sits on the chord's right side.
    /// `<bracketRightSide>`; `nil` means absent.
    /// C++: `Pid::BRACKET_RIGHT_SIDE` (`dom/property.cpp:445`).
    public var isRightSide: Bool?
    /// Base element properties shared with every engravable element, including
    /// the spatium-unit `<offset>`.
    public var elementProperties: ElementProperties
    /// Source XML children this model does not represent — chiefly the
    /// inherited `Arpeggio` properties listed above.
    public var preservedMarkup: [PreservedXML]

    public init(
        hookLength: Double? = nil,
        hookPosition: HookPosition? = nil,
        isRightSide: Bool? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.hookLength = hookLength
        self.hookPosition = hookPosition
        self.isRightSide = isRightSide
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }

    /// Mirrors upstream `DirectionV` (`types/types.h:371-373`). A second user
    /// — stem direction being the obvious one — is the point at which to
    /// promote it to a shared type.
    public enum HookPosition: String, Sendable, CaseIterable {
        case auto, up, down
    }
}
