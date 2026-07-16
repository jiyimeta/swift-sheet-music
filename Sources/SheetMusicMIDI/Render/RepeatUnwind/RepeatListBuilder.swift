import Foundation
import SheetMusicCore

/// Builds the per-section ordered navigation element lists from a
/// `ScoreNavigation`. Swift reimplementation — studied from, not
/// copied from — `RepeatList::collectRepeatListElements`
/// (repeatlist.cpp:425-683).
///
/// Documented approximations vs. the C++:
/// - All voltas are treated as CLOSED-hook (`END_HOOK_TYPE != NONE`);
///   the open-volta edge cases (MuseScore repeat40-42/67) are a
///   noted follow-up.
/// - Overlapping voltas are not split/merged (repeatlist.cpp:453-521);
///   identical cross-staff duplicates are already deduplicated by
///   `ScoreNavigation`.
enum RepeatListBuilder {
    /// One ordered element list per section (sections are runs of
    /// measures separated by section breaks). Every section starts
    /// with an implicit `.repeatStart` (repeatlist.cpp:440-443) and
    /// ends with a `.sectionBreak` (repeatlist.cpp:646-681).
    static func collectElements(navigation: ScoreNavigation) -> [[RepeatListElement]] {
        var collector = Collector(navigation: navigation)
        return collector.collect()
    }

    private struct Collector {
        let navigation: ScoreNavigation
        var sections: [[RepeatListElement]] = []
        var section: [RepeatListElement] = []
        /// Index into `section` of the loop-start reference the next
        /// `.repeatEnd` accumulates onto.
        var startRepeatIndex = 0
        /// Voltas not yet reached, sorted by `startMeasure`.
        var pendingVoltas: [ScoreNavigation.VoltaSpan]
        var activeVolta: ScoreNavigation.VoltaSpan?

        init(navigation: ScoreNavigation) {
            self.navigation = navigation
            pendingVoltas = navigation.voltas
        }

        mutating func collect() -> [[RepeatListElement]] {
            guard !navigation.measures.isEmpty else { return [] }
            section = [RepeatListElement(
                kind: .repeatStart, measureIndex: 0, repeatCount: 1,
            )]
            startRepeatIndex = 0
            for measureIndex in 0 ..< navigation.measures.count {
                collectMeasure(measureIndex)
            }
            return sections
        }

        private mutating func collectMeasure(_ mi: Int) {
            let facts = navigation.measures[mi]
            beginVolta(at: mi)
            if facts.startRepeat {
                appendRepeatStart(at: mi)
            }
            for jump in facts.jumps {
                section.append(RepeatListElement(
                    kind: .jump, measureIndex: mi, jump: jump,
                ))
            }
            for marker in facts.markers {
                insertMarker(marker, at: mi)
            }
            if let plays = facts.endRepeatCount {
                appendRepeatEnd(at: mi, plays: plays)
            }
            endClosedVolta(at: mi)
            if facts.sectionBreak || mi == navigation.measures.count - 1 {
                closeSection(at: mi)
            }
        }

        /// Volta start (repeatlist.cpp:529-544). A volta starting
        /// while another is open closes the previous one on the
        /// preceding measure (open-volta recovery).
        private mutating func beginVolta(at mi: Int) {
            guard let next = pendingVoltas.first, next.startMeasure == mi else { return }
            if let open = activeVolta {
                section.append(RepeatListElement(
                    kind: .voltaEnd, measureIndex: max(0, mi - 1), volta: open,
                ))
            }
            activeVolta = next
            section.append(RepeatListElement(
                kind: .voltaStart, measureIndex: mi, volta: next,
            ))
            pendingVoltas.removeFirst()
        }

        /// Repeat start (repeatlist.cpp:546-561). A start repeat
        /// inside a volta closes it on the preceding measure; a volta
        /// starting ON the repeat measure stays open (repeat56).
        private mutating func appendRepeatStart(at mi: Int) {
            if let open = activeVolta, open.startMeasure != mi {
                section.append(RepeatListElement(
                    kind: .voltaEnd, measureIndex: max(0, mi - 1), volta: open,
                ))
                activeVolta = nil
            }
            section.append(RepeatListElement(
                kind: .repeatStart, measureIndex: mi, repeatCount: 1,
            ))
            startRepeatIndex = section.count - 1
        }

        /// Marker insertion (repeatlist.cpp:590-618): within one
        /// measure, bar-start (left) markers order before bar-end
        /// (right) markers, and every marker before any jump. The
        /// backward scan always stops at or before the measure's
        /// first element because each section starts with a
        /// `.repeatStart`.
        private mutating func insertMarker(_ marker: Marker, at mi: Int) {
            var insertionIndex = section.count - 1
            let markerIsRight = marker.isRightMarker
            while section[insertionIndex].measureIndex == mi {
                var markerShouldGoBefore = false
                if section[insertionIndex].kind == .marker, !markerIsRight,
                   let stored = section[insertionIndex].marker
                {
                    markerShouldGoBefore = stored.isRightMarker
                }
                if markerShouldGoBefore || section[insertionIndex].kind == .jump {
                    insertionIndex -= 1
                } else {
                    break
                }
            }
            section.insert(
                RepeatListElement(kind: .marker, measureIndex: mi, marker: marker),
                at: insertionIndex + 1,
            )
        }

        /// Repeat end (repeatlist.cpp:621-635): accumulate total
        /// plays onto the current loop start; a repeat end always
        /// closes the active volta.
        private mutating func appendRepeatEnd(at mi: Int, plays: Int) {
            section.append(RepeatListElement(kind: .repeatEnd, measureIndex: mi))
            section[startRepeatIndex].repeatCount += plays - 1
            if let open = activeVolta {
                section.append(RepeatListElement(
                    kind: .voltaEnd, measureIndex: mi, volta: open,
                ))
                activeVolta = nil
            }
        }

        /// Closed-volta end (repeatlist.cpp:637-644). All voltas are
        /// approximated as closed-hook, so a bracket ending on this
        /// measure always closes here.
        private mutating func endClosedVolta(at mi: Int) {
            guard let open = activeVolta, open.endMeasure == mi else { return }
            section.append(RepeatListElement(
                kind: .voltaEnd, measureIndex: mi, volta: open,
            ))
            activeVolta = nil
        }

        /// Section break / end of score (repeatlist.cpp:646-681).
        private mutating func closeSection(at mi: Int) {
            if let open = activeVolta {
                section.append(RepeatListElement(
                    kind: .voltaEnd, measureIndex: mi, volta: open,
                ))
                activeVolta = nil
            }
            section.append(RepeatListElement(kind: .sectionBreak, measureIndex: mi))
            sections.append(section)
            if mi < navigation.measures.count - 1 {
                section = [RepeatListElement(
                    kind: .repeatStart, measureIndex: mi + 1, repeatCount: 1,
                )]
                startRepeatIndex = 0
            }
        }
    }
}
