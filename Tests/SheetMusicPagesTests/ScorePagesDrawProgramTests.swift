import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
import SheetMusicPages
import Testing

#if !canImport(CoreGraphics)
    // Foundation off Apple ships its own `CGFloat` / `CGRect`; `FontMetricsProvider` speaks SheetMusicLayout's
    // (`CGTypes+Android.swift`), so the provider below names those.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// `ScorePages.encodedDrawProgram()`: the pages a host computed, as the draw-program bytes the same release's Kotlin
/// `DrawProgramReader.decode` reads — how a host that lays out in its own Swift image, inside a
/// `FontMetrics.withProvider` scope the JNI library's process-wide provider never sees, hands the result to a Kotlin
/// renderer (`drawScoreCommands`).
///
/// `SheetMusicPages` is imported without `@testable`, as a host imports it.
@Suite("ScorePages.encodedDrawProgram")
struct ScorePagesDrawProgramTests {
    /// The portable table, as a host makes it (`fontMetricsTableProvider(_:)`).
    private static func table() throws -> any FontMetricsProvider {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicPagesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Sources/SheetMusicRenderWindows/Resources/sheet-music.smft")
        return try fontMetricsTableProvider(Data(contentsOf: url))
    }

    private static let title = "Sonatina"

    /// A titled staff of 48 whole-note bars: a title line, which is centred by its measured width, and enough systems
    /// for several short pages.
    private static let score: Score = {
        let note = Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])
        var measures = Array(repeating: Measure(voices: [Voice(elements: [.chord(note)])]), count: 48)
        measures[0] = Measure(voices: [Voice(elements: [.clef(Clef(concertClefType: "G")), .chord(note)])])
        return Score(
            division: 480,
            parts: [Part(id: "P1", instrument: Instrument(id: "voice"), staves: [Staff(measures: measures)])],
            systemMeasures: IdentifiedArray(Array(repeating: SystemMeasure(), count: measures.count)),
            titleFrame: ScoreFrame(heightSp: 12, texts: [FrameText(style: .title, text: Self.title)]),
        )
    }()

    private static let pageWidthMM = 180.0
    private static let pageHeightMM = 60.0

    @Test("the bytes decode to the pages compute built, in every mode, and are nativeComputeLayout's payload")
    func theBytesAreTheBridgesProgram() throws {
        try FontMetrics.withProvider(Self.table()) {
            for mode in ScorePageOptions.Mode.allCases {
                let options = ScorePageOptions(mode: mode)
                let pages = ScorePages.compute(
                    score: Self.score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM,
                    options: options,
                )
                let bytes = pages.encodedDrawProgram()
                let decoded = try DrawProgramCodec.decode(bytes)
                #expect(decoded == pages.pages, "\(mode)")
                #expect(decoded.count == pages.pageCount, "\(mode)")
                // Not vacuous in page mode: one page would not tell a whole program from its first page.
                if mode == .page { #expect(decoded.count > 1) }
                // What the Android Reader's `nativeComputeLayout` returns for the same score and options — the
                // payload `DrawProgramReader.decode` already reads.
                let bridge = LayoutBridge.computeWithDocument(
                    score: Self.score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM,
                    options: options.wire(),
                )
                #expect(bytes == bridge.encoded, "\(mode)")
            }
        }
    }

    @Test("the program carries the scope's measurements, and encoding it reads no provider")
    func theScopeReachesTheProgram() throws {
        let table = try Self.table()
        let stub = StubMeasurements()
        let underTable = FontMetrics.withProvider(table) {
            ScorePages.compute(score: Self.score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM)
        }
        let underStub = FontMetrics.withProvider(stub) {
            ScorePages.compute(score: Self.score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM)
        }

        // Encoded after both scopes ended: the title sits where each scope's widths centred it.
        let tableTitle = try #require(Self.titleRun(in: DrawProgramCodec.decode(underTable.encodedDrawProgram())))
        let stubTitle = try #require(Self.titleRun(in: DrawProgramCodec.decode(underStub.encodedDrawProgram())))
        #expect(tableTitle.x != stubTitle.x, "the title starts at \(tableTitle.x) mm under both")

        // The bytes are fixed when `compute` returns: no provider in force at the call changes them.
        let inTableScope = FontMetrics.withProvider(table) { underTable.encodedDrawProgram() }
        let inStubScope = FontMetrics.withProvider(stub) { underTable.encodedDrawProgram() }
        #expect(inTableScope == inStubScope)
    }

    /// `systemCommandRanges(onPage:)` is the spans a host cannot see: for every page, in every mode, the ranges chain
    /// from the first command to the last, and each is its span's system and command range. Every system has one range
    /// on the page that draws it — in `.vertical` and `.horizontal` all of them on the one page, in `.page` the
    /// document's indices across the pages, in order — and a page that draws the title block draws it first, in a range
    /// with no system.
    @Test("a page's system ranges are its spans: in order, covering its commands, one range per system")
    func systemRangesAreTheSpans() throws {
        try FontMetrics.withProvider(Self.table()) {
            var titled = 0
            for mode in ScorePageOptions.Mode.allCases {
                let pages = ScorePages.compute(
                    score: Self.score, pageWidthMM: Self.pageWidthMM, pageHeightMM: Self.pageHeightMM,
                    options: ScorePageOptions(mode: mode),
                )
                var systems: [Int] = []
                for page in 0 ..< pages.pageCount {
                    let ranges = pages.systemCommandRanges(onPage: page)
                    let commands = pages.pages[page].commands
                    let label = "\(mode), page \(page)"
                    #expect(ranges.first?.commands.lowerBound == 0, "\(label)")
                    #expect(ranges.last?.commands.upperBound == commands.count, "\(label)")
                    for (range, next) in zip(ranges, ranges.dropFirst()) {
                        #expect(range.commands.upperBound == next.commands.lowerBound, "\(label)")
                    }
                    let spans = pages.spans[page]
                    #expect(ranges.count == spans.count, "\(label)")
                    for (range, span) in zip(ranges, spans) {
                        #expect(range.systemIndex == span.systemIndex, "\(label)")
                        #expect(range.commands == span.commandRange, "\(label)")
                    }
                    if mode != .page {
                        #expect(ranges.compactMap(\.systemIndex) == Array(pages.document.systems.indices), "\(label)")
                    }
                    systems += ranges.compactMap(\.systemIndex)
                    if let title = Self.titleCommand(in: commands) {
                        #expect(ranges.first?.systemIndex == nil, "\(label): the title block is not first")
                        #expect(ranges.first?.commands.contains(title) == true, "\(label): the title is not first")
                        titled += 1
                    }
                }
                #expect(systems == Array(pages.document.systems.indices), "\(mode)")
            }
            // Not vacuous: the title block is laid out in `.vertical` and `.page`.
            #expect(titled > 0)
        }
    }

    /// The index of the title's `text` run among `commands`.
    private static func titleCommand(in commands: [DrawCommand]) -> Int? {
        commands.firstIndex { command in
            guard case let .text(text, _, _, _, _) = command else { return false }
            return text == title
        }
    }

    /// The title's `text` run on the first page.
    private static func titleRun(in pages: [EncodablePage]) -> (x: Double, y: Double)? {
        for case let .text(text, x, y, _, _) in pages.first?.commands ?? [] where text == title {
            return (x, y)
        }
        return nil
    }
}

/// The stub's measurements behind another type: `LayoutEngine.layout` refuses the stub itself in a debug build on a
/// CoreText platform.
private struct StubMeasurements: FontMetricsProvider {
    let stub = StubFontMetricsProvider()

    func ascent(font: LayoutFont) -> CGFloat {
        stub.ascent(font: font)
    }

    func descent(font: LayoutFont) -> CGFloat {
        stub.descent(font: font)
    }

    func leading(font: LayoutFont) -> CGFloat {
        stub.leading(font: font)
    }

    func glyphPathBoundingBox(font: LayoutFont, codepoint: UInt16) -> CGRect? {
        stub.glyphPathBoundingBox(font: font, codepoint: codepoint)
    }

    func typographicWidth(text: String, font: LayoutFont) -> CGFloat {
        stub.typographicWidth(text: text, font: font)
    }

    func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        stub.inkBounds(text: text, font: font)
    }

    func textInkBounds(text: String, font: LayoutFont) -> CGRect? {
        stub.textInkBounds(text: text, font: font)
    }
}
