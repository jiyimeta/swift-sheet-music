import Foundation
import ZIPFoundation

/// Builds `.mxl` archive bytes at test time so we don't need to ship a
/// physical `.mxl` fixture. Writes a minimal `META-INF/container.xml` +
/// one MusicXML entry.
enum MXLTestBuilder {
    /// Wrap the given MusicXML bytes in a valid `.mxl` archive.
    /// - Parameters:
    ///   - xml: MusicXML bytes for the main score.
    ///   - entryName: file name of the score entry inside the archive
    ///     (defaults to `"score.xml"`); referenced from `container.xml`.
    static func wrap(xml: Data, entryName: String = "score.xml") throws -> Data {
        let container = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container>
              <rootfiles>
                <rootfile full-path="\(entryName)" media-type="application/vnd.recordare.musicxml+xml"/>
              </rootfiles>
            </container>
            """.utf8)
        return try buildArchive(entries: [
            ("META-INF/container.xml", container),
            (entryName, xml),
        ])
    }

    /// Build an archive that omits `META-INF/container.xml` entirely — used
    /// to exercise the `MXL: container.xml missing` error path.
    static func wrapWithoutContainer(xml: Data, entryName: String = "score.xml") throws -> Data {
        try buildArchive(entries: [(entryName, xml)])
    }

    /// Build an archive whose `container.xml` references a rootfile path that
    /// doesn't exist in the archive — used to exercise the
    /// `MXL: rootfile not found` error path.
    static func wrapWithDanglingRootfile(xml: Data) throws -> Data {
        let container = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container>
              <rootfiles>
                <rootfile full-path="missing.xml" media-type="application/vnd.recordare.musicxml+xml"/>
              </rootfiles>
            </container>
            """.utf8)
        return try buildArchive(entries: [
            ("META-INF/container.xml", container),
            ("score.xml", xml),
        ])
    }

    private static func buildArchive(entries: [(path: String, data: Data)]) throws -> Data {
        let archive = try Archive(accessMode: .create)
        for entry in entries {
            try archive.addEntry(
                with: entry.path,
                type: .file,
                uncompressedSize: Int64(entry.data.count),
                compressionMethod: .deflate,
                provider: { position, count in
                    let start = Int(position)
                    let end = start + count
                    return entry.data.subdata(in: start..<end)
                }
            )
        }
        guard let data = archive.data else {
            throw NSError(domain: "MXLTestBuilder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "archive produced no data",
            ])
        }
        return data
    }
}
