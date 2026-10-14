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
            CropVersion(id: copy.versionID, name: copy.versionName, crop: crop)
        ]]
        try CropCatalog.save(versions, folder: root.path)
        precondition(CropCatalog.load(folder: root.path) == versions)
        print("Crop smoke passed: image geometry, orientation, JPEG/TIFF output, original copy, version naming, persistence")
    }
}
