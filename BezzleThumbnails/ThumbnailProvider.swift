import ImageIO
import QuickLookThumbnailing

/// Gives the Finder its thumbnails of designs: the picture Bezzle keeps in each design's package
/// (Bezzle/Store/DesignPreview.swift), laid on a sheet of Bezzle's paper with its corner folded
/// over. A design without one shows the design's icon.
final class ThumbnailProvider: QLThumbnailProvider {
    /// Where in the package Bezzle keeps the picture: `DesignPreview.folderName` and `fileName`.
    static let picturePath = "QuickLook/Thumbnail.jpg"

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL.appendingPathComponent(Self.picturePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = full[kCGImagePropertyPixelWidth] as? CGFloat, let height = full[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else {
            handler(nil, CocoaError(.fileReadNoSuchFile))
            return
        }
        let sheet = Sheet(aspect: width / height)
        let size = sheet.size(fitting: request.maximumSize)
        // Read no larger than it is drawn.
        let pixels = Int((max(size.width, size.height) * request.scale).rounded(.up))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: pixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true]
        guard let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        handler(QLThumbnailReply(contextSize: size) { ctx in
            sheet.draw(picture, in: ctx, size: size)
            return true
        }, nil)
    }
}
