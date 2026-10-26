import SheetMusicFoundation

/// A stem direction a file sets rather than leaves to the layout — MuseScore's `DirectionV` on a chord's or a beam's
/// `<StemDirection>` (`Pid::STEM_DIRECTION`), MusicXML's `<stem>`. Its absence is MuseScore's `auto`, which MuseScore
/// does not write. C++: `mu::engraving::DirectionV::UP` / `DOWN`.
public enum StemDirectionOverride: String, Sendable, Equatable, CaseIterable {
    case up
    case down

    /// The MSCX `<StemDirection>` token, which is the raw value; nil for `auto` or anything else.
    public init?(mscxValue: String) {
        self.init(rawValue: mscxValue)
    }

    public var mscxValue: String {
        rawValue
    }
}
