import SheetMusicCore

/// The identity of the engraved text a layout element draws — the one answer to "which selectable text is
/// this element", shared by the hit tester and by any renderer that has to tint it.
///
/// It lives here rather than inside `ScoreHitTester` because two consumers now need it and they must not be
/// able to disagree. The hit tester reports a target for an element; `ScoreLayerBuilder` registers that same
/// element's layers so a selection can re-tint them. If those two ran different predicates, a text could be
/// clickable and untintable (or the reverse) with nothing in either file to say so.
extension LayoutElement {
    /// This element's text identity, or `nil` when it is not addressable text.
    ///
    /// Three kinds of text are deliberately excluded, and all three are excluded by having no identity to
    /// report rather than by a special case here:
    ///
    /// * a lyric / staff text / harmony whose `anchor` is `nil` — a lane element positioned at a tick no
    ///   chord starts, which no text-entry command can address either;
    /// * an `.instrumentChange`, which shares the `.staffText` layout case (and its skyline slot) but is a
    ///   separate model element with no text-entry command — the one exclusion that has to be made by
    ///   style, since its layout case is indistinguishable;
    /// * every non-text element, including dynamics, tempo marks, measure numbers and staff names, which
    ///   are engraved text but not editable text.
    public var textID: ScoreTextID? {
        switch self {
        case let .textMark(.lyrics(_, verse, anchor), _, _):
            guard let anchor else { return nil }
            return .lyric(anchor: anchor, verse: verse)
        case let .staffText(_, _, _, style, anchor):
            guard let anchor, style == .staffText || style == .systemText else { return nil }
            return .staffText(anchor: anchor, style: style)
        case let .harmony(harmony):
            guard let anchor = harmony.anchor else { return nil }
            return .harmony(anchor: anchor)
        case let .rehearsalMark(_, _, _, _, measureIndex):
            return .rehearsalMark(measureIndex: measureIndex)
        default:
            return nil
        }
    }

    /// The selectable item a click on this element's text names — `textID` re-wrapped, so a renderer can
    /// key its layers by the same `ScoreItemID` a host will put in a `ScoreSelection`.
    public var textItemID: ScoreItemID? {
        textID.map(ScoreItemID.text)
    }
}
