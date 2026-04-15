import Foundation
import SheetMusicCore
import SheetMusicXMLTools
import ZIPFoundation

/// Reads `.mxl` (compressed MusicXML) archives: resolves the rootfile from
/// `META-INF/container.xml`, extracts that entry, and hands the bytes off to
/// `MusicXMLParser.parse(_:)`.
///
/// Mirrors the OPF container layout standard used by EPUB and MusicXML:
/// `<container><rootfiles><rootfile full-path="…" media-type="…"/></rootfiles></container>`.
/// Preference order for `parse(mxlData:)`:
/// 1. first rootfile whose `media-type` is `application/vnd.recordare.musicxml+xml`,
/// 2. else the first rootfile entry (back-compat with archives that omit media-type).
enum MXLReader {
    private static let containerPath = "META-INF/container.xml"
    private static let musicXMLMediaType = "application/vnd.recordare.musicxml+xml"

    /// Extract the bytes of the main MusicXML entry from a `.mxl` archive.
    static func extractRootScore(mxlData: Data) throws -> Data {
        let archive = try openArchive(mxlData)
        let roots = try readRootFiles(in: archive)
        let chosen = pickPreferred(roots)
        return try extract(path: chosen.path, from: archive)
    }

    /// List all rootfile entries declared in the archive's container.xml, in
    /// document order. Exposed via `MusicXMLContainer.rootFiles`.
    static func rootFiles(mxlData: Data) throws -> [MusicXMLContainer.RootFile] {
        let archive = try openArchive(mxlData)
        return try readRootFiles(in: archive)
    }

    private static func openArchive(_ data: Data) throws -> Archive {
        do {
            return try Archive(data: data, accessMode: .read)
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: could not open ZIP: \(error)"
            )
        }
    }

    private static func readRootFiles(in archive: Archive) throws -> [MusicXMLContainer.RootFile] {
        guard let entry = archive[containerPath], entry.type == .file else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml missing or has no rootfiles"
            )
        }
        let data = try extractEntry(entry, from: archive)
        let root: XMLTreeNode
        do {
            root = try XMLTreeParser.parse(data)
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml is not valid XML: \(error)"
            )
        }
        guard root.name == "container" else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml root is <\(root.name)>, expected <container>"
            )
        }
        let rootsNode = root.first("rootfiles")
        let entries = rootsNode?.all("rootfile") ?? []
        let result: [MusicXMLContainer.RootFile] = entries.compactMap { node in
            guard let path = node.attributes["full-path"], !path.isEmpty else {
                return nil
            }
            return MusicXMLContainer.RootFile(
                path: path,
                mediaType: node.attributes["media-type"]
            )
        }
        guard !result.isEmpty else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml has no <rootfile> entries"
            )
        }
        return result
    }

    private static func pickPreferred(_ roots: [MusicXMLContainer.RootFile]) -> MusicXMLContainer.RootFile {
        if let match = roots.first(where: { $0.mediaType == musicXMLMediaType }) {
            return match
        }
        return roots[0]  // non-empty guaranteed by readRootFiles
    }

    private static func extract(path: String, from archive: Archive) throws -> Data {
        guard let entry = archive[path], entry.type == .file else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: rootfile '\(path)' not found in archive"
            )
        }
        return try extractEntry(entry, from: archive)
    }

    private static func extractEntry(_ entry: Entry, from archive: Archive) throws -> Data {
        var buffer = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                buffer.append(chunk)
            }
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: failed to extract \(entry.path): \(error)"
            )
        }
        return buffer
    }
}
