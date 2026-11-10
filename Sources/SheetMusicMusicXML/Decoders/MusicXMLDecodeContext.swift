import SheetMusicFoundation
import SheetMusicXMLTools

/// Score-wide values a MusicXML reading needs deep inside a part, bound for the length of `Score.decodeMusicXML(_:)`.
enum MusicXMLDecodeContext {
    /// The score's staff space in millimeters, from `<defaults><scaling>` — `millimeters` per `tenths`, a staff space
    /// being ten tenths — as MuseScore's import sets `Sid::spatium` from it. `nil` outside a decode, and for a file
    /// with no usable scaling, in which case MuseScore keeps its default 1.75 mm (`defaultSpatiumMillimeters`).
    @TaskLocal static var spatiumMillimeters: Double?

    /// Whether the score carries beaming information (`MusicXMLStemBeam.hasBeamingInfo(root:)`), which leaves an eighth
    /// no beam holds unbeamed rather than to the meter. `false` outside a decode.
    @TaskLocal static var hasBeamingInfo = false

    /// MuseScore's default staff space, 1.75 mm (`Sid::spatium` 24.8 at 360 DPI), used when a file gives no scaling.
    static let defaultSpatiumMillimeters = 1.75

    /// The staff space `<defaults><scaling>` describes, or `nil` when it is absent or not positive.
    static func spatiumMillimeters(root: XMLTreeNode) -> Double? {
        guard let scaling = root.first("defaults")?.first("scaling"),
              let millimeters = scaling.first("millimeters").flatMap({ Double($0.text) }),
              let tenths = scaling.first("tenths").flatMap({ Double($0.text) }),
              millimeters > 0, tenths > 0
        else { return nil }
        return millimeters * 10 / tenths
    }

    /// A MusicXML length in tenths as staff spaces, at the score's scaling: MuseScore reads a `relative-x` as
    /// `tenths × 0.1 mm` (`* 0.1 * DPMM`) and stores it against `Sid::spatium`, so this is `tenths × 0.1` over the
    /// staff space in millimeters — not tenths over ten, unless the scaling is 1 mm to the staff space.
    static func spatiums(tenths: Double) -> Double {
        tenths * 0.1 / (spatiumMillimeters ?? defaultSpatiumMillimeters)
    }
}
