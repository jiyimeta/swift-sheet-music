// The single choke point for what every portable target used to get from
// `import Foundation`.
//
// That is a wider surface than the Foundation module itself, and deliberately so:
// the umbrella re-exports the platform C library and Dispatch, so dropping it takes
// `cos` and `DispatchQueue` with it. Anything in that category belongs here — see
// the libm re-export below and `SerialLock.swift`.
//
// On platforms that ship swift-foundation's `FoundationEssentials` as a module
// of its own (WASI, Linux, Android) this imports that, avoiding the
// ICU-carrying `Foundation` umbrella — measured on wasm at ~13 MB brotli
// against ~2.9 MB for `FoundationEssentials`. Apple platforms have no such
// module and fall back to `Foundation`, where the types are the same ones
// anyway.
//
// Portable targets (`SheetMusicCore`, `SheetMusicXMLTools`, `SheetMusicZip`,
// `SheetMusicMIDI`, `SheetMusicMSCX`, `SheetMusicMusicXML`, `SheetMusicLayout`,
// `SheetMusicAudioCore`, `SheetMusicEditWire`, `SheetMusic`) import this
// instead of `Foundation` directly. Apple-only targets keep importing
// `Foundation`, since they already depend on much heavier Apple frameworks.
//
// A plain `import Foundation` in a portable target still compiles everywhere,
// so nothing complains when it drifts back — the wasm size check in
// `Scripts/wasm-size.sh` is what catches that.
#if canImport(FoundationEssentials)
    @_exported import FoundationEssentials
#else
    @_exported import Foundation
#endif

// `Foundation` re-exports the platform C library, so code that said
// `import Foundation` also got `cos`, `pow`, `sqrt` and friends.
// `FoundationEssentials` does not, so the shim has to supply them or the
// FoundationEssentials branch fails to compile wherever the renderers do
// trigonometry (`MidiRenderer+GlissandoMath`, the layout geometry helpers).
#if canImport(Darwin)
    @_exported import Darwin
#elseif canImport(Android)
    @_exported import Android
#elseif canImport(Glibc)
    @_exported import Glibc
#elseif canImport(Musl)
    @_exported import Musl
#elseif canImport(WASILibc)
    @_exported import WASILibc
#endif

/// `CharacterSet` is one of the pieces `FoundationEssentials` does not carry, so
/// the two `trimmingCharacters(in:)` sets this package uses are reproduced here
/// from the stdlib's own Unicode tables. Defining them by general category
/// rather than by a hand-written range list is what keeps them exactly equal to
/// Foundation's, which documents the same categories.
///
/// Trimming is done at scalar level on purpose: a combining mark following a
/// space forms one non-whitespace grapheme, so a `Character`-based trim would
/// disagree at the boundary.
extension StringProtocol {
    /// Equivalent of `trimmingCharacters(in: .whitespaces)`: Unicode space
    /// separators (category Zs) plus the tab, and deliberately not newlines.
    public func trimmingHorizontalWhitespace() -> String {
        trimming(Self.isHorizontalWhitespace)
    }

    /// U+200B is the one member Foundation's `.whitespaces` has that the
    /// category lookup does not: it was `Zs` in early Unicode and was
    /// reclassified to `Cf`, and Foundation kept the original membership.
    /// The scalar sweep in `TrimmingHelpersTests` is what turned this up.
    private static func isHorizontalWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x09
            || scalar.value == 0x200B
            || scalar.properties.generalCategory == .spaceSeparator
    }

    /// Equivalent of `trimmingCharacters(in: .whitespacesAndNewlines)`: the
    /// horizontal set above plus the line separators (U+000A–U+000D, U+0085,
    /// U+2028, U+2029).
    public func trimmingWhitespaceAndNewlines() -> String {
        trimming { scalar in
            switch scalar.value {
            case 0x0A ... 0x0D, 0x85, 0x2028, 0x2029:
                true
            default:
                Self.isHorizontalWhitespace(scalar)
            }
        }
    }

    /// Equivalent of `trimmingCharacters(in: .controlCharacters)`: Unicode
    /// categories Cc and Cf.
    public func trimmingControlCharacters() -> String {
        trimming { scalar in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format
        }
    }

    private func trimming(_ shouldTrim: (Unicode.Scalar) -> Bool) -> String {
        let scalars = unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, shouldTrim(scalars[start]) {
            start = scalars.index(after: start)
        }
        while start < end {
            let previous = scalars.index(before: end)
            guard shouldTrim(scalars[previous]) else { break }
            end = previous
        }
        return String(String.UnicodeScalarView(scalars[start ..< end]))
    }
}
