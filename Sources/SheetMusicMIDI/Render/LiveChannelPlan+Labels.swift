import SheetMusicCore
import SheetMusicFoundation

extension LiveChannelPlan {
    /// What a host calls a strip.
    ///
    /// Three values rather than one string, because a mixer laid out in groups needs the halves separately: the
    /// part titles the group and the instrument labels the row inside it. Re-splitting `displayName` on its
    /// parentheses would make every host depend on this type's formatting, and would fail on the parts that are
    /// deliberately given no suffix.
    public struct StripLabels: Sendable, Equatable {
        /// The part the strip belongs to — `Score.staffDisplayName` of its first staff, which is what the score
        /// calls that line of music.
        public let partName: String
        /// The instrument driving the strip, unqualified by the part — MuseScore's `<trackName>`, which is the name
        /// it shows in its own mixer. Always reported, even when `displayName` suppresses it: what a host chooses to
        /// draw is not this type's business.
        public let instrumentName: String
        /// The two composed into one self-sufficient label, for a host that draws a flat list.
        public let displayName: String

        public init(partName: String, instrumentName: String, displayName: String) {
            self.partName = partName
            self.instrumentName = instrumentName
            self.displayName = displayName
        }
    }

    /// Labels for one strip. `"Guitar"` when the part has a single instrument, `"Guitar (Banjo)"` when it has
    /// several and this one is genuinely a different instrument.
    ///
    /// Two guards keep the composed form from stuttering:
    ///
    /// - the suffix is gated on the count of DEDUPED strips for the part (`strips`, filtered by `partIndex`), not
    ///   on `Score.instrumentTimeline(forPart:).count` — a part whose two timeline entries collapse onto one live
    ///   channel is one strip, and must read as one instrument however many times the score announced it;
    /// - an instrument whose name equals the part's is suppressed, so a part named after its own instrument reads
    ///   "Piano" rather than "Piano (Piano)".
    ///
    /// The instrument name reads `<trackName>` BEFORE `<longName>`, which is the opposite of what a part label wants
    /// and is the point. MuseScore prints `longName` at the left of the staff: it is the PART's label, and an
    /// arranger routinely sets it to the voice — "Soprano 1", or just "S" — while `trackName` keeps the instrument
    /// ("ボーカル", "ピアノ"). Reading `longName` first therefore answered "which instrument drives this strip" with
    /// the part's own name; that then equalled `partName`, the suffix was suppressed as a stutter, and a part which
    /// genuinely changed instrument showed a row that never said what it was.
    public func labels(for strip: Strip, in score: Score) -> StripLabels {
        let partName = score.staffDisplayName(
            at: StaffAddress(partIndex: strip.partIndex, staffIndexInPart: 0),
        )
        let instrumentName = [strip.instrument.trackName, strip.instrument.longName]
            .compactMap(\.self)
            .first { !$0.isEmpty }
            ?? strip.instrument.id
        let distinctStripsForPart = strips.count { $0.partIndex == strip.partIndex }
        let showsSuffix = distinctStripsForPart > 1
            && !instrumentName.isEmpty
            && instrumentName != partName
        return StripLabels(
            partName: partName,
            instrumentName: instrumentName,
            displayName: showsSuffix ? "\(partName) (\(instrumentName))" : partName,
        )
    }
}
