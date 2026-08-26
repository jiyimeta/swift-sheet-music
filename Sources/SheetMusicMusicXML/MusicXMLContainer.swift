import SheetMusicCore
import SheetMusicFoundation

/// Public helpers for `.mxl` archive introspection.
public enum MusicXMLContainer {
    /// A rootfile entry declared in `META-INF/container.xml`.
    public struct RootFile: Sendable, Equatable {
        /// Full archive-relative path (e.g. `"score.xml"`).
        public let path: String
        /// Optional `media-type` attribute (e.g.
        /// `"application/vnd.recordare.musicxml+xml"`).
        public let mediaType: String?

        public init(path: String, mediaType: String? = nil) {
            self.path = path
            self.mediaType = mediaType
        }
    }

    /// Returns rootfile entries declared in the archive's `META-INF/container.xml`,
    /// in document order. `MusicXMLParser.parse(mxlData:)` picks the first entry
    /// whose `mediaType` matches MusicXML (or the first rootfile if none match).
    public static func rootFiles(mxlData: Data) throws -> [RootFile] {
        try MXLReader.rootFiles(mxlData: mxlData)
    }
}
