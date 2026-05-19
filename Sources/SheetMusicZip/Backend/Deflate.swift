import Foundation

/// Platform-dispatched raw-DEFLATE codec (RFC 1951, no zlib header,
/// no Adler32). Implementation lives in `DeflateApple.swift`
/// (`#if canImport(Compression)`) or `DeflateZLib.swift` (`#else`).
enum Deflate {}
