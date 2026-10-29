import Foundation

/// One grayscale image, row-major, y-down, top-left origin. 0 is ink, 255 is paper.
public struct OMRTextImage: Sendable {
    public var pixels: [UInt8]
    public var width: Int
    public var height: Int

    /// REQUIRED: the Vision-backed recognizer is in another module, so the
    /// synthesized memberwise init would be internal and unusable there.
    public init(pixels: [UInt8], width: Int, height: Int) {
        self.pixels = pixels
        self.width = width
        self.height = height
    }
}

/// One recognized character's box in the image's pixels (top-left origin, y-down).
public struct OMRRecognizedCharacter: Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    /// REQUIRED: see `OMRTextImage.init`.
    public init(text: String, x: Double, y: Double, width: Double, height: Double) {
        self.text = text
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One recognized line of text: its box in the image's pixels (top-left origin, y-down) and the per-character boxes.
public struct OMRRecognizedLine: Sendable {
    public var text: String
    public var confidence: Float
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var characters: [OMRRecognizedCharacter]

    /// REQUIRED: see `OMRTextImage.init`.
    public init(
        text: String,
        confidence: Float,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        characters: [OMRRecognizedCharacter],
    ) {
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.characters = characters
    }
}

/// The ONE platform-specific step of raster text reading (mirrors `OMRTileClassifier`):
/// turning a grayscale image into recognized lines.
///
/// Everything around it — cropping, mapping boxes back to page space, deciding what is a lyric — is portable Swift
/// and lives in this module, so a non-Vision backend reuses all of it and reimplements only this.
public protocol OMRTextRecognizer: Sendable {
    /// Recognizes the text in `image`. Implementations perform recognition only.
    ///
    /// **The implementation owns an `autoreleasepool` (or equivalent) around its own work**, for the same reason as
    /// `OMRTileClassifier.run(tile:)`: the pool cannot live in the portable caller because that code also compiles
    /// for Android.
    func recognize(_ image: OMRTextImage) throws -> [OMRRecognizedLine]
}
