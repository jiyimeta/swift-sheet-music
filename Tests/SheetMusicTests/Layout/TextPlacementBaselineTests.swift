import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

@Suite("Text placement baselines")
struct TextPlacementBaselineTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private let roles: [TextPlacementRole] = [
        .lyrics,
        .staffText,
        .systemText,
        .rehearsalMark,
        .harmonyA,
        .romanNumeral,
        .nashvilleNumber,
    ]

    /// Literal baseline values are independent of the resolver's default table.
    @Test(arguments: [1, 3, 5], [Placement.above, .below])
    func staffEdgesAndMultilineBaseline(lines: Int, side: Placement) throws {
        let expectedAbove: [CGFloat] = [-2, -1, -2, -2, -2.5, -2.5, -2.5]
        let expectedBelow: [CGFloat] = [3, 2.5, 3.5, 4, 3.5, 3.5, 3.5]
        for (index, role) in roles.enumerated() {
            // Harmony runs are separately anchored; multiline run shaping is covered by ink tests.
            let text = index < 4 ? "A\ng" : "Ag"
            let document = TextPlacementFixtures.layout(TextPlacementFixtures.score(
                role: role,
                side: side,
                autoplace: false,
                text: text,
                lines: lines,
            ))
            let system = try #require(document.systems.first)
            let element = try #require(TextPlacementFixtures.mark(document))
            var origin = TextPlacementFixtures.origin(element)
            origin.y -= try #require(system.staffOrigins.first).y
            let textStyle: TextStyleType
            let anchor: CGPoint
            switch role {
            case .lyrics: textStyle = .lyricsOdd; anchor = CGPoint(x: 0.5, y: 0.5)
            case .staffText: textStyle = .staffText; anchor = CGPoint(x: 0, y: 1)
            case .systemText: textStyle = .systemText; anchor = CGPoint(x: 0, y: 1)
            case .rehearsalMark:
                textStyle = .rehearsalMark; anchor = CGPoint(x: 0, y: 1)
                origin.y -= RehearsalMarkFrame.paddingSp(sp: 7)
            case .romanNumeral: textStyle = .chordSymbolRomanNumeral; anchor = CGPoint(x: 0, y: 0.5)
            default: textStyle = .chordSymbolA; anchor = CGPoint(x: 0, y: 0.5)
            }
            let font = TextInkGeometry.font(for: textStyle, metrics: TextPlacementFixtures.metrics)
            let baseline = TextInkGeometry.baselineOrigin(text: text, font: font, origin: origin, anchor: anchor)
            let expected = side == .above ? expectedAbove[index] * 7 : (CGFloat(lines - 1) + expectedBelow[index]) * 7
            #expect(abs(baseline.y - expected) < 0.0001, "\(role), \(side), \(lines) lines")
            #expect(element.textPlacement?.side == side)
            #expect(element.textPlacement?.autoplace == false)
        }
    }

    @Test func nilAndExplicitDefaultAreEquivalent() throws {
        for role in roles {
            let implicit = TextPlacementFixtures.layout(TextPlacementFixtures.score(role: role))
            let explicit = TextPlacementFixtures.layout(TextPlacementFixtures.score(
                role: role,
                side: role == .lyrics ? .below : .above,
            ))
            let a = try #require(TextPlacementFixtures.mark(implicit))
            let b = try #require(TextPlacementFixtures.mark(explicit))
            #expect(TextPlacementFixtures.origin(a) == TextPlacementFixtures.origin(b))
            #expect(implicit.size == explicit.size)
            #expect(TextInkGeometry.rects(for: a, metrics: TextPlacementFixtures.metrics) == TextInkGeometry.rects(
                for: b,
                metrics: TextPlacementFixtures.metrics,
            ))
        }
    }

    @Test func scoreStyleOverridesAndElementSideWins() throws {
        for role in roles {
            var style = TextPlacementStyles()
            let sideRole: TextPlacementRole = [.romanNumeral, .nashvilleNumber].contains(role) ? .harmonyA : role
            style[sideRole].placement = .below
            style[role].positionBelow = ScoreOffset(x: 1, y: 8)
            let styled = TextPlacementFixtures.layout(TextPlacementFixtures.score(
                role: role,
                autoplace: false,
                style: style,
            ))
            #expect(try #require(TextPlacementFixtures.mark(styled)).textPlacement?.side == .below)
            let explicit = TextPlacementFixtures.layout(TextPlacementFixtures.score(
                role: role,
                side: .above,
                autoplace: false,
                style: style,
            ))
            #expect(try #require(TextPlacementFixtures.mark(explicit)).textPlacement?.side == .above)
            let offset = TextPlacementFixtures.layout(TextPlacementFixtures.score(
                role: role,
                autoplace: false,
                offset: ScoreOffset(x: 2, y: 3),
                style: style,
            ))
            let a = try #require(TextPlacementFixtures.mark(styled))
            let b = try #require(TextPlacementFixtures.mark(offset))
            let ay = TextPlacementFixtures.origin(a).y - (styled.systems.first?.staffOrigins.first?.y ?? 0)
            let by = TextPlacementFixtures.origin(b).y - (offset.systems.first?.staffOrigins.first?.y ?? 0)
            #expect(abs(by - ay - 21) < 0.0001)
        }
    }

    @Test func noteAndChordGenericPlacementDoNotChangeGeometry() {
        var score = TextPlacementFixtures.score(role: .lyrics)
        let original = TextPlacementFixtures.layout(score)
        score.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staff in
                staff.measures[0].voices[0].elements.updateValue(at: 0) { element in
                    guard case var .chord(chord) = element else { return }
                    chord.elementProperties.placement = .above
                    var note = chord.notes[0]
                    note.elementProperties.placement = .above
                    chord.notes = ChordNotes([note])
                    element = .chord(chord)
                }
            }
        }
        #expect(TextPlacementFixtures.layout(score) == original)
    }
}
