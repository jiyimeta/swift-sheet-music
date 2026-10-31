import CoreGraphics
import Foundation
import SheetMusicPDF
import Vision

/// The Vision implementation of `OMRTextRecognizer`: `VNRecognizeTextRequest` at `.accurate`, top candidate only,
/// with a box per character.
///
/// A stateless value type, so it is `Sendable` for free; every call builds its own request.
public struct VisionTextRecognizer: OMRTextRecognizer {
    /// Japanese first, then English: lyrics are mostly Japanese with the odd Latin word.
    public static let defaultLanguages = ["ja-JP", "en-US"]

    private let languages: [String]

    public init(languages: [String] = VisionTextRecognizer.defaultLanguages) {
        self.languages = languages
    }

    public func recognize(_ image: OMRTextImage) throws -> [OMRRecognizedLine] {
        try autoreleasepool {
            guard image.width > 0, image.height > 0, image.pixels.count >= image.width * image.height,
                  let cgImage = Self.makeCGImage(image)
            else {
                return []
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = languages
            // Lyrics are not prose: a language model would "correct" syllables into words.
            request.usesLanguageCorrection = false

            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

            let width = Double(image.width)
            let height = Double(image.height)
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = Self.pixelBox(observation.boundingBox, width: width, height: height)
                return OMRRecognizedLine(
                    text: candidate.string,
                    confidence: candidate.confidence,
                    x: box.x,
                    y: box.y,
                    width: box.width,
                    height: box.height,
                    characters: Self.characters(of: candidate, width: width, height: height),
                )
            }
        }
    }

    /// One box per non-whitespace character. A character whose box Vision cannot produce is skipped.
    private static func characters(of candidate: VNRecognizedText, width: Double, height: Double)
        -> [OMRRecognizedCharacter]
    {
        let text = candidate.string
        var result: [OMRRecognizedCharacter] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            let character = text[index ..< next]
            index = next
            if character.allSatisfy(\.isWhitespace) { continue }
            guard let rect = try? candidate.boundingBox(for: character.startIndex ..< character.endIndex) else {
                continue
            }
            let box = pixelBox(rect.boundingBox, width: width, height: height)
            result.append(
                OMRRecognizedCharacter(
                    text: String(character), x: box.x, y: box.y, width: box.width, height: box.height,
                ),
            )
        }
        return result
    }

    /// Vision's normalized, bottom-left-origin rect to image pixels with a top-left origin.
    private static func pixelBox(
        _ rect: CGRect, width: Double, height: Double,
    ) -> (x: Double, y: Double, width: Double, height: Double) {
        (
            x: Double(rect.minX) * width,
            y: (1 - Double(rect.maxY)) * height,
            width: Double(rect.width) * width,
            height: Double(rect.height) * height,
        )
    }

    private static func makeCGImage(_ image: OMRTextImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: image.width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent,
        )
    }
}
