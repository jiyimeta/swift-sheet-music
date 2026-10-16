#if DEBUG
    import CoreGraphics
    import Foundation
    import ImageIO
    import SheetMusicCore
    import SwiftUI

    /// A score shaped like the `frames-pictures` fixture, built in code: a picture in the title block and a box with
    /// a subtitle and a picture between two systems (it breaks the systems before measure 5). It exercises the screen
    /// path — `ScoreView` mounting `LayoutDocument.frames` and drawing the title block's `titleImages` — on macOS and
    /// iOS alike, with no file to load.
    private enum ScoreViewFramesPreview {
        static let score: Score = {
            var score = Score.blank(BlankScoreTemplate(
                title: "Boxes and pictures", composer: "swift-sheet-music",
                parts: [.init(instrumentID: "piano", staves: [.init(clefType: "G")])],
                measureCount: 8,
            ))
            var title = score.titleFrame ?? ScoreFrame(heightSp: 10, texts: [])
            title.images = [
                FrameImage(path: "title.png", size: CGSize(width: 5, height: 5), offsetSp: CGPoint(x: 1, y: 1)),
            ]
            score.titleFrame = title
            let box = ScoreFrame(
                heightSp: 8,
                texts: [FrameText(style: .subtitle, text: "A box between two systems")],
                images: [
                    FrameImage(path: "box.png", size: CGSize(width: 16, height: 6), offsetSp: CGPoint(x: 2, y: 2)),
                ],
            )
            score.blocks.append(PositionedScoreBlock(beforeMeasureIndex: 4, block: .verticalFrame(box)))
            score.pictures = [
                "title.png": ScoreViewFramesPreview.swatch(width: 64, height: 64, red: 0.20, green: 0.45, blue: 0.85),
                "box.png": ScoreViewFramesPreview.swatch(width: 192, height: 72, red: 0.90, green: 0.55, blue: 0.15),
            ]
            return score
        }()

        /// A `width` × `height` PNG: a solid color crossed by a white diagonal, so a stretched or misplaced picture
        /// reads at a glance. Empty `Data` (which lays out as no picture) if CoreGraphics or ImageIO refuses.
        private static func swatch(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> Data {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            ) else { return Data() }
            context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.setLineWidth(CGFloat(min(width, height)) / 8)
            context.strokeLineSegments(between: [CGPoint(x: 0, y: 0), CGPoint(x: width, y: height)])
            let output = NSMutableData()
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithData(
                      output as CFMutableData, "public.png" as CFString, 1, nil,
                  )
            else { return Data() }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return Data() }
            return output as Data
        }
    }

    #Preview("Boxes and pictures") {
        if #available(macOS 15.0, *) {
            // 360 pt wide, so the whole page fits an iPhone's preview as well as a Mac's.
            ScoreView(score: ScoreViewFramesPreview.score, availableWidth: 360)
                .padding(16)
                .frame(width: 392, height: 640, alignment: .topLeading)
                .background(.white)
        } else {
            Text("ScoreView needs macOS 15")
        }
    }
#endif
