import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum CropSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftCull-CropSmoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? CropCatalog.remove(folder: root.path) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context") }
        context.setFillColor(NSColor.red.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 80))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 50, y: 0, width: 50, height: 80))
        guard let fullImage = context.makeImage() else { fatalError("image") }
        let original = root.appendingPathComponent("test.jpg")
        guard let destination = CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            fatalError("destination")
        }
        CGImageDestinationAddImage(destination, fullImage, nil)
        precondition(CGImageDestinationFinalize(destination))

        let crop = CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
        let canvas = CGSize(width: 800, height: 600)
        let displayImage = CGSize(width: 1200, height: 800)
        let fittedPan = CropViewport.clampedPan(CGSize(width: 500, height: -500),
                                                canvas: canvas, image: displayImage, zoom: 1)
        precondition(fittedPan == .zero)
        let zoomedPan = CropViewport.clampedPan(CGSize(width: 500, height: -500),
                                                canvas: canvas, image: displayImage, zoom: 2)
        precondition(abs(zoomedPan.width - 400) < 0.001)
        precondition(abs(zoomedPan.height + 233.33333333333337) < 0.001)
        let zoomedFrame = CropViewport.imageFrame(canvas: canvas, image: displayImage,
                                                   zoom: 2, pan: zoomedPan)
        precondition(abs(zoomedFrame.minX) < 0.001)
        precondition(abs(zoomedFrame.maxY - canvas.height) < 0.001)
        precondition(CropAspectRatio.allCases.map(\.title) ==
                     ["自由", "原始比例", "1:1", "3:2", "4:3", "16:9"])
        let square = CropGeometry.fitted(.full, imageWidth: 1200, imageHeight: 800,
                                         aspect: .square)
        precondition(abs(square.width * 1200 - square.height * 800) < 0.001)
        let resizedSquare = CropGeometry.resized(square, dx: -0.1, dy: 0,
                                                 right: true, bottom: true,
                                                 normalizedRatio: 800.0 / 1200)
        precondition(abs(resizedSquare.width * 1200 - resizedSquare.height * 800) < 0.001)
        precondition(CropAspectRatio.threeTwo.imageRatio(width: 800, height: 1200)! == 2.0 / 3)
        let portraitWide = CropGeometry.fitted(.full, imageWidth: 800, imageHeight: 1200,
                                               aspect: .sixteenNine)
        precondition(abs((portraitWide.width * 800) / (portraitWide.height * 1200) - 9.0 / 16) < 0.001)
        for (imageWidth, imageHeight) in [(1200, 800), (800, 1200)] {
            for mode in CropAspectRatio.allCases where mode != .free {
                let frame = CropGeometry.fitted(.full, imageWidth: imageWidth,
                                                imageHeight: imageHeight, aspect: mode)
                let normalizedRatio = mode.imageRatio(width: imageWidth, height: imageHeight)!
                    * Double(imageHeight) / Double(imageWidth)
                for right in [false, true] {
                    for bottom in [false, true] {
                        let edited = CropGeometry.resized(frame, dx: right ? -0.12 : 0.12,
                                                          dy: bottom ? -0.08 : 0.08,
                                                          right: right, bottom: bottom,
                                                          normalizedRatio: normalizedRatio)
                        precondition(edited.x >= 0 && edited.y >= 0 &&
                                     edited.x + edited.width <= 1.000_001 &&
                                     edited.y + edited.height <= 1.000_001)
                        precondition(abs(edited.width / edited.height - normalizedRatio) < 0.001)
                    }
                }
            }
        }
        let now = Date()
        var photo = PhotoEntry(baseName: "test", jpgPath: original.path, nefPath: nil, movPath: nil,
                               jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                               fileDate: now, modificationDate: now)
        photo.cropRect = crop
        let cropped = try CropImageService.image(path: original.path, crop: crop)
        precondition(cropped.width == 50 && cropped.height == 80)

        let output = try CropImageService.write(photo: photo, sourcePath: original.path, into: root.appendingPathComponent("out"))
        let reloaded = try CropImageService.image(path: output.path)
        precondition(reloaded.width == 50 && reloaded.height == 80)

        var unedited = photo
        unedited.cropRect = nil
        let untouched = try CropImageService.copyOrRender(photo: unedited, sourcePath: original.path,
                                                           into: root.appendingPathComponent("uncut"))
        let originalData = try Data(contentsOf: original)
        let untouchedData = try Data(contentsOf: untouched)
        precondition(originalData == untouchedData)

        let rotatedURL = root.appendingPathComponent("rotated.jpg")
        guard let rotatedDestination = CGImageDestinationCreateWithURL(rotatedURL as CFURL,
                                                                       UTType.jpeg.identifier as CFString, 1, nil) else {
            fatalError("rotated destination")
        }
        CGImageDestinationAddImage(rotatedDestination, fullImage,
                                   [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(rotatedDestination))
        let oriented = try CropImageService.image(path: rotatedURL.path)
        precondition(oriented.width == 80 && oriented.height == 100)
        let orientedDimensions = try CropImageService.orientedDimensions(path: rotatedURL.path)
        precondition(orientedDimensions.width == 80 && orientedDimensions.height == 100)
        let orientedCrop = try CropImageService.image(path: rotatedURL.path,
                                                      crop: CropRect(x: 0, y: 0, width: 0.5, height: 1))
        precondition(orientedCrop.width == 40 && orientedCrop.height == 100)

        let rawSource = root.appendingPathComponent("test-source.tiff")
        guard let rawDestination = CGImageDestinationCreateWithURL(rawSource as CFURL,
                                                                   UTType.tiff.identifier as CFString, 1, nil) else {
            fatalError("raw destination")
        }
        CGImageDestinationAddImage(rawDestination, fullImage, nil)
        precondition(CGImageDestinationFinalize(rawDestination))
        var paired = PhotoEntry(baseName: "test-source", jpgPath: original.path, nefPath: rawSource.path,
                                movPath: nil, jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                                fileDate: now, modificationDate: now)
        paired.cropRect = crop
        let rawOutput = try CropImageService.write(photo: paired, sourcePath: rawSource.path,
                                                    into: root.appendingPathComponent("raw-out"))
        precondition(rawOutput.pathExtension == "tiff")
        let renderedRaw = try CropImageService.image(path: rawOutput.path)
        precondition(renderedRaw.width == 50 && renderedRaw.height == 80)

        let copy = photo.asVersion(CropVersion(id: UUID(), name: "右侧", crop: crop))
        let copyOutput = try CropImageService.write(photo: copy, sourcePath: original.path,
                                                    into: root.appendingPathComponent("out"))
        precondition(copyOutput != output)
        let versions: [String: [CropVersion]] = ["test": [
            CropVersion(id: nil, name: nil, crop: nil),
            CropVersion(id: copy.versionID, name: copy.versionName, crop: crop, aspect: .threeTwo)
        ]]
        try CropCatalog.save(versions, folder: root.path)
        precondition(CropCatalog.load(folder: root.path) == versions)
        let legacy = "{\"id\":null,\"name\":null,\"crop\":null}".data(using: .utf8)!
        let oldVersion = try JSONDecoder().decode(CropVersion.self, from: legacy)
        precondition(oldVersion.aspect == nil)
        print("Crop smoke passed: ratios, image geometry, orientation, JPEG/TIFF output, original copy, version naming, persistence")
    }
}
