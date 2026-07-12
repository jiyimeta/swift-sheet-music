import Foundation
import SheetMusicCore
import SheetMusicPDF

// PDF import JNI entry point. Imports SheetMusicPDF (the Foundation-only
// Android subset: pure-Swift PDF reader → decode pipeline) — NOT SheetMusicLayout,
// to avoid the CGFloat clash the other bridges anchor around.

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeLoadScoreFromPDF(...)` call site. Parses a
/// MuseScore-exported vector PDF (3.x/4.x) into a `Score` and returns a
/// handle, mirroring `nativeLoadScore` for `.mscz` / `.mscx`. Returns 0 on
/// parse failure or empty input; the handle must be released via
/// `nativeReleaseScore`.
public func nativeLoadScoreFromPDF(bytes: Data) -> Int64 {
    guard !bytes.isEmpty else { return 0 }
    do {
        let score = try PDFImporter.parse(pdfData: bytes)
        return scoreTable.insert(score)
    } catch {
        return 0
    }
}
