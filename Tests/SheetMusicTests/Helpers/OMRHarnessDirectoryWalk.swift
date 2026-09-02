import Foundation

/// Directory-walk helpers shared by every OMR dataset harness (spec
/// §6.6, §8.1-8.3): each one applies the identical "which entries under
/// `root` count as a render directory" / "which files in a render
/// directory are labels" filter before doing its own per-directory work.
///
/// Extracted here (Task 9 controller addition) so a fixture-driven test
/// can exercise the SAME traversal a harness uses, without needing
/// `OMR_DATA_ROOT` or the harness's `.enabled(if:)` gate. Mechanical
/// extraction only — every call site this replaces used
/// `FileManager.default` already, so `fileManager: .default` preserves
/// behavior exactly.
enum OMRHarnessDirectoryWalk {
    /// `root`'s immediate children, sorted, kept only when they contain
    /// a `render.json` — every harness's "is this a render dir" filter.
    static func renderDirectories(
        root: String, fileManager: FileManager = .default,
    ) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: root).sorted()
            .map { "\(root)/\($0)" }
            .filter { fileManager.fileExists(atPath: "\($0)/render.json") }
    }

    /// As `renderDirectories`, but also accepting the frozen eval set's
    /// `frozen.json` marker.
    ///
    /// The frozen set deliberately writes a DIFFERENT marker so that a
    /// second `freeze` cannot re-degrade its own output, and so that
    /// `eval_frozen/` is not walked as part of its parent root. The
    /// consequence is that pointing a `render.json`-only harness at it
    /// silently sweeps NOTHING: the first degraded raster sweep printed
    /// `pages=0 recall=0.0000`, which reads like a total detector failure
    /// and is in fact an empty traversal. That is precisely why every
    /// summary line here leads with a count.
    static func renderOrFrozenDirectories(
        root: String, fileManager: FileManager = .default,
    ) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: root).sorted()
            .map { "\(root)/\($0)" }
            .filter {
                fileManager.fileExists(atPath: "\($0)/render.json")
                    || fileManager.fileExists(atPath: "\($0)/frozen.json")
            }
    }

    /// `dir`'s `.labels.json` files, sorted — the per-render-directory
    /// label-file listing used by the replay / seam / score harnesses.
    static func labelFiles(
        in dir: String, fileManager: FileManager = .default,
    ) throws -> [String] {
        try fileManager.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".labels.json") }
            .sorted()
    }
}
