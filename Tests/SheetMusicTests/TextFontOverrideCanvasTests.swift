#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import SwiftUI
    import Testing

    /// The SwiftUI Canvas renderer — the path `PagedScoreView` and PDF export draw through — draws a text's
    /// authored font override and color.
    ///
    /// Each laid-out element is drawn ALONE into a Canvas through `ScoreCanvasDrawing.drawElement` and the
    /// raster is measured. A whole-page probe cannot see this: a larger text also grows the system, and the
    /// page's fit-to-width scale then shrinks everything, so a page's total ink can go down as one text grows.
    @Suite("Text font overrides reach the Canvas renderer", .serialized)
    @MainActor
    struct TextFontOverrideCanvasTests {
        private let _installApple = TestSupport.installApple

        private static let red = ScoreColor(red: 200, green: 10, blue: 20)
        private static let large = TextProperties(size: 24)
        private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        private static let canvas = CGSize(width: 700, height: 320)

        private static func score(lyric: Lyric? = nil, lane: [SystemElement] = []) -> Score {
            let chord = Chord(
                duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]), lyrics: lyric.map { [$0] } ?? [],
            )
            return Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )], systemMeasures: [SystemMeasure(elements: lane.map {
                PositionedSystemElement(position: .start, element: $0, originalStaff: staff)
            })])
        }

        /// What one element put on the canvas: the horizontal extent of its ink and how much of it is red.
        private struct Ink {
            var width = 0
            var red = 0
        }

        @available(macOS 15.0, *)
        private static func ink(
            of score: Score, _ matches: @escaping (LayoutElement) -> Bool,
        ) throws -> Ink {
            _ = BravuraFont.register
            let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 800)
            let element = try #require(document.systems.flatMap(\.measures).flatMap(\.elements).first(where: matches))
            let metrics = document.metrics
            let view = Canvas { context, _ in
                ScoreCanvasDrawing.drawElement(
                    element, base: CGPoint(x: 150, y: 180), metrics: metrics, into: &context,
                )
            }
            .frame(width: canvas.width, height: canvas.height)
            .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            return try raster(image)
        }

        private static func raster(_ image: CGImage) throws -> Ink {
            let width = image.width
            let height = image.height
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
            var minX = width
            var maxX = -1
            var ink = Ink()
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let offset = (y * width + x) * 4
                    let (r, g, b) = (bytes[offset], bytes[offset + 1], bytes[offset + 2])
                    guard r < 200 || g < 200 || b < 200 else { continue }
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    if r > 150, g < 90, b < 90 { ink.red += 1 }
                }
            }
            ink.width = maxX >= minX ? maxX - minX + 1 : 0
            return ink
        }

        private static func isLyric(_ element: LayoutElement) -> Bool {
            if case .textMark(.lyrics, _, _) = element { true } else { false }
        }

        private static func isStaffText(_ element: LayoutElement) -> Bool {
            if case .staffText = element { true } else { false }
        }

        private static func isRehearsalMark(_ element: LayoutElement) -> Bool {
            if case .rehearsalMark = element { true } else { false }
        }

        private static func isTempo(_ element: LayoutElement) -> Bool {
            if case .textMark(.tempo, _, _) = element { true } else { false }
        }

        @available(macOS 15.0, *)
        @Test("the Canvas lyric, staff text and rehearsal mark draw at their override size")
        func textsDrawTheOverrideSize() throws {
            let lyric = try Self.ink(of: Self.score(lyric: Lyric(text: "Wonder", properties: Self.large)), Self.isLyric)
            let plainLyric = try Self.ink(of: Self.score(lyric: Lyric(text: "Wonder")), Self.isLyric)
            #expect(lyric.width > plainLyric.width * 3 / 2)

            let staffText = try Self.ink(
                of: Self.score(lane: [.staffText(StaffText(text: "dolce", properties: Self.large))]), Self.isStaffText,
            )
            let plainStaffText = try Self.ink(
                of: Self.score(lane: [.staffText(StaffText(text: "dolce"))]), Self.isStaffText,
            )
            #expect(staffText.width > plainStaffText.width * 3 / 2)

            let mark = try Self.ink(
                of: Self.score(lane: [.rehearsalMark(RehearsalMark(text: "Chorus", properties: Self.large))]),
                Self.isRehearsalMark,
            )
            let plainMark = try Self.ink(
                of: Self.score(lane: [.rehearsalMark(RehearsalMark(text: "Chorus"))]), Self.isRehearsalMark,
            )
            #expect(mark.width > plainMark.width * 6 / 5)
        }

        @available(macOS 15.0, *)
        @Test("the Canvas tempo marking draws its size and color")
        func tempoDrawsSizeAndColor() throws {
            var tempo = Tempo(beatsPerSecond: 2, properties: Self.large)
            tempo.elementProperties.color = Self.red
            let styled = try Self.ink(of: Self.score(lane: [.tempo(tempo)]), Self.isTempo)
            let plain = try Self.ink(of: Self.score(lane: [.tempo(Tempo(beatsPerSecond: 2))]), Self.isTempo)
            #expect(plain.width > 0)
            #expect(styled.width > plain.width * 3 / 2)
            #expect(plain.red == 0)
            #expect(styled.red > 50)
        }
    }
#endif
