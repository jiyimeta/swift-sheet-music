import CDirect2D
import Foundation
import SheetMusicLayout

/// The font file DirectWrite draws the platform UI face from at `weight` and slant — the Segoe UI file
/// `cd2d_fill_text` fills the notation labels with (part labels, measure numbers, staff names, jumps), resolved the
/// way it resolves it — read whole, for a PDF of the score to embed: pass it as `ScorePDFFonts(system:)`, so the PDF's
/// labels are the screen's.
///
/// Nil when DirectWrite cannot resolve the face or its file cannot be read — a collection's member, a font not on disk.
/// Opens its own DirectWrite resources, so it may run on any thread, and reads the file each call: ask once per weight
/// and slant a document uses, which is how the PDF writer asks.
public func windowsSystemFontFile(weight: FontWeight, isItalic: Bool) -> Data? {
    var created: OpaquePointer?
    guard cd2d_resources_create(&created) == 0, let resources = created else { return nil }
    defer { cd2d_resources_destroy(resources) }
    let family = Array(WindowsFontMetricsProvider.systemFamily.utf16) + [0]
    // Room for a long path; a font under C:\Windows\Fonts or a user's font folder needs far less.
    var path = [UInt16](repeating: 0, count: 4096)
    var length: UInt32 = 0
    let hresult = family.withUnsafeBufferPointer { family in
        path.withUnsafeMutableBufferPointer { path in
            cd2d_font_file_path(
                resources, family.baseAddress, WindowsFontMetricsProvider.directWriteWeight(weight), isItalic ? 1 : 0,
                path.baseAddress, UInt32(path.count), &length,
            )
        }
    }
    guard hresult == 0 else { return nil }
    return try? Data(contentsOf: URL(fileURLWithPath: String(decoding: path.prefix(Int(length)), as: UTF16.self)))
}
