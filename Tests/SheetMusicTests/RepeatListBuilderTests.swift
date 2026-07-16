import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Element-collection order and repeat-count accumulation, mirroring
/// RepeatList::collectRepeatListElements (repeatlist.cpp:425-683).
struct RepeatListBuilderTests {
    private static func facts(
        startRepeat: Bool = false,
        endRepeat: Int? = nil,
        markers: [Marker] = [],
        jumps: [Jump] = [],
        sectionBreak: Bool = false,
    ) -> ScoreNavigation.MeasureFacts {
        ScoreNavigation.MeasureFacts(
            startRepeat: startRepeat,
            endRepeatCount: endRepeat,
            sectionBreak: sectionBreak,
            markers: markers,
            jumps: jumps,
            tickSpan: 1920,
        )
    }

    @Test func plainRepeatCollectsAccumulatedStartAndEnd() {
        // [m0, m1(:|| x2)]: the implicit section-start REPEAT_START
        // accumulates the loop's total plays (1 + (2-1) = 2) at
        // collection time (repeatlist.cpp:621-625).
        let nav = ScoreNavigation(
            measures: [Self.facts(), Self.facts(endRepeat: 2)],
            voltas: [],
        )
        let sections = RepeatListBuilder.collectElements(navigation: nav)
        #expect(sections == [[
            RepeatListElement(kind: .repeatStart, measureIndex: 0, repeatCount: 2),
            RepeatListElement(kind: .repeatEnd, measureIndex: 1),
            RepeatListElement(kind: .sectionBreak, measureIndex: 1),
        ]])
    }

    @Test func markersOrderLeftThenRightThenJumps() {
        // One measure carrying (arrival order) a jump, a RIGHT marker
        // (fine), then a LEFT marker (segno). Evaluation order within
        // a measure must be bar-start (left) markers, then bar-end
        // (right) markers, then jumps (repeatlist.cpp:590-618).
        let jump = Jump(jumpTo: "start", playUntil: "fine")
        let fine = Marker(kind: .fine, label: "fine")
        let segno = Marker(kind: .segno, label: "segno")
        let nav = ScoreNavigation(
            measures: [Self.facts(markers: [fine, segno], jumps: [jump])],
            voltas: [],
        )
        let sections = RepeatListBuilder.collectElements(navigation: nav)
        #expect(sections == [[
            RepeatListElement(kind: .repeatStart, measureIndex: 0, repeatCount: 1),
            RepeatListElement(kind: .marker, measureIndex: 0, marker: segno),
            RepeatListElement(kind: .marker, measureIndex: 0, marker: fine),
            RepeatListElement(kind: .jump, measureIndex: 0, jump: jump),
            RepeatListElement(kind: .sectionBreak, measureIndex: 0),
        ]])
    }

    @Test func sectionBreakSplitsSectionsAndResetsRepeatStart() {
        // [m0(sectionBreak), m1(:||x2)] → two sections; the repeat in
        // section 2 accumulates onto section 2's implicit start.
        let nav = ScoreNavigation(
            measures: [Self.facts(sectionBreak: true), Self.facts(endRepeat: 2)],
            voltas: [],
        )
        let sections = RepeatListBuilder.collectElements(navigation: nav)
        #expect(sections == [
            [
                RepeatListElement(kind: .repeatStart, measureIndex: 0, repeatCount: 1),
                RepeatListElement(kind: .sectionBreak, measureIndex: 0),
            ],
            [
                RepeatListElement(kind: .repeatStart, measureIndex: 1, repeatCount: 2),
                RepeatListElement(kind: .repeatEnd, measureIndex: 1),
                RepeatListElement(kind: .sectionBreak, measureIndex: 1),
            ],
        ])
    }

    @Test func voltaEmitsStartAndClosedEndAroundRepeatEnd() {
        // m0 ||: m1, m2(volta1 :||x2), m3(volta2): the repeat end
        // closes volta 1 on its measure (repeatlist.cpp:621-635); the
        // closed-hook approximation closes volta 2 at its bracket end
        // (repeatlist.cpp:637-644).
        let v1 = ScoreNavigation.VoltaSpan(startMeasure: 2, endMeasure: 2, endings: [1])
        let v2 = ScoreNavigation.VoltaSpan(startMeasure: 3, endMeasure: 3, endings: [2])
        let nav = ScoreNavigation(
            measures: [
                Self.facts(),
                Self.facts(startRepeat: true),
                Self.facts(endRepeat: 2),
                Self.facts(),
            ],
            voltas: [v1, v2],
        )
        let sections = RepeatListBuilder.collectElements(navigation: nav)
        #expect(sections == [[
            RepeatListElement(kind: .repeatStart, measureIndex: 0, repeatCount: 1),
            RepeatListElement(kind: .repeatStart, measureIndex: 1, repeatCount: 2),
            RepeatListElement(kind: .voltaStart, measureIndex: 2, volta: v1),
            RepeatListElement(kind: .repeatEnd, measureIndex: 2),
            RepeatListElement(kind: .voltaEnd, measureIndex: 2, volta: v1),
            RepeatListElement(kind: .voltaStart, measureIndex: 3, volta: v2),
            RepeatListElement(kind: .voltaEnd, measureIndex: 3, volta: v2),
            RepeatListElement(kind: .sectionBreak, measureIndex: 3),
        ]])
    }

    // MARK: - findMarker

    /// Section 0: [RS(0), M(segno,1), SB(2)]
    /// Section 1: [RS(3), M(codab,4), J(5), SB(5)]
    private static func twoSections() -> [[RepeatListElement]] {
        [
            [
                RepeatListElement(kind: .repeatStart, measureIndex: 0, repeatCount: 1),
                RepeatListElement(
                    kind: .marker, measureIndex: 1,
                    marker: Marker(kind: .segno, label: "segno"),
                ),
                RepeatListElement(kind: .sectionBreak, measureIndex: 2),
            ],
            [
                RepeatListElement(kind: .repeatStart, measureIndex: 3, repeatCount: 1),
                RepeatListElement(
                    kind: .marker, measureIndex: 4,
                    marker: Marker(kind: .coda), // effectiveLabel "codab"
                ),
                RepeatListElement(
                    kind: .jump, measureIndex: 5,
                    jump: Jump(jumpTo: "segno", playUntil: "coda", continueAt: "codab"),
                ),
                RepeatListElement(kind: .sectionBreak, measureIndex: 5),
            ],
        ]
    }

    @Test func findMarkerResolvesSpecialLabels() {
        let sections = Self.twoSections()
        let reference = RepeatListPosition(section: 1, element: 2)
        #expect(RepeatListBuilder.findMarker(
            label: "start", from: reference, in: sections,
        ) == RepeatListPosition(section: 1, element: 0))
        #expect(RepeatListBuilder.findMarker(
            label: "end", from: reference, in: sections,
        ) == RepeatListPosition(section: 1, element: 3))
    }

    @Test func findMarkerSearchesBackwardInSectionFirst() {
        let sections = Self.twoSections()
        let reference = RepeatListPosition(section: 1, element: 2)
        // "codab" resolves via the marker's effectiveLabel (unlabeled
        // `.coda` defaults to "codab" — Task 3).
        #expect(RepeatListBuilder.findMarker(
            label: "codab", from: reference, in: sections,
        ) == RepeatListPosition(section: 1, element: 1))
    }

    @Test func findMarkerFallsBackToPreviousSections() {
        let sections = Self.twoSections()
        let reference = RepeatListPosition(section: 1, element: 2)
        #expect(RepeatListBuilder.findMarker(
            label: "segno", from: reference, in: sections,
        ) == RepeatListPosition(section: 0, element: 1))
    }

    @Test func findMarkerSearchesForwardThenFollowingSections() {
        let sections = Self.twoSections()
        // From section 0's marker, "codab" is only found forward in
        // the following section.
        let reference = RepeatListPosition(section: 0, element: 1)
        #expect(RepeatListBuilder.findMarker(
            label: "codab", from: reference, in: sections,
        ) == RepeatListPosition(section: 1, element: 1))
    }

    @Test func findMarkerReturnsNilForEmptyOrUnknownLabels() {
        let sections = Self.twoSections()
        let reference = RepeatListPosition(section: 1, element: 2)
        #expect(RepeatListBuilder.findMarker(
            label: "", from: reference, in: sections,
        ) == nil)
        #expect(RepeatListBuilder.findMarker(
            label: "varcoda", from: reference, in: sections,
        ) == nil)
    }
}
