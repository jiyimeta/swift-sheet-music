#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutEngine {
    /// Pixels per spatium at MuseScore's default spatium (1.75 mm at 1200 dpi: `image.cpp`, `mscore.h`).
    private static let pixelsPerSpatium: CGFloat = 82.677
    /// Pixels per millimetre at the same resolution.
    private static let pixelsPerMillimetre: CGFloat = 47.244

    /// The pictures of a `<VBox>`, sized and placed relative to the box's top (`tlayout.cpp:3245-3285`). A payload
    /// `ImageSniffer` cannot read, an SVG, or a path missing from `pictures` yields nothing, as does a picture whose
    /// size comes out empty. `fitHeight` is the box height an `autoScale` picture is fitted into, in points.
    static func layoutImages(
        of frame: ScoreFrame,
        pictures: [String: Data],
        docWidth: CGFloat,
        fitHeight: CGFloat,
        sp: CGFloat,
    ) -> [LayoutFrameImage] {
        frame.images.compactMap { image in
            guard let data = pictures[image.path], let info = ImageSniffer.sniff(data) else { return nil }
            let size = imageSize(image, info: info, docWidth: docWidth, fitHeight: fitHeight, sp: sp)
            guard size.width > 0, size.height > 0 else { return nil }
            let origin = CGPoint(x: (image.offsetSp?.x ?? 0) * sp, y: (image.offsetSp?.y ?? 0) * sp)
            let format: LayoutFrameImage.Format = info.format == .png ? .png : .jpeg
            return LayoutFrameImage(data: data, format: format, rect: CGRect(origin: origin, size: size))
        }
    }

    private static func imageSize(
        _ image: FrameImage, info: ImageInfo, docWidth: CGFloat, fitHeight: CGFloat, sp: CGFloat,
    ) -> CGSize {
        let mmToPt: CGFloat = 72.0 / 25.4
        let nativeWidth = CGFloat(info.width)
        let nativeHeight = CGFloat(info.height)
        if image.autoScale {
            guard image.lockAspectRatio else { return CGSize(width: docWidth, height: fitHeight) }
            let scale = min(docWidth / nativeWidth, fitHeight / nativeHeight)
            return CGSize(width: nativeWidth * scale, height: nativeHeight * scale)
        }
        if let size = image.size {
            let unit = image.sizeIsSpatium ? sp : mmToPt
            return CGSize(width: size.width * unit, height: size.height * unit)
        }
        if image.sizeIsSpatium {
            return CGSize(width: nativeWidth / pixelsPerSpatium * sp, height: nativeHeight / pixelsPerSpatium * sp)
        }
        return CGSize(
            width: nativeWidth / pixelsPerMillimetre * mmToPt, height: nativeHeight / pixelsPerMillimetre * mmToPt,
        )
    }
}
