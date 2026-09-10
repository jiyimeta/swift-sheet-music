import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

@Suite("Text placement empty caret")
struct TextPlacementCaretTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test(arguments: TextInputPlanner.Kind.allCases, [false, true])
    func blankAnnotationUsesBaselineAndFirstCharacterKeepsSide(kind: TextInputPlanner.Kind, customBelow: Bool) throws {
        var score = TextPlacementFixtures.score(role: .lyrics, text: "")
        var ids = EIDAllocator()
        score.assignMissingIDs(using: &ids)
        if customBelow {
            for role in [TextPlacementRole.staffText, .systemText, .rehearsalMark, .harmonyA] {
                score.style.textPlacement[role] = TextPlacementStyle(
                    placement: .below,
                    positionBelow: ScoreOffset(x: 2, y: 7),
                )
            }
        }
        let anchor = VoiceElementID(
            staff: TextPlacementFixtures.address, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
        let empty = TextPlacementFixtures.layout(score)
        let before = try #require(empty.textEntryOrigin(
            kind: kind,
            at: anchor,
            text: "",
            placementStyle: score.style.textPlacement,
        ))
        var preview = score
        _ = try TextInputPlanner.command(kind, at: anchor, text: "A").apply(to: &preview)
        let mapping = ScoreEditingAddressMap(score: score, hiddenStaves: [], previewScore: preview)
        let mapped = try #require(mapping.displayedItem(forFull: .text(.harmony(anchor: anchor)))?.textID?.anchor)
        let pending = TextPlacementFixtures.layout(preview)
        let after = try #require(pending.textEntryOrigin(
            kind: kind,
            at: mapped,
            text: "A",
            placementStyle: score.style.textPlacement,
        ))
        let oldSystem = try #require(empty.systems.first)
        let newSystem = try #require(pending.systems.first)
        let oldStaffY = oldSystem.origin.y + (oldSystem.staffOrigins.first?.y ?? 0)
        let newStaffY = newSystem.origin.y + (newSystem.staffOrigins.first?.y ?? 0)
        if kind != .chordSymbol { #expect(abs(before.x - after.x) < 0.001) }
        if customBelow {
            #expect(abs((before.y - oldStaffY) - (after.y - newStaffY)) < 0.001)
            #expect(before.y > oldStaffY + 4 * empty.metrics.sp)
            #expect(after.y > newStaffY + 4 * pending.metrics.sp)
        } else {
            let role: TextStyleType
            let baselineSp: CGFloat
            switch kind {
            case .staffText: (role, baselineSp) = (.staffText, -1)
            case .systemText: (role, baselineSp) = (.systemText, -2)
            case .chordSymbol: (role, baselineSp) = (.chordSymbolA, -2.5)
            case .rehearsalMark: (role, baselineSp) = (.rehearsalMark, -2)
            }
            let font = TextInkGeometry.font(for: role, metrics: empty.metrics)
            let provider = FontMetrics.provider
            let shift = kind == .chordSymbol
                ? -(provider.ascent(font: font) - provider.descent(font: font)) / 2
                : provider.descent(font: font)
            #expect(abs(before.y - oldStaffY - baselineSp * empty.metrics.sp - shift) < 0.001)
            #expect(before.y < oldStaffY)
            #expect(after.y < newStaffY)
        }
    }

    @Test func styledEmptyCaretAndFirstCharacterStayAboveOnFilteredStaff() throws {
        let staff = Staff(measures: [Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 71, tpc: 19)]))),
        ])])])
        var score = Score(division: 480, parts: [
            Part(id: "hidden", instrument: Instrument(id: "a"), staves: [staff]),
            Part(id: "visible", instrument: Instrument(id: "b"), staves: [staff, staff]),
        ])
        score.style.textPlacement[.lyrics] = TextPlacementStyle(
            placement: .above,
            positionAbove: ScoreOffset(x: 2, y: -6),
        )
        let hidden: Set<StaffAddress> = [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
        ]
        let full = VoiceElementID(
            staff: StaffAddress(partIndex: 1, staffIndexInPart: 1),
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
        )
        let map = ScoreEditingAddressMap(score: score, hiddenStaves: hidden)
        let displayed = try #require(map.displayedItem(forFull: .text(.lyric(anchor: full, verse: 0)))?.textID?.anchor)
        #expect(displayed.staff == TextPlacementFixtures.address)
        let empty = TextPlacementFixtures.layout(score.filtered(hidingStaves: hidden))
        let before = try #require(empty.lyricEntryOrigin(
            at: .init(location: displayed, verse: 0),
            placementStyle: score.style.textPlacement,
        ))
        score.parts.updateValue(at: 1) { part in
            part.staves.updateValue(at: 1) { staff in
                staff.measures[0].voices[0].elements.updateValue(at: 0) { element in
                    guard case var .chord(chord) = element else { return }
                    chord.lyrics = [Lyric(text: "A")]
                    element = .chord(chord)
                }
            }
        }
        let pending = TextPlacementFixtures.layout(score.filtered(hidingStaves: hidden))
        let after = try #require(pending.lyricEntryOrigin(
            at: .init(location: displayed, verse: 0),
            placementStyle: score.style.textPlacement,
        ))
        let oldStaffY = try #require(empty.systems.first).origin.y + (empty.systems.first?.staffOrigins.first?.y ?? 0)
        let newStaffY = try #require(pending.systems.first).origin
            .y + (pending.systems.first?.staffOrigins.first?.y ?? 0)
        #expect(before.y < oldStaffY)
        #expect(after.y < newStaffY)
        #expect(abs((before.y - oldStaffY) - (after.y - newStaffY)) < 0.001)
        #expect(abs(before.x - after.x) < 0.001)
        #expect(pending.lyricEntryOrigin(
            at: .init(location: full, verse: 0),
            placementStyle: score.style.textPlacement,
        ) == nil)
    }

    @Test func authoredOffsetUsesExactGlyphAnchor() throws {
        let document = TextPlacementFixtures.layout(TextPlacementFixtures.score(
            role: .lyrics,
            side: .above,
            autoplace: false,
            offset: ScoreOffset(x: 3, y: -2),
        ))
        let mark = try #require(TextPlacementFixtures.mark(document))
        let system = try #require(document.systems.first)
        let measure = try #require(system.measures.first)
        let anchor = VoiceElementID(
            staff: TextPlacementFixtures.address,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
        )
        let result = try #require(document.lyricEntryOrigin(at: .init(location: anchor, verse: 0)))
        let origin = TextPlacementFixtures.origin(mark)
        #expect(result.x == system.origin.x + measure.origin.x + origin.x)
        #expect(result.y == system.origin.y + measure.origin.y + origin.y)
    }

    @Test func blankExistingAnnotationRetainsAuthoredPlacementAndOffset() throws {
        var committed = TextPlacementFixtures.score(
            role: .staffText,
            side: .below,
            autoplace: false,
            offset: ScoreOffset(x: 3, y: 2),
        )
        var ids = EIDAllocator()
        committed.assignMissingIDs(using: &ids)
        let anchor = VoiceElementID(
            staff: TextPlacementFixtures.address,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
        )
        let properties = try #require(SetElementPlacement.currentProperties(
            for: .text(.staffText(anchor: anchor, style: .staffText)), in: committed,
        ))
        var emptyScore = committed
        _ = try TextInputPlanner.command(.staffText, at: anchor, text: nil).apply(to: &emptyScore)
        let empty = TextPlacementFixtures.layout(emptyScore)
        let before = try #require(empty.textEntryOrigin(
            kind: .staffText,
            at: anchor,
            text: "",
            elementProperties: properties,
        ))
        var typed = committed
        _ = try TextInputPlanner.command(.staffText, at: anchor, text: "A").apply(to: &typed)
        let document = TextPlacementFixtures.layout(typed)
        let after = try #require(document.textEntryOrigin(
            kind: .staffText,
            at: anchor,
            text: "A",
            elementProperties: properties,
        ))
        let firstSystem = try #require(empty.systems.first)
        let lastSystem = try #require(document.systems.first)
        let firstStaffY = firstSystem.origin.y + (firstSystem.staffOrigins.first?.y ?? 0)
        let lastStaffY = lastSystem.origin.y + (lastSystem.staffOrigins.first?.y ?? 0)
        #expect(abs(before.x - after.x) < 0.001)
        #expect(abs(before.y - firstStaffY - (after.y - lastStaffY)) < 0.001)
        #expect(before.y > firstStaffY + 28)
    }
}
