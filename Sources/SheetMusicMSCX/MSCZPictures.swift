import SheetMusicCore
import SheetMusicFoundation
import SheetMusicZip

/// The `Pictures/` payloads of an `.mscz`: the read side loads the ones a VBox's `<Image>` names into
/// `Score.pictures`, the write side gives them back as archive entries.
enum MSCZPictures {
    /// Archive folder every picture lives in; `Score.pictures` keys are the names below it.
    static let folder = "Pictures/"

    /// Loads `Pictures/<path>` into `score.pictures` for every path a VBox image references.
    ///
    /// Only referenced names are read; an unreferenced file stays reachable through `extraEntries`. A name
    /// that escapes the archive is skipped (`mscz.picture.badName`), a referenced entry that is absent or
    /// unreadable is reported (`mscz.picture.missing`); the `<Image>` itself stays either way.
    static func load(from reader: ZipReader, into score: inout Score) -> [ScoreDiagnostic] {
        var diagnostics: [ScoreDiagnostic] = []
        for path in referencedPaths(in: score) {
            guard isSafe(path) else {
                diagnostics.append(
                    ScoreDiagnostic(
                        severity: .warning,
                        code: "mscz.picture.badName",
                        message: "picture name is not a path inside the archive: \(path)",
                        location: path,
                    ),
                )
                continue
            }
            let entryPath = folder + path
            if reader.contains(path: entryPath), let data = try? reader.read(path: entryPath) {
                score.pictures[path] = data
            } else {
                diagnostics.append(
                    ScoreDiagnostic(
                        severity: .warning,
                        code: "mscz.picture.missing",
                        message: "picture \(entryPath) is referenced by an image but not in the archive",
                        location: path,
                    ),
                )
            }
        }
        return diagnostics
    }

    /// One stored entry per picture that an image still references and `paths` does not already name.
    /// A picture no image references (its `<Image>` was removed) is not written, as MuseScore does.
    static func entries(for score: Score, excluding paths: Set<String>) -> [MSCZExtraEntry] {
        var result: [MSCZExtraEntry] = []
        for path in referencedPaths(in: score) where isSafe(path) {
            let entryPath = folder + path
            guard let data = score.pictures[path], !paths.contains(entryPath) else { continue }
            result.append(MSCZExtraEntry(path: entryPath, data: data, compression: .stored))
        }
        return result
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

    /// Mirrors `MSCZWriter.validate(extraEntries:)`: non-empty, relative, no `..` segment.
    private static func isSafe(_ path: String) -> Bool {
        !path.isEmpty
            && !path.hasPrefix("/")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}
