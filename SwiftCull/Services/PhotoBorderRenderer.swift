import AppKit

enum PhotoBorderRenderer {
    static func render(image: CGImage, configuration: PhotoBorderConfiguration) throws -> SemiWatermarkRenderer.RenderedCanvas {
        guard configuration.isValid else { throw BorderError.invalidConfiguration }
        let layout = configuration.layout(photoSize: CGSize(width: image.width, height: image.height))
        let width = Int(layout.canvas.width)
        let height = Int(layout.canvas.height)
        guard width > 0, height > 0, width <= 30_000, height <= 30_000,
              width * height <= 180_000_000 else { throw BorderError.canvasTooLarge }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw WatermarkError.encodingFailed
        }
        context.setFillColor(configuration.color.cgColor)
        context.fill(CGRect(origin: .zero, size: layout.canvas))
        context.draw(image, in: layout.photoRect)
        guard let rendered = context.makeImage() else { throw WatermarkError.encodingFailed }
        return SemiWatermarkRenderer.RenderedCanvas(bitmap: NSBitmapImageRep(cgImage: rendered),
                                                    photoRect: layout.photoRect)
    }

    enum BorderError: LocalizedError {
        case invalidConfiguration, canvasTooLarge
        var errorDescription: String? {
            switch self {
            case .invalidConfiguration: return "边框参数无效，请重新选择比例、宽度或颜色。"
            case .canvasTooLarge: return "当前边框画布过大，请减小留白或选择更接近照片的比例。"
            }
        }
    }
}
