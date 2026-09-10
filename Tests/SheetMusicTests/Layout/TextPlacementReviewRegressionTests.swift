import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

@Suite("Text placement review regressions")
struct TextPlacementReviewRegressionTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private let staff = TextPlacementFixtures.address

    @Test(arguments: [Placement.above, .below], [false, true])
    func emptyLyricKeepsOwnOffsetWithoutBorrowingNeighborCorrection(side: Placement, autoplace: Bool) throws {
        var own = Lyric(text: "A")
        own.elementProperties = ElementProperties(
            offset: ScoreOffset(x: 3, y: 2),
            placement: side,
            autoplace: autoplace,
        )
        own.properties = TextProperties(face: "Edwin", size: 33, style: [.italic])
        var neighbor = Lyric(text: "Ag\nAg")
        neighbor.elementProperties = ElementProperties(offset: ScoreOffset(x: 0, y: 4), placement: side)
        var score = makeScore([[
            chord(pitch: 71, lyrics: [own]), chord(pitch: 71, lyrics: [neighbor]),
        ]])
        score.style.textPlacement[.lyrics] = TextPlacementStyle(
            positionAbove: ScoreOffset(x: 0, y: -15), positionBelow: ScoreOffset(x: 0, y: 15),
        )
        let cursor = LyricInputPlanner.Cursor(location: anchor(measure: 0, element: 0), verse: 0)
        let filled = TextPlacementFixtures.layout(score)
        let before = try #require(filled.lyricEntryOrigin(at: cursor))
        var preview = score
        let deletion = try #require(LyricInputPlanner.plan(typing: "", terminatedBy: .none, at: cursor, in: score)
            .command)
        _ = try deletion.apply(to: &preview)
        let empty = TextPlacementFixtures.layout(preview)
        let after = try #require(empty.lyricEntryOrigin(
            at: cursor, placementStyle: score.style.textPlacement, elementProperties: own.elementProperties,
        ))
        #expect(abs(before.x - after.x) < 0.001)
        #expect(abs(relativeY(before, in: filled) - relativeY(after, in: empty)) < 0.001)
        var typed = score
        let replacement = try #require(LyricInputPlanner.plan(typing: "B", terminatedBy: .none, at: cursor, in: score)
            .command)
        _ = try replacement.apply(to: &typed)
        let restored = try #require(LyricInputPlanner.lyric(at: cursor, in: typed))
        #expect(restored.elementProperties == own.elementProperties)
        #expect(restored.properties == own.properties)
    }

    @Test(arguments: [Placement.above, .below])
    func nonoverlappingRowsKeepVerseOrderAfterInnerStemPush(side: Placement) throws {
        let innerVerse = side == .above ? 2 : 0
        let outerVerse = side == .above ? 0 : 2
        let document = TextPlacementFixtures.layout(makeScore([
            [extremeChord(side: side, lyrics: lyrics(verse: innerVerse, side: side))],
            [chord(pitch: 71, lyrics: lyrics(verse: outerVerse, side: side))],
        ]))
        #expect(document.systems.count == 1)
        let elements = document.systems.flatMap(\.measures).flatMap(\.elements)
        let inner = try #require(elements.first { $0.textPlacement?.verse == innerVerse })
        let outer = try #require(elements.first { $0.textPlacement?.verse == outerVerse })
        let innerBox = try #require(TextInkGeometry.rects(for: inner, metrics: document.metrics)?.first)
        let outerBox = try #require(TextInkGeometry.rects(for: outer, metrics: document.metrics)?.first)
        let measures = document.systems[0].measures
        #expect(innerBox.maxX + measures[0].origin.x < outerBox.minX + measures[1].origin.x)
        if side == .above {
            #expect(innerBox.minY - outerBox.maxY >= 1.75 - 0.001)
        } else {
            #expect(outerBox.minY - innerBox.maxY >= 1.75 - 0.001)
        }
    }

    @Test(arguments: [Placement.above, .below])
    func fixedInnerRowConstrainsDistantMovableOuterRow(side: Placement) throws {
        let innerVerse = side == .above ? 2 : 0
        let outerVerse = side == .above ? 0 : 2
        let offset = side == .above ? -12.0 : 12.0
        let document = TextPlacementFixtures.layout(makeScore([
            [chord(pitch: 71, lyrics: lyrics(verse: innerVerse, side: side, autoplace: false, offset: offset))],
            [chord(pitch: 71, lyrics: lyrics(verse: outerVerse, side: side))],
        ]))
        let elements = document.systems.flatMap(\.measures).flatMap(\.elements)
        let inner = try #require(elements.first { $0.textPlacement?.verse == innerVerse })
        let outer = try #require(elements.first { $0.textPlacement?.verse == outerVerse })
        let system = try #require(document.systems.first)
        let innerOrigin = TextPlacementFixtures.origin(inner)
        let base: CGFloat = side == .above ? -2 : 7
        let font = TextInkGeometry.font(for: .lyricsOdd, metrics: document.metrics)
        let centerOffset = (FontMetrics.provider.ascent(font: font) - FontMetrics.provider.descent(font: font)) / 2
        #expect(abs(innerOrigin.y - (system.staffOrigins.first?.y ?? 0) - (base + offset) * 7 + centerOffset) < 0.001)
        if side == .above {
            #expect(TextPlacementFixtures.origin(outer).y < innerOrigin.y)
        } else {
            #expect(TextPlacementFixtures.origin(outer).y > innerOrigin.y)
        }
    }

    @Test(arguments: [Placement.above, .below])
    func fixedOuterRowKeepsAuthoredPositionWhenInnerRowMustPassIt(side: Placement) throws {
        let innerVerse = side == .above ? 2 : 0
        let outerVerse = side == .above ? 0 : 2
        let document = TextPlacementFixtures.layout(makeScore([
            [extremeChord(side: side, lyrics: lyrics(verse: innerVerse, side: side))],
            [chord(pitch: 71, lyrics: lyrics(verse: outerVerse, side: side, autoplace: false))],
        ]))
        let system = try #require(document.systems.first)
        let elements = system.measures.flatMap(\.elements)
        let inner = try #require(elements.first { $0.textPlacement?.verse == innerVerse })
        let outer = try #require(elements.first { $0.textPlacement?.verse == outerVerse })
        let y = TextPlacementFixtures.origin(outer).y - (system.staffOrigins.first?.y ?? 0)
        let baseline: CGFloat = side == .above ? -37.8 : 72.8
        let font = TextInkGeometry.font(for: .lyricsOdd, metrics: document.metrics)
        let centerOffset = (FontMetrics.provider.ascent(font: font) - FontMetrics.provider.descent(font: font)) / 2
        #expect(abs(y - baseline + centerOffset) < 0.001)
        if side == .above {
            #expect(TextPlacementFixtures.origin(inner).y < TextPlacementFixtures.origin(outer).y)
        } else {
            #expect(TextPlacementFixtures.origin(inner).y > TextPlacementFixtures.origin(outer).y)
        }
    }

    @Test(arguments: [Placement.above, .below], [false, true])
    func emptyLyricSharesOnlyMovableNeighborRowShift(side: Placement, autoplace: Bool) throws {
        let document = TextPlacementFixtures.layout(makeScore([[
            chord(pitch: 71, lyrics: []),
            extremeChord(side: side, lyrics: lyrics(verse: 0, side: side, offset: 4)),
        ]]))
        let system = try #require(document.systems.first)
        let neighbor = try #require(system.measures.flatMap(\.elements).first { $0.textPlacement?.verse == 0 })
        let cursor = LyricInputPlanner.Cursor(location: anchor(measure: 0, element: 0), verse: 0)
        let origin = try #require(document.lyricEntryOrigin(
            at: cursor, placementStyle: TextPlacementStyles(),
            elementProperties: ElementProperties(
                offset: ScoreOffset(x: 0, y: 2),
                placement: side,
                autoplace: autoplace,
            ),
        ))
        let font = TextInkGeometry.font(for: .lyricsOdd, metrics: document.metrics)
        let centerOffset = (FontMetrics.provider.ascent(font: font) - FontMetrics.provider.descent(font: font)) / 2
        let ownDefault: CGFloat = (side == .above ? 0 : 63) - centerOffset
        let sharedRow = TextPlacementFixtures.origin(neighbor).y - (system.staffOrigins.first?.y ?? 0) - 14
        #expect(abs(sharedRow - ownDefault) > 1)
        #expect(abs(relativeY(origin, in: document) - (autoplace ? sharedRow : ownDefault)) < 0.001)
    }

    @Test(arguments: [Placement.above, .below])
    func lyricRowConstraintsDoNotCrossStaffBoundaries(side: Placement) throws {
        let outerVerse = side == .above ? 0 : 2
        let innerVerse = side == .above ? 2 : 0
        let ownStaff = Staff(measures: [Measure(voices: [Voice(elements: [
            chord(pitch: 71, lyrics: lyrics(verse: outerVerse, side: side)),
        ])])])
        let documents = [false, true].map { displaced in
            let values = lyrics(verse: innerVerse, side: side)
            let other = displaced ? extremeChord(side: side, lyrics: values) : chord(pitch: 71, lyrics: values)
            return TextPlacementFixtures.layout(Score(division: 480, parts: [
                Part(id: "P", instrument: Instrument(id: "voice"), staves: [
                    ownStaff, Staff(measures: [Measure(voices: [Voice(elements: [other])])]),
                ]),
            ]))
        }
        let quietLayout = documents[0]
        let extremeLayout = documents[1]
        let quietSystem = try #require(quietLayout.systems.first)
        let extremeSystem = try #require(extremeLayout.systems.first)
        let quietMark = try #require(quietSystem.measures.flatMap(\.elements).first {
            $0.textPlacement?.staff == staff
        })
        let extremeMark = try #require(extremeSystem.measures.flatMap(\.elements).first {
            $0.textPlacement?.staff == staff
        })
        let quietY = TextPlacementFixtures.origin(quietMark).y - quietSystem.staffOrigins[0].y
        let extremeY = TextPlacementFixtures.origin(extremeMark).y - extremeSystem.staffOrigins[0].y
        #expect(abs(quietY - extremeY) < 0.001)
    }

    private func extremeChord(side: Placement, lyrics: [Lyric]) -> VoiceElement {
        let pitches = side == .above ? [24, 26, 96] : [24, 108, 110]
        return .chord(Chord(
            duration: .eighth, notes: ChordNotes(pitches.map { Note(pitch: $0, tpc: 14) }), lyrics: lyrics,
        ))
    }

    private func lyrics(verse: Int, side: Placement, autoplace: Bool = true, offset: Double = 0) -> [Lyric] {
        var values = (0 ... verse).map { Lyric(text: "", verse: $0) }
        values[verse].text = "Ag"
        values[verse].elementProperties = ElementProperties(
            offset: ScoreOffset(x: 0, y: offset),
            placement: side,
            autoplace: autoplace,
        )
        return values
    }

    private func chord(pitch: Int, lyrics: [Lyric]) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: pitch, tpc: 14)]), lyrics: lyrics))
    }

    private func makeScore(_ measures: [[VoiceElement]]) -> Score {
        Score(division: 480, parts: [Part(id: "P", instrument: Instrument(id: "voice"), staves: [
            Staff(measures: measures.map { Measure(voices: [Voice(elements: $0)]) }),
        ])])
    }

    private func anchor(measure: Int, element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private func relativeY(_ point: CGPoint, in document: LayoutDocument) -> CGFloat {
        point.y - (document.systems.first?.origin.y ?? 0) - (document.systems.first?.staffOrigins.first?.y ?? 0)
    }
}
