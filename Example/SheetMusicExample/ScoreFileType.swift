import Foundation
import UniformTypeIdentifiers

/// The score file formats the example app can open. Detection is
/// path-extension based so it works whether the user picks a file
/// from iCloud Drive (which sometimes hands us a generic
/// `public.data` UTI) or from local storage (which usually gives
/// us the right type directly).
enum ScoreFileType {
    case mscx
    case mscz
    case musicXML
    case mxl
    case midi

    /// UTI list passed to `.fileImporter`. We register custom
    /// `.mscx` / `.mscz` / `.mxl` types via `exportedTypeIdentifiers`
    /// in Info.plist so the document picker shows them as openable;
    /// when those aren't installed we fall back to `public.xml` and
    /// `public.archive` so users can still pick the files.
    static var allUTTypes: [UTType] {
        var out: [UTType] = []
        if let t = UTType(filenameExtension: "mscx") { out.append(t) }
        if let t = UTType(filenameExtension: "mscz") { out.append(t) }
        if let t = UTType(filenameExtension: "musicxml") {
            out.append(t)
        }
        if let t = UTType(filenameExtension: "mxl") { out.append(t) }
        // Generic XML and ZIP fallbacks — picker still shows the
        // file even if the system doesn't know our custom types.
        out.append(.midi)
        out.append(.xml)
        out.append(.zip)
        return out
    }

    /// Detect the score format from the URL's path extension.
    /// Falls back to `.mscx` for unrecognised .xml files (most are
    /// MusicXML embedded as plain XML).
    static func detect(url: URL) -> ScoreFileType? {
        switch url.pathExtension.lowercased() {
        case "mscx":
            return .mscx
        case "mscz":
            return .mscz
        case "musicxml", "xml":
            return .musicXML
        case "mxl":
            return .mxl
        case "mid", "midi":
            return .midi
        default:
            return nil
        }
    }
}
