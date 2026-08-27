import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

// `ScoreFrame.offsetMm` is `CGPoint`. On Apple and Android that's Foundation's own
// `CGPoint` (bare, from `import Foundation` above); WebAssembly is the only platform
// where no CoreGraphics-shaped `CGPoint` exists at all, so `SheetMusicCore` supplies
// its own — see `Sources/SheetMusicCore/Score/CGCompat+WASI.swift`. That file scopes
// itself to `os(WASI)`, not `!canImport(CoreGraphics)`, precisely because Android's
// incumbent `CGPoint` (Foundation's) must keep winning there — mirror the same gate.
#if os(WASI)
    private typealias CGPoint = SheetMusicCore.CGPoint
#endif

@Suite("MSCXEncoder ScoreFrame")
struct MSCXEncoderScoreFrameTests {
    @Test("VBox round-trips height and a Title text")
    func minimalTitleFrameRoundTrip() throws {
        let frame = ScoreFrame(
            heightSp: 10,
            texts: [FrameText(style: .title, text: "Invention")],
        )
        let xml = frame.encodeAsVBox()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]),
        )
        let reparsed = try XMLTreeParser.parse(bytes)
        let vbox = try #require(reparsed.first("VBox"))
        let decoded = ScoreFrame.decode(vbox: vbox)
        #expect(decoded == frame)
    }

    @Test("FrameText round-trips every Style case")
    func everyFrameTextStyleRoundTrip() throws {
        let cases: [FrameText.Style] = [
            .title, .subtitle, .composer, .lyricist, .other,
        ]
        for style in cases {
            let frame = ScoreFrame(
                heightSp: 10,
                texts: [FrameText(style: style, text: "x")],
            )
            let xml = frame.encodeAsVBox()
            let bytes = XMLTreeSerializer.serialize(
                XMLTreeNode(name: "root", children: [xml]),
            )
            let reparsed = try XMLTreeParser.parse(bytes)
            let vbox = try #require(reparsed.first("VBox"))
            let decoded = ScoreFrame.decode(vbox: vbox)
            #expect(decoded.texts.first?.style == style)
        }
    }

    @Test("FrameText round-trips offsetMm")
    func frameTextOffsetRoundTrip() throws {
        let frame = ScoreFrame(
            heightSp: 12,
            texts: [
                FrameText(
                    style: .composer,
                    text: "J.S. Bach",
                    offsetMm: CGPoint(x: 0, y: 4.5),
                ),
            ],
        )
        let xml = frame.encodeAsVBox()
        let bytes = XMLTreeSerializer.serialize(
            XMLTreeNode(name: "root", children: [xml]),
        )
        let reparsed = try XMLTreeParser.parse(bytes)
        let vbox = try #require(reparsed.first("VBox"))
        let decoded = ScoreFrame.decode(vbox: vbox)
        #expect(decoded == frame)
    }

    @Test("Score round-trips titleFrame on first staff")
    func scoreTitleFrameRoundTrip() throws {
        let titleFrame = ScoreFrame(
            heightSp: 10,
            texts: [
                FrameText(style: .title, text: "Invention"),
                FrameText(style: .composer, text: "J.S. Bach"),
            ],
        )
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            defaultClefType: nil,
            measures: [
                Measure(voices: [Voice(elements: [
                    .chord(Chord(
                        duration: .quarter,
                        notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                    )),
                ])]),
            ],
        )
        let part = Part(
            id: "1",
            trackName: "Voice",
            instrument: Instrument(id: "voice"),
            staves: [staff],
        )
        let original = Score(
            division: 480, parts: [part], titleFrame: titleFrame,
        )

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.titleFrame == titleFrame)
    }
}
