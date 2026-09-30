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
        // No annotation of `kind` exists yet, and the one typed below is written plain: no element properties, no
        // font.
        let before = try #require(empty.textEntryOrigin(
            kind: kind,
            at: anchor,
            text: "",
            placementStyle: score.style.textPlacement,
            elementProperties: .default,
            textProperties: TextProperties(),
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
            elementProperties: .default,
            textProperties: TextProperties(),
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
            #expect(abs(before.y - oldStaffY - defaultBaselineOffset(kind, metrics: empty.metrics)) < 0.001)
            #expect(before.y < oldStaffY)
            #expect(after.y < newStaffY)
        }
    }

    /// Where a blank annotation of `kind` puts its baseline above the staff top under the default style: the role's
    /// offset in sp, then a descent shift (half the ascent above the descent for chord symbols, which centre).
    private func defaultBaselineOffset(_ kind: TextInputPlanner.Kind, metrics: StaffMetrics) -> CGFloat {
        let role: TextStyleType
        let baselineSp: CGFloat
        switch kind {
        case .staffText: (role, baselineSp) = (.staffText, -1)
        case .systemText: (role, baselineSp) = (.systemText, -2)
        case .chordSymbol: (role, baselineSp) = (.chordSymbolA, -2.5)
        case .rehearsalMark: (role, baselineSp) = (.rehearsalMark, -2)
        }
        let font = TextInkGeometry.font(for: role, metrics: metrics)
        let provider = FontMetrics.provider
        let shift = kind == .chordSymbol
            ? -(provider.ascent(font: font) - provider.descent(font: font)) / 2
            : provider.descent(font: font)
        return baselineSp * metrics.sp + shift
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
        // No syllable yet, and the one written below is a plain `Lyric(text:)`: no element properties, no font.
        let before = try #require(empty.lyricEntryOrigin(
            at: .init(location: displayed, verse: 0),
            placementStyle: score.style.textPlacement,
            elementProperties: .default,
            textProperties: TextProperties(),
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
            elementProperties: .default,
            textProperties: TextProperties(),
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
            elementProperties: .default,
            textProperties: TextProperties(),
        ) == nil)
    }

    @Test func authoredOffsetUsesExactGlyphAnchor() throws {
        let score = TextPlacementFixtures.score(
            role: .lyrics,
            side: .above,
            autoplace: false,
            offset: ScoreOffset(x: 3, y: -2),
        )
        let document = TextPlacementFixtures.layout(score)
        let mark = try #require(TextPlacementFixtures.mark(document))
        let system = try #require(document.systems.first)
        let measure = try #require(system.measures.first)
        let anchor = VoiceElementID(
            staff: TextPlacementFixtures.address,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
        )
        let cursor = LyricInputPlanner.Cursor(location: anchor, verse: 0)
        let syllable = LyricInputPlanner.lyric(at: cursor, in: score)
        let result = try #require(document.lyricEntryOrigin(
            at: cursor,
            placementStyle: score.style.textPlacement,
            elementProperties: syllable?.elementProperties ?? .default,
            textProperties: syllable?.properties ?? TextProperties(),
        ))
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
        let textID = ScoreTextID.staffText(anchor: anchor, style: .staffText)
        let properties = try #require(SetElementPlacement.currentProperties(for: .text(textID), in: committed))
        let font = SetTextFont.current(textID, in: committed) ?? TextProperties()
        var emptyScore = committed
        _ = try TextInputPlanner.command(.staffText, at: anchor, text: nil).apply(to: &emptyScore)
        let empty = TextPlacementFixtures.layout(emptyScore)
        let before = try #require(empty.textEntryOrigin(
            kind: .staffText,
            at: anchor,
            text: "",
            placementStyle: committed.style.textPlacement,
            elementProperties: properties,
            textProperties: font,
        ))
        var typed = committed
        _ = try TextInputPlanner.command(.staffText, at: anchor, text: "A").apply(to: &typed)
        let document = TextPlacementFixtures.layout(typed)
        let after = try #require(document.textEntryOrigin(
            kind: .staffText,
            at: anchor,
            text: "A",
            placementStyle: committed.style.textPlacement,
            elementProperties: properties,
            textProperties: font,
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
