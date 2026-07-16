import Foundation
import SheetMusicCore

/// One navigation-relevant event in a section's ordered element list.
/// Swift analog of MuseScore's `RepeatListElement`
/// (repeatlist.cpp:383-419). Value type: the unwinder mutates
/// `repeatCount` in place.
struct RepeatListElement: Equatable {
    enum Kind: Equatable {
        case sectionBreak
        case voltaStart
        case voltaEnd
        case repeatStart
        case repeatEnd
        case jump
        case marker
    }

    var kind: Kind
    /// Measure the element lives on (for `.voltaEnd`: the measure the
    /// bracket ends on; for `.sectionBreak`: the section's last
    /// measure).
    var measureIndex: Int
    /// `.repeatStart`: total plays of the loop it anchors
    /// (1 + Σ(endRepeat−1)), accumulated at collection time.
    /// `.repeatEnd`: times the unwinder has passed this barline
    /// (starts 0, incremented / re-armed during unwinding).
    /// Other kinds: 0 — including a `.marker` used as a continueAt
    /// loop-start reference (its `getRepeatCount() == 0` is
    /// load-bearing in the C++ too).
    var repeatCount = 0
    var marker: Marker?
    var jump: Jump?
    var volta: ScoreNavigation.VoltaSpan?
}

/// Position of an element inside the per-section element lists.
struct RepeatListPosition: Equatable, Hashable {
    var section: Int
    var element: Int
}
