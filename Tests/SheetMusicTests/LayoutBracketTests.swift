import CoreGraphics
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

@Suite struct LayoutBracketTests {
    /// Hand-built score with brackets — avoids round-tripping through
    /// MSCX, so geometry logic can be verified independently.
    private static func makeScore() -> Score {
        let measure = Measure(voices: [
            Voice(elements: [
                .rest(duration: .fraction(Fraction(numerator: 1, denominator: 1))),
            ]),
        ])
        // Vln1 (single staff with NORMAL bracket span 2 column 0
        // and SQUARE bracket span 2 column 1).
        let vln1 = Part(
            id: "1",
            trackName: "Violin 1",
            instrument: Instrument(id: "vln1", longName: "Violin 1"),
            staves: [Staff(
                defaultClefType: "G",
                brackets: [
                    BracketItem(type: .normal, span: 2, column: 0),
                    BracketItem(type: .square, span: 2, column: 1),
                ],
                measures: [measure]
            )]
        )
        let vln2 = Part(
            id: "2",
            trackName: "Violin 2",
            instrument: Instrument(id: "vln2", longName: "Violin 2"),
            staves: [Staff(
                defaultClefType: "G",
                measures: [measure]
            )]
        )
        // Piano: 2 staves with BRACE on staff 0, span 2.
        let piano = Part(
            id: "3",
            trackName: "Piano",
            instrument: Instrument(id: "piano", longName: "Piano"),
            staves: [
                Staff(
                    defaultClefType: "G",
                    brackets: [BracketItem(type: .brace, span: 2)],
                    measures: [measure]
                ),
                Staff(
                    defaultClefType: "F",
                    measures: [measure]
                ),
            ]
        )
        return Score(division: 480, parts: [vln1, vln2, piano])
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func layoutBracketYFollowsStaffOrigins() {
        let doc = LayoutEngine.layout(
            score: Self.makeScore(),
            options: .init(),
            availableWidth: 800
        )
        let system = doc.systems[0]

        // Three distinct items: NORMAL (vln1+vln2), SQUARE
        // (vln1+vln2 nested), BRACE (piano).
        #expect(system.brackets.count == 3)

        // Find the BRACE.
        guard let brace = system.brackets.first(where: { $0.type == .brace })
        else {
            Issue.record("Expected a .brace bracket")
            return
        }
        // Piano staves are flat indices 2 and 3.
        #expect(abs(brace.topY - system.staffOrigins[2].y) < 0.001)
        let metrics = doc.metrics
        let pianoBottom = system.staffOrigins[3].y + metrics.staffHeight
        #expect(abs(brace.bottomY - pianoBottom) < 0.001)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func layoutBracketColumnAffectsXPosition() {
        let doc = LayoutEngine.layout(
            score: Self.makeScore(),
            options: .init(),
            availableWidth: 800
        )
        let system = doc.systems[0]
        let columns = system.brackets.map(\.column)
        #expect(columns.contains(0))
        #expect(columns.contains(1))

        let bareScore = Score(
            division: 480,
            parts: [
                Part(
                    id: "1",
                    trackName: "Violin 1",
                    instrument: Instrument(id: "vln1", longName: "Violin 1"),
                    staves: [Staff(
                        defaultClefType: "G",
                        measures: Self.makeScore().parts[0].staves[0].measures
                    )]
                ),
            ]
        )
        let bareDoc = LayoutEngine.layout(
            score: bareScore,
            options: .init(),
            availableWidth: 800
        )
        let bareGutter = bareDoc.systems[0].staffOrigins[0].x
        let bracketGutter = system.staffOrigins[0].x
        // With a column-1 bracket present, the gutter must be at
        // least one extra `sp` wider.
        #expect(bracketGutter > bareGutter + doc.metrics.sp * 0.9)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func bracketSpanClampedAtScoreEnd() {
        let measure = Measure(voices: [
            Voice(elements: [
                .rest(duration: .fraction(Fraction(numerator: 1, denominator: 1))),
            ]),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                trackName: "P",
                instrument: Instrument(id: "p", longName: "P"),
                staves: [Staff(
                    defaultClefType: "G",
                    brackets: [BracketItem(type: .normal, span: 99)],
                    measures: [measure]
                )]
            )]
        )
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(),
            availableWidth: 800
        )
        let system = doc.systems[0]
        #expect(system.brackets.count == 1)
        let metrics = doc.metrics
        guard let lastOrigin = system.staffOrigins.last else {
            Issue.record("Expected at least one staffOrigin")
            return
        }
        let lastBottom = lastOrigin.y + metrics.staffHeight
        #expect(abs(system.brackets[0].bottomY - lastBottom) < 0.001)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func noBracketTypeNotEmitted() {
        let measure = Measure(voices: [
            Voice(elements: [
                .rest(duration: .fraction(Fraction(numerator: 1, denominator: 1))),
            ]),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                trackName: "P",
                instrument: Instrument(id: "p", longName: "P"),
                staves: [Staff(
                    defaultClefType: "G",
                    brackets: [BracketItem(type: .noBracket, span: 1)],
                    measures: [measure]
                )]
            )]
        )
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(),
            availableWidth: 800
        )
        #expect(doc.systems[0].brackets.isEmpty)
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test func invisibleBracketNotEmitted() {
        let measure = Measure(voices: [
            Voice(elements: [
                .rest(duration: .fraction(Fraction(numerator: 1, denominator: 1))),
            ]),
        ])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                trackName: "P",
                instrument: Instrument(id: "p", longName: "P"),
                staves: [Staff(
                    defaultClefType: "G",
                    brackets: [BracketItem(
                        type: .normal, span: 1, visible: false
                    )],
                    measures: [measure]
                )]
            )]
        )
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(),
            availableWidth: 800
        )
        #expect(doc.systems[0].brackets.isEmpty)
    }

    // MARK: – End-to-end: real MSCX fixture

    @available(macOS 15.0, iOS 16.0, *)
    @Test func multiPartMixedStavesFixtureBrackets() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "multiPartMixedStaves",
                withExtension: "mscx"
            )
        )
        let score = try MSCXParser.parse(contentsOf: url)

        // Vln1 declares NORMAL (col 0) + SQUARE (col 1); Piano (parts[2])
        // declares BRACE on its top staff.
        #expect(score.parts[0].staves[0].brackets.count == 2)
        #expect(score.parts[0].staves[0].brackets.contains {
            $0.type == .normal && $0.span == 2 && $0.column == 0
        })
        #expect(score.parts[0].staves[0].brackets.contains {
            $0.type == .square && $0.span == 2 && $0.column == 1
        })
        #expect(score.parts[2].staves[0].brackets.count == 1)
        #expect(score.parts[2].staves[0].brackets[0].type == .brace)

        // End-to-end: layout produces three LayoutBrackets.
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(),
            availableWidth: 800
        )
        let kinds = doc.systems[0].brackets
            .map(\.type).sorted { $0.rawValue < $1.rawValue }
        #expect(kinds == [.normal, .brace, .square])
    }
}
