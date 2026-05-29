#if os(macOS)
    import AppKit
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
    @testable import SheetMusicUI
    import Testing

    /// End-to-end render check for author-supplied `<color>`: a red
    /// notehead / stem / beam / lyric, plus a text-only red chord symbol
    /// (the MuseScore-4.4 `<harmonyInfo>` shape) must rasterize with
    /// genuinely red pixels — not the default black ink.
    @Suite("Element colour rasterization")
    struct ElementColorRenderTests {
        private let _installApple = TestSupport.installApple

        @MainActor
        @Test("Red noteheads / beam / lyric / text-harmony render red")
        // swiftlint:disable:next function_body_length
        func redElementsRenderRed() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register

            let red = ScoreColor(red: 255, green: 0, blue: 0, alpha: 255)
            func redNote(_ pitch: Int) -> Note {
                var n = Note(pitch: pitch, tpc: 14)
                n.elementProperties.color = red
                return n
            }
            var redLyric = Lyric(text: "あ")
            redLyric.elementProperties.color = red
            // Two beamed eighths so the beam-colour path runs; the first
            // carries the red lyric.
            let c1 = Chord(
                duration: .eighth, notes: [redNote(60)], lyrics: [redLyric],
            )
            let c2 = Chord(duration: .eighth, notes: [redNote(62)])
            // High note (C6) sits well above the treble staff so it
            // carries several ledger lines — used to eyeball that the
            // ledger renders behind the (red) notehead.
            let c3 = Chord(duration: .quarter, notes: [redNote(84)])
            let harmony = Harmony(name: "裏声OK", color: red)
            let measure = Measure(voices: [Voice(elements: [
                .harmony(harmony), .chord(c1), .chord(c2), .chord(c3),
            ])])
            let staff = Staff(measures: [measure])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"), staves: [staff],
                )],
            )

            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false,
            )
            let natW = LayoutEngine.naturalContentWidth(
                score: score, options: opts,
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: natW,
            )
            let system = try #require(doc.systems.first)
            let tree = ScoreLayerBuilder.buildSystem(
                system, metrics: doc.metrics,
            )
            tree.layoutIfNeeded()

            let width = Int(ceil(system.size.width))
            let height = Int(ceil(system.size.height + 1))
            let space = CGColorSpaceCreateDeviceRGB()
            let ctx = try #require(CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            tree.render(in: ctx)

            let image = try #require(ctx.makeImage())
            let provider = try #require(image.dataProvider)
            let cfData = try #require(provider.data)
            let data = try #require(CFDataGetBytePtr(cfData))

            // Dump a PNG for manual inspection (best-effort; never fails
            // the test).
            if let png = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:])
            {
                try? png.write(to: URL(
                    fileURLWithPath: "/tmp/element-color-verify.png",
                ))
            }

            // A "red" pixel: red channel dominant, green/blue suppressed.
            var redPixels = 0
            var blackInk = 0
            for i in stride(from: 0, to: width * height * 4, by: 4) {
                let r = data[i], g = data[i + 1], b = data[i + 2]
                if r > 180, g < 110, b < 110 { redPixels += 1 }
                if r < 80, g < 80, b < 80 { blackInk += 1 }
            }
            #expect(
                redPixels > 100,
                "expected red ink for coloured elements, got \(redPixels)",
            )
            // Staff lines / ledger are still black; the score is not
            // entirely red. (Sanity: the colour path didn't tint
            // everything.)
            #expect(
                blackInk > 50,
                "expected black staff ink to remain, got \(blackInk)",
            )
        }
    }
#endif
