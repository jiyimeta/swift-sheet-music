import SheetMusicFoundation
import SheetMusicZip

/// One archive member a host wants to carry inside an `.mscz` container beside the score.
///
/// This library knows nothing about what such an entry means. A host that keeps a sidecar next to
/// the score — annotations, per-score preferences, ink — writes it through
/// `MSCZWriter.write(…, extraEntries:)` and gets it back from `MSCZReader.extraEntries(in:)`, so a
/// read → edit → write cycle preserves bytes this library does not model.
///
/// MuseScore addresses archive members by name, so a container carrying extra entries still opens
/// there; its own writer, however, does not pass them through, which is why a host whose sidecar
/// must survive a save should not name the file `.mscz`.
public struct MSCZExtraEntry: Sendable, Equatable {
    /// How an entry is stored in the archive.
    ///
    /// Declared here rather than reusing `SheetMusicZip.ZipCompressionMethod`: `SheetMusicZip` is
    /// an internal target with no library product, so a host that consumes `SheetMusicMSCX` cannot
    /// name that type at all — an entry could be constructed but never told to stay uncompressed.
    public enum Compression: Sendable, Equatable {
        /// Deflate the bytes. The right default for anything textual.
        case deflate
        /// Store the bytes verbatim. For payloads that are already compressed — a `.pkdrawing`, a
        /// PDF, an image — where deflating again costs time and saves nothing.
        case stored

        var zipMethod: ZipCompressionMethod {
            switch self {
            case .deflate: .deflate
            case .stored: .stored
            }
        }

        init(_ zipMethod: ZipCompressionMethod) {
            switch zipMethod {
            case .deflate: self = .deflate
            case .stored: self = .stored
            }
        }
    }

    /// Forward-slash separated path inside the archive. Nested paths are allowed.
    public let path: String
    public let data: Data
    public let compression: Compression

    public init(path: String, data: Data, compression: Compression = .deflate) {
        self.path = path
        self.data = data
        self.compression = compression
    }
}
