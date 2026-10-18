import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum PreviewZoomSmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let context = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        context.setFillColor(NSColor.systemOrange.cgColor)
        context.fill(CGRect(x: 1500, y: 0, width: 1500, height: 2000))
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 3000, height: 2000))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PhotoZoomScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = view
        window.orderFront(nil)
        view.update(image: image, sourceID: "first", request: nil)

        Task { @MainActor in
            try! await Task.sleep(for: .milliseconds(80))
            view.layoutSubtreeIfNeeded()
            precondition(abs(view.photoView.frame.width - 900) < 1)
            precondition(abs(view.photoView.frame.height - 600) < 1)
            precondition(abs(view.contentView.bounds.midY - 300) < 1, "Fit must center the actual image")
            let photoView = view.photoView
            let focalPoint = CGPoint(x: 350, y: 320)
            let screenPoint = photoView.convert(focalPoint, to: nil)
            view.zoom(to: 2, centeredAt: focalPoint)
            var samples: [CGFloat] = []
            for _ in 0..<30 {
                try! await Task.sleep(for: .milliseconds(16))
                samples.append(view.magnification)
            }
            precondition(abs(view.magnification - 2) < 0.001)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                precondition(samples.contains { $0 > 1.02 && $0 < 1.98 },
                             "Button zoom must render intermediate magnifications")
            }
            let movedPoint = photoView.convert(focalPoint, to: nil)
            precondition(hypot(screenPoint.x - movedPoint.x, screenPoint.y - movedPoint.y) < 2,
                         "Zoom must keep its focal point under the same screen location")
            precondition(view.photoView === photoView && photoView.image === image,
                         "Zoom must reuse the decoded image and native image view")

            // Rapid commands advance from the pending target, not an intermediate animation frame.
            view.update(image: image, sourceID: "first", request: PhotoZoomRequest(increasing: true))
            view.update(image: image, sourceID: "first", request: PhotoZoomRequest(increasing: true))
            try! await Task.sleep(for: .milliseconds(400))
            precondition(abs(view.magnification - 4) < 0.001, "Rapid plus clicks must advance two steps")

            // A new photo must also cancel an in-flight zoom animation.
            view.zoom(to: 6)
            try! await Task.sleep(for: .milliseconds(40))
            view.update(image: image, sourceID: "second", request: nil)
            try! await Task.sleep(for: .milliseconds(400))
            precondition(abs(view.magnification - 1) < 0.001, "A new photo must start at fit without stale animation")

            view.zoom(to: 3, animated: false)
            let originalCenter = CGPoint(x: view.contentView.bounds.midX / photoView.frame.width,
                                         y: view.contentView.bounds.midY / photoView.frame.height)
            window.setContentSize(NSSize(width: 700, height: 640))
            try! await Task.sleep(for: .milliseconds(80))
            let resizedCenter = CGPoint(x: view.contentView.bounds.midX / photoView.frame.width,
                                        y: view.contentView.bounds.midY / photoView.frame.height)
            precondition(abs(originalCenter.x - resizedCenter.x) < 0.01 &&
                         abs(originalCenter.y - resizedCenter.y) < 0.01,
                         "Resize must preserve the viewed region: \(originalCenter) -> \(resizedCenter)")

            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                view.zoom(to: 1, animated: false)
                try! await Task.sleep(for: .milliseconds(30))
                precondition(abs(view.contentView.bounds.midX - photoView.frame.midX) < 1)
                precondition(abs(view.contentView.bounds.midY - photoView.frame.midY) < 1)
            }
            view.zoom(to: 20, animated: false)
            try! await Task.sleep(for: .milliseconds(20))
            precondition(abs(view.magnification - 6) < 0.001)
            view.zoom(to: 0.1, animated: false)
            try! await Task.sleep(for: .milliseconds(20))
            precondition(abs(view.magnification - 1) < 0.001)
            precondition(PhotoZoomSteps.next(from: 1.73, increasing: true) == 2)
            precondition(PhotoZoomSteps.next(from: 1.73, increasing: false) == 1.5)
            await checkImageLoading(in: window, image: context.makeImage()!)
            print("Preview zoom smoke passed: intermediate frames, focal point, image reuse, rapid commands, photo reset, resize, bounds, light/dark")
            print("Animation samples: \(samples.prefix(18).map { String(format: "%.3f", $0) }.joined(separator: ", "))")
            window.orderOut(nil)
            exit(0)
        }
        app.run()
    }

    @MainActor
    static func checkImageLoading(in window: NSWindow, image: CGImage) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewZoom-\(UUID())")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("photo.jpg")
        let output = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil)
        precondition(CGImageDestinationFinalize(output))
        let date = Date()
        let photo = PhotoEntry(baseName: "photo", jpgPath: source.path, nefPath: nil, movPath: nil,
                               jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                               fileDate: date, modificationDate: date)
        let model = PreviewZoomTestModel(photo: photo)
        let host = NSHostingView(rootView: PreviewZoomTestView(model: model))
        window.contentView = host
        var viewport: PhotoZoomScrollView?
        for _ in 0..<100 {
            viewport = zoomView(in: host)
            if (viewport?.photoView.image?.size.width ?? 0) > 960 { break }
            try! await Task.sleep(for: .milliseconds(30))
        }
        guard let viewport, let fitted = viewport.photoView.image else { fatalError("No fitted image") }
        precondition(fitted.size.width < 3000, "Fit viewing should not decode an unnecessary original")
        model.request = PhotoZoomRequest(scale: 3)
        for _ in 0..<100 {
            if viewport.photoView.image?.size.width == 3000 { break }
            try! await Task.sleep(for: .milliseconds(30))
        }
        let decoded = viewport.photoView.image!
        precondition(decoded.size.width == 3000, "Zooming must request original pixels when needed")
        for scale: CGFloat in [1.5, 2, 3, 6, 1] {
            model.request = PhotoZoomRequest(scale: scale)
            try! await Task.sleep(for: .milliseconds(350))
            precondition(abs(viewport.magnification - scale) < 0.001)
            precondition(viewport.photoView.image === decoded, "Zoom tiers must not restart image decoding")
        }
        model.request = PhotoZoomRequest(scale: 6)
        try! await Task.sleep(for: .milliseconds(40))
        model.photo = photo.asVersion(CropVersion(id: UUID(), name: "crop",
                                                  crop: CropRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        try! await Task.sleep(for: .milliseconds(400))
        model.request = PhotoZoomRequest(scale: 3)
        for _ in 0..<100 {
            if viewport.photoView.image?.size == NSSize(width: 1500, height: 2000) { break }
            try! await Task.sleep(for: .milliseconds(30))
        }
        try! await Task.sleep(for: .milliseconds(300))
        precondition(viewport.photoView.image?.size == NSSize(width: 1500, height: 2000),
                     "The selected crop must load at full resolution")
        precondition(abs(viewport.magnification - 3) < 0.001, "Detail upgrade must preserve the zoom transform")
        print("Preview loading passed: progressive decode, stable image across zoom tiers, full-resolution crop, stale animation cancellation")
    }

    @MainActor
    static func zoomView(in view: NSView) -> PhotoZoomScrollView? {
        if let zoom = view as? PhotoZoomScrollView { return zoom }
        return view.subviews.lazy.compactMap { zoomView(in: $0) }.first
    }
}

private final class PreviewZoomTestModel: ObservableObject {
    @Published var photo: PhotoEntry
    @Published var request: PhotoZoomRequest?
    init(photo: PhotoEntry) { self.photo = photo }
}

private struct PreviewZoomTestView: View {
    @ObservedObject var model: PreviewZoomTestModel
    @State private var scale: CGFloat = 1
    var body: some View {
        DetailThumbnailView(photo: model.photo, zoomRequest: model.request, scale: $scale, onSingleClick: {})
    }
}
