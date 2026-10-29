#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicPDF

    /// An `OMRTextRecognizer` that records every image it is handed, in order, and answers from a closure.
    /// `stripIndex` is the number of calls made before this one.
    final class FakeTextRecognizer: OMRTextRecognizer, @unchecked Sendable {
        var images: [OMRTextImage] = []
        private let answer: (_ stripIndex: Int, _ image: OMRTextImage) throws -> [OMRRecognizedLine]

        init(
            answer: @escaping (_ stripIndex: Int, _ image: OMRTextImage) throws -> [OMRRecognizedLine] = { _, _ in [] },
        ) {
            self.answer = answer
        }

        func recognize(_ image: OMRTextImage) throws -> [OMRRecognizedLine] {
            let index = images.count
            images.append(image)
            return try answer(index, image)
        }
    }
#endif
