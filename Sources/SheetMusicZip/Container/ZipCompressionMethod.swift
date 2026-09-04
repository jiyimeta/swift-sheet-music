/// ZIP compression methods SheetMusicZip understands.
///
/// 0 = STORED (no compression), 8 = DEFLATE (RFC 1951). All other
/// method codes are rejected by ZipReader with
/// `ZipError.unsupportedFeature`.
public enum ZipCompressionMethod: UInt16, Sendable {
    case stored = 0
    case deflate = 8
}
