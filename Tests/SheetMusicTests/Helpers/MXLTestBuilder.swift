import Foundation
import SheetMusicZip

/// Builds `.mxl` archive bytes at test time so we don't need to ship a
/// physical `.mxl` fixture. Writes a minimal `META-INF/container.xml`
/// plus one MusicXML entry.
enum MXLTestBuilder {
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

    static func wrapWithoutContainer(xml: Data, entryName: String = "score.xml") throws -> Data {
        try buildArchive(entries: [(entryName, xml)])
    }

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
        var writer = ZipWriter()
        for entry in entries {
            try writer.add(path: entry.path, data: entry.data, method: .deflate)
        }
        return writer.finish()
    }
}
