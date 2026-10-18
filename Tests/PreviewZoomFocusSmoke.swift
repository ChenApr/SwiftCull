import AppKit
import ImageIO

@main
enum PreviewZoomFocusSmoke {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 900, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = PhotoZoomScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        window.contentView = view
        window.orderFront(nil)
        Task { @MainActor in
            let paths = Array(CommandLine.arguments.dropFirst())
            for path in paths.isEmpty ? [""] : paths {
                let start = ProcessInfo.processInfo.systemUptime
                let image = await Task.detached { loadImage(path: path) }.value
                guard let image else { fatalError("Unable to decode \(path)") }
                let decodeMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                view.update(image: image, sourceID: path, request: nil)
                try! await Task.sleep(for: .milliseconds(100))
                view.layoutSubtreeIfNeeded()
                let photoPoint = CGPoint(x: view.photoView.bounds.width * 0.72,
                                         y: view.photoView.bounds.height * 0.35)
                let windowPoint = view.photoView.convert(photoPoint, to: nil)
                var reports = 0
                view.onScaleChange = { _ in reports += 1 }
                view.magnify(with: PinchEvent(delta: 0, phase: .began, point: windowPoint))
                var timings: [Double] = []
                var maxDrift: CGFloat = 0
                let replacement = NSImage(cgImage: image.cgImage(forProposedRect: nil, context: nil, hints: nil)!,
                                          size: image.size)
                for index in 0..<80 {
                    let eventStart = ProcessInfo.processInfo.systemUptime
                    let movedPointer = CGPoint(x: windowPoint.x + CGFloat(index) * 0.1, y: windowPoint.y)
                    view.magnify(with: PinchEvent(delta: 0.0095, phase: .changed, point: movedPointer))
                    // A repeated layout proposal must not recenter or retile the document.
                    view.setFrameSize(view.frame.size)
                    view.layoutSubtreeIfNeeded()
                    timings.append((ProcessInfo.processInfo.systemUptime - eventStart) * 1000)
                    if index == 20 { view.update(image: replacement, sourceID: path, request: nil) }
                    precondition(view.photoView.image === image, "Image replacement must wait until the pinch ends")
                    let actual = view.photoView.convert(photoPoint, to: nil)
                    maxDrift = max(maxDrift, hypot(actual.x - windowPoint.x, actual.y - windowPoint.y))
                    precondition(maxDrift < 1, "The original photo point drifted \(maxDrift) points during pinch")
                    try! await Task.sleep(for: .milliseconds(8))
                }
                precondition(reports == 0, "Pinch frames must not publish SwiftUI layout updates")
                view.magnify(with: PinchEvent(delta: 0, phase: .ended, point: windowPoint))
                try! await Task.sleep(for: .milliseconds(220))
                precondition(view.photoView.image === replacement)
                precondition(reports > 0, "The final percentage must publish after the gesture")

                view.zoom(to: 1, animated: false)
                try! await Task.sleep(for: .milliseconds(40))
                let buttonPoint = CGPoint(x: view.photoView.bounds.width * 0.65,
                                          y: view.photoView.bounds.height * 0.5)
                let pointer = view.photoView.convert(buttonPoint, to: nil)
                let move = NSEvent.mouseEvent(with: .mouseMoved, location: pointer, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!
                view.photoView.mouseMoved(with: move)
                view.update(image: replacement, sourceID: path, request: PhotoZoomRequest(increasing: true))
                var buttonDrift: CGFloat = 0
                for _ in 0..<24 {
                    try! await Task.sleep(for: .milliseconds(16))
                    let actual = view.photoView.convert(buttonPoint, to: nil)
                    buttonDrift = max(buttonDrift, hypot(actual.x - pointer.x, actual.y - pointer.y))
                }
                precondition(buttonDrift < 1, "Button zoom ignored the last photo pointer: \(buttonDrift)")
                // Interrupt a running button animation with a new pinch, then
                // shrink through the letterboxed range without losing its anchor.
                view.zoom(to: 4)
                try! await Task.sleep(for: .milliseconds(40))
                let downPoint = CGPoint(x: view.contentView.bounds.midX + 30,
                                        y: view.contentView.bounds.midY + 25)
                let downPointer = view.photoView.convert(downPoint, to: nil)
                view.magnify(with: PinchEvent(delta: 0, phase: .began, point: downPointer))
                var shrinkDrift: CGFloat = 0
                for _ in 0..<80 {
                    view.magnify(with: PinchEvent(delta: -0.018, phase: .changed, point: downPointer))
                    view.setFrameSize(view.frame.size)
                    let actual = view.photoView.convert(downPoint, to: nil)
                    shrinkDrift = max(shrinkDrift, hypot(actual.x - downPointer.x, actual.y - downPointer.y))
                    try! await Task.sleep(for: .milliseconds(8))
                }
                precondition(shrinkDrift < 1, "Shrink/pinch interruption lost focus: \(shrinkDrift)")
                view.magnify(with: PinchEvent(delta: 0, phase: .ended, point: downPointer))
                try! await Task.sleep(for: .milliseconds(220))
                precondition(abs(view.magnification - 1) < 0.001)
                precondition(abs(view.contentView.bounds.midX - view.photoView.frame.midX) < 1 &&
                             abs(view.contentView.bounds.midY - view.photoView.frame.midY) < 1,
                             "Fit must settle back to the center after shrinking")
                let sorted = timings.sorted()
                let label = path.isEmpty ? "generated" : URL(fileURLWithPath: path).lastPathComponent
                print(String(format: "%@: %.0fx%.0f, decode %.1f ms, pinch drift %.3f pt, button drift %.3f pt, shrink drift %.3f pt, native update p95 %.3f ms, max %.3f ms",
                             label, image.size.width, image.size.height, decodeMS, maxDrift, buttonDrift, shrinkDrift,
                             sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!))
            }
            print("Preview focus smoke passed: actual magnify handler, locked gesture anchor, pointer-based buttons, deferred image upload, coalesced feedback")
            window.orderOut(nil)
            exit(0)
        }
        app.run()
    }

    private nonisolated static func loadImage(path: String) -> NSImage? {
        if !path.isEmpty {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
            let size = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                           props[kCGImagePropertyPixelHeight] as? Int ?? 0)
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldCache: false]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        }
        let context = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        return NSImage(cgImage: context.makeImage()!, size: CGSize(width: 3000, height: 2000))
    }
}

private final class PinchEvent: NSEvent {
    let delta: CGFloat
    let eventPhase: NSEvent.Phase
    let point: CGPoint
    init(delta: CGFloat, phase: NSEvent.Phase, point: CGPoint) {
        self.delta = delta
        self.eventPhase = phase
        self.point = point
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var type: NSEvent.EventType { .magnify }
    override var magnification: CGFloat { delta }
    override var phase: NSEvent.Phase { eventPhase }
    override var locationInWindow: NSPoint { point }
}
