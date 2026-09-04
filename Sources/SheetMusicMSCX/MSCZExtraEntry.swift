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
    /// Forward-slash separated path inside the archive. Nested paths are allowed.
    public let path: String
    public let data: Data
    /// How the entry is stored. `.deflate` for anything compressible; `.stored` for bytes that are
    /// already compressed, where deflating twice costs time and gains nothing.
    public let compression: ZipCompressionMethod

    public init(path: String, data: Data, compression: ZipCompressionMethod = .deflate) {
        self.path = path
        self.data = data
        self.compression = compression
    }
}
