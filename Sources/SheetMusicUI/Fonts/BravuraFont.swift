#if os(macOS)
import CoreText
import Foundation

/// Runtime registration of the bundled Bravura SMuFL font.
///
/// Registration is process-scoped — it does not affect system font caches
/// outside the host application.
@available(macOS 15.0, *)
enum BravuraFont {
    /// Font family name as reported by CoreText once registered.
    static let familyName = "Bravura"

    /// Trigger registration by reading this property once. Subsequent reads
    /// are no-ops (Swift `static let` is lazy + thread-safe).
    static let register: Void = {
        guard let url = Bundle.module.url(
            forResource: "Bravura",
            withExtension: "otf"
        ) else {
            return
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    }()
}
#endif
