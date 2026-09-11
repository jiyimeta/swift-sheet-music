import SheetMusicFoundation

/// One credit field of a score — its title, subtitle, composer, arranger, lyricist or copyright — and the value to
/// write into it.
///
/// **One write reaches two places, on purpose.** A score records a credit twice: as a `<metaTag>`, which is what a
/// properties dialog and every importer read, and (for the four that have a text style) as a `FrameText` in the
/// leading `<VBox>`, which is what is actually ENGRAVED at the top of the first page. MuseScore lets the two drift
/// — its New Score wizard writes both and nothing keeps them together afterwards — and a host that writes only one
/// of them produces exactly the confusion this type exists to remove: a title typed into a form, stored, and then
/// read back as unset, or shown in a list but missing from the page.
///
/// So `field` names the credit, not the storage, and `SetScoreInfo` writes every place that credit lives. A host
/// that genuinely wants to engrave something different from the metadata is asking a different question and wants a
/// different command.
///
/// Plural at the intent (`[ScoreInfoWrite]`) for `LyricSyllableWrite`'s reason: a form with six fields saves all six
/// at once, and one Save must be one undo step.
public struct ScoreInfoWrite: Sendable, Equatable, Hashable {
    public enum Field: String, Sendable, Equatable, Hashable, CaseIterable {
        case title
        case subtitle
        case composer
        case arranger
        case lyricist
        case copyright

        /// MuseScore's `<metaTag name="…">` key for this credit. Every field has one.
        ///
        /// `title` is the odd spelling: MuseScore stores it as `workTitle` (the MusicXML lineage), which is why the
        /// mapping is a table rather than the raw value.
        public var metaTagKey: String {
            switch self {
            case .title: "workTitle"
            case .subtitle: "subtitle"
            case .composer: "composer"
            case .arranger: "arranger"
            case .lyricist: "lyricist"
            case .copyright: "copyright"
            }
        }

        /// The engraved title-block role this credit takes, or `nil` when it has none.
        ///
        /// Arranger and copyright answer `nil` because MuseScore has no VBox text style for them — an arranger is
        /// conventionally engraved as part of the composer line, and a copyright belongs to the page footer, which
        /// reads its `<metaTag>` through a `$:copyright:` macro rather than through a frame. Writing them is
        /// therefore metadata-only, and that is not a gap to fill later.
        public var frameTextStyle: FrameText.Style? {
            switch self {
            case .title: .title
            case .subtitle: .subtitle
            case .composer: .composer
            case .lyricist: .lyricist
            case .arranger, .copyright: nil
            }
        }
    }

    public var field: Field
    /// The value to write. `nil` — or anything that trims to empty — clears the credit: the `<metaTag>` is dropped
    /// and the engraved text, if the field has one, is removed from the title frame.
    public var text: String?

    public init(field: Field, text: String?) {
        self.field = field
        self.text = text
    }

    /// The value as it will be stored: trimmed, with empty collapsed to `nil` so "cleared" has ONE representation
    /// and a restatement check cannot be fooled by trailing whitespace.
    var normalizedText: String? {
        guard let trimmed = text?.trimmingWhitespaceAndNewlines(), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
