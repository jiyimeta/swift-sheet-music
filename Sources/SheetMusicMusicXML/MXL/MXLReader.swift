import Foundation
import SheetMusicCore
import SheetMusicXMLTools
import SheetMusicZip

/// Reads `.mxl` (compressed MusicXML) archives: resolves the rootfile
/// from `META-INF/container.xml`, extracts that entry, and hands the
/// bytes off to `MusicXMLParser.parse(_:)`.
enum MXLReader {
    private static let containerPath = "META-INF/container.xml"
    private static let musicXMLMediaType = "application/vnd.recordare.musicxml+xml"

    static func extractRootScore(mxlData: Data) throws -> Data {
        let reader = try openReader(mxlData)
        let roots = try readRootFiles(in: reader)
        let chosen = pickPreferred(roots)
        do {
            return try reader.read(path: chosen.path)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: failed to extract \(chosen.path): \(error)",
            )
        }
    }

    static func rootFiles(mxlData: Data) throws -> [MusicXMLContainer.RootFile] {
        let reader = try openReader(mxlData)
        return try readRootFiles(in: reader)
    }

    private static func openReader(_ data: Data) throws -> ZipReader {
        do {
            return try ZipReader(data: data)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: could not open ZIP: \(error)",
            )
        }
    }

    private static func readRootFiles(in reader: ZipReader) throws -> [MusicXMLContainer.RootFile] {
        guard reader.contains(path: containerPath) else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml missing or has no rootfiles",
            )
        }
        let data: Data
        do {
            data = try reader.read(path: containerPath)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: failed to extract container.xml: \(error)",
            )
        }
        let root: XMLTreeNode
        do {
            root = try XMLTreeParser.parse(data)
        } catch {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml is not valid XML: \(error)",
            )
        }
        guard root.name == "container" else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml root is <\(root.name)>, expected <container>",
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
                mediaType: node.attributes["media-type"],
            )
        }
        guard !result.isEmpty else {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: container.xml has no <rootfile> entries",
            )
        }
        // Verify each rootfile actually exists in the archive — preserves
        // the "rootfile not found" error path of the previous version.
        for r in result where !reader.contains(path: r.path) {
            throw SheetMusicError.corruptedContainer(
                reason: "MXL: rootfile '\(r.path)' not found in archive",
            )
        }
        return result
    }

    private static func pickPreferred(_ roots: [MusicXMLContainer.RootFile]) -> MusicXMLContainer.RootFile {
        if let match = roots.first(where: { $0.mediaType == musicXMLMediaType }) {
            return match
        }
        return roots[0]
    }
}
