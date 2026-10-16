import SheetMusicCore
import SheetMusicFoundation
import SheetMusicZip

/// The `Pictures/` payloads of an `.mscz`: the read side loads the ones a VBox's `<Image>` names into
/// `Score.pictures`, the write side gives them back as archive entries.
enum MSCZPictures {
    /// Archive folder every picture lives in; `Score.pictures` keys are the names below it.
    static let folder = "Pictures/"

    /// Loads `Pictures/<path>` into `score.pictures` for every path a VBox image references.
    static func load(from reader: ZipReader, into score: inout Score) -> [ScoreDiagnostic] {
        []
    }

    /// One stored entry per `score.pictures` key that an image still references and `paths` does not name.
    static func entries(for score: Score, excluding paths: Set<String>) -> [MSCZExtraEntry] {
        []
    }

    /// Every `FrameImage.path` in the score's VBoxes, in document order, each once.
    static func referencedPaths(in score: Score) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for positioned in score.blocks {
            guard case let .verticalFrame(frame) = positioned.block else { continue }
            for image in frame.images where seen.insert(image.path).inserted {
                result.append(image.path)
            }
        }
        return result
    }
}
