import CDirect2D
import Foundation
import SheetMusicLayout
import SheetMusicPDFWriter
import Synchronization

extension ScorePDFFonts {
    /// The faces a score PDF draws in on Windows, as the screen draws them: the bundled Bravura and Edwin
    /// (`ScoreSurface.bundledFontFiles`), Segoe UI for the notation labels, and for characters neither has — Japanese,
    /// most often — the fonts DirectWrite's fallback draws them in, each read from the file DirectWrite draws from, and
    /// only once. For `ScorePDFWriter.write(_:fonts:title:)`.
    ///
    /// Throws when a bundled face cannot be read, or DirectWrite cannot be set up with it. Loads `Bundle.module` (see
    /// `BundledResources`).
    public static func windows() throws -> ScorePDFFonts {
        let paths = ScoreSurface.bundledFontFiles
        let text = try WindowsTextFonts(fontFiles: paths)
        func bundled(_ name: String) throws -> Data {
            guard let path = paths.first(where: { $0.hasSuffix(name) }) else {
                throw Direct2DPageRenderer.Failure(step: "finding the bundled \(name)", hresult: -1)
            }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        return try ScorePDFFonts(
            smufl: bundled("Bravura.otf"), roman: bundled("Edwin-Roman.otf"), bold: bundled("Edwin-Bold.otf"),
            italic: bundled("Edwin-Italic.otf"), boldItalic: bundled("Edwin-BdIta.otf"),
            system: { weight, isItalic in text.systemFace(weight: weight, isItalic: isItalic) },
            fallback: { line in text.fallback(line) },
        )
    }
}

/// DirectWrite's answers for a PDF's text — the file the platform UI face draws from, the fonts a line falls back to —
/// over resources holding the bundled faces, so a line in Edwin falls back as the screen's does. Each file is read
/// once. One call at a time (the resources' caches), under a lock.
final class WindowsTextFonts: @unchecked Sendable {
    private let resources: OpaquePointer
    /// The files read so far, by path; touched under the lock, which is also the one `resources` is used under.
    private let files = Mutex<[String: Data]>([:])

    /// - Parameter fontFiles: the faces a surface draws with (`ScoreSurface.bundledFontFiles`).
    init(fontFiles: [String]) throws {
        var created: OpaquePointer?
        let hresult = cd2d_resources_create(&created)
        guard hresult == 0, let created else {
            throw Direct2DPageRenderer.Failure(step: "creating the DirectWrite resources", hresult: hresult)
        }
        var added: Int32 = 0
        for file in fontFiles where added == 0 {
            added = withWide(file) { cd2d_resources_add_font_file(created, $0) }
        }
        if added == 0 { added = cd2d_resources_fonts_ready(created) }
        guard added == 0 else {
            cd2d_resources_destroy(created)
            throw Direct2DPageRenderer.Failure(step: "adding the bundled faces", hresult: added)
        }
        resources = created
    }

    deinit {
        cd2d_resources_destroy(resources)
    }

    /// The Segoe UI file DirectWrite draws `weight` and slant from; nil when it cannot resolve one on disk.
    func systemFace(weight: FontWeight, isItalic: Bool) -> ScorePDFFontFile? {
        files.withLock { files in
            guard let face = face(WindowsFontMetricsProvider.systemFamily, weight: weight, isItalic: isItalic) else {
                return nil
            }
            return Self.read(face, into: &files)
        }
    }

    /// The parts of `line` DirectWrite draws in a font other than the line's own face — Segoe UI's for the system
    /// face, Edwin's otherwise — each with that font's file.
    func fallback(_ line: ScorePDFTextLine) -> [ScorePDFFallbackSpan] {
        let family = line.isSystemFace ? WindowsFontMetricsProvider.systemFamily : "Edwin"
        let weight = WindowsFontMetricsProvider.directWriteWeight(line.weight)
        let units = Array(line.text.utf16)
        return files.withLock { files in
            let own = face(family, weight: line.weight, isItalic: line.isItalic)
            var runs = [cd2d_font_run](repeating: cd2d_font_run(), count: max(units.count, 1))
            var count: UInt32 = 0
            let hresult = withWide(family) { family in
                units.withUnsafeBufferPointer { text in
                    runs.withUnsafeMutableBufferPointer { runs in
                        cd2d_text_font_runs(
                            resources, family, weight, line.isItalic ? 1 : 0, text.baseAddress, UInt32(text.count),
                            runs.baseAddress, UInt32(runs.count), &count,
                        )
                    }
                }
            }
            guard hresult == 0 else { return [] }
            return runs.prefix(Int(count)).compactMap { run in
                let face = (path: Self.path(run), index: Int(run.faceIndex))
                guard !face.path.isEmpty, face.path != own?.path || face.index != own?.index,
                      let file = Self.read(face, into: &files)
                else { return nil }
                return ScorePDFFallbackSpan(utf16Range: Int(run.start) ..< Int(run.start + run.length), font: file)
            }
        }
    }

    /// `cd2d_font_file_path` for the family; caller holds the lock.
    private func face(_ family: String, weight: FontWeight, isItalic: Bool) -> (path: String, index: Int)? {
        var path = [UInt16](repeating: 0, count: 4096)
        var length: UInt32 = 0
        var index: UInt32 = 0
        let hresult = withWide(family) { family in
            path.withUnsafeMutableBufferPointer { path in
                cd2d_font_file_path(
                    resources, family, WindowsFontMetricsProvider.directWriteWeight(weight), isItalic ? 1 : 0,
                    path.baseAddress, UInt32(path.count), &length, &index,
                )
            }
        }
        guard hresult == 0 else { return nil }
        return (String(decoding: path.prefix(Int(length)), as: UTF16.self), Int(index))
    }

    /// A run's path, up to its NUL.
    private static func path(_ run: cd2d_font_run) -> String {
        withUnsafeBytes(of: run.path) { bytes in
            let units = bytes.bindMemory(to: UInt16.self)
            return String(decoding: units.prefix { $0 != 0 }, as: UTF16.self)
        }
    }

    /// The file at `face.path`, read the first time; nil when it cannot be read.
    private static func read(
        _ face: (path: String, index: Int), into files: inout [String: Data],
    ) -> ScorePDFFontFile? {
        if files[face.path] == nil {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: face.path)) else { return nil }
            files[face.path] = data
        }
        return files[face.path].map { ScorePDFFontFile(key: face.path, data: $0, faceIndex: face.index) }
    }
}
