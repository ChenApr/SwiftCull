import AppKit
import QuartzCore
import SwiftUI

struct PhotoZoomRequest {
    enum Action {
        case scale(CGFloat)
        case step(increasing: Bool)
    }

    let id = UUID()
    let action: Action

    init(scale: CGFloat) { action = .scale(scale) }
    init(increasing: Bool) { action = .step(increasing: increasing) }
}

enum PhotoZoomSteps {
    static let values: [CGFloat] = [1, 1.5, 2, 3, 4, 6]

    static func next(from scale: CGFloat, increasing: Bool) -> CGFloat {
        if increasing { return values.first { $0 > scale + 0.01 } ?? 6 }
        return values.last { $0 < scale - 0.01 } ?? 1
    }
}

/// AppKit owns the live transform and scroll position. SwiftUI receives only the
/// displayed percentage; gesture frames never change image identity or decode size.
struct PhotoZoomViewport: NSViewRepresentable {
    let image: NSImage?
    let sourceID: String
    let request: PhotoZoomRequest?
    var onScaleChange: (CGFloat) -> Void
    var onSingleClick: () -> Void

    func makeNSView(context: Context) -> PhotoZoomScrollView {
        PhotoZoomScrollView()
    }

    func updateNSView(_ view: PhotoZoomScrollView, context: Context) {
        view.onScaleChange = onScaleChange
        view.onSingleClick = onSingleClick
        view.update(image: image, sourceID: sourceID, request: request)
    }
}

final class PhotoZoomScrollView: NSScrollView {
    let photoView = PhotoZoomImageView()
    private var sourceID: String?
    private var requestID: UUID?
    private var magnificationObservation: NSKeyValueObservation?
    private var reportingScheduled = false
    private var showsPanCursor = false
    private var fittedViewport = CGSize.zero
    private var fittedImage = CGSize.zero
    private var zoomTarget: CGFloat?
    private var animationID = UUID()
    private var gestureAnchor: CGPoint?
    private var gesturePhotoAnchor: CGPoint?
    private var lastPointerLocation: CGPoint?
    private var pendingImage: NSImage?
    private var isPanning = false
    private var lastScaleReportTime: TimeInterval = 0
    var onScaleChange: ((CGFloat) -> Void)?
    var onSingleClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = PhotoZoomClipView()
        contentView.drawsBackground = false
        drawsBackground = false
        borderType = .noBorder
        hasHorizontalScroller = false
        hasVerticalScroller = false
        horizontalScrollElasticity = .automatic
        verticalScrollElasticity = .automatic
        usesPredominantAxisScrolling = false
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 6
        photoView.zoomScroll = self
        photoView.imageScaling = .scaleProportionallyUpOrDown
        photoView.wantsLayer = true
        photoView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        documentView = photoView
        magnificationObservation = observe(\.magnification, options: [.new]) { [weak self] _, _ in
            self?.reportScale()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(image: NSImage?, sourceID: String, request: PhotoZoomRequest?) {
        if self.sourceID != sourceID {
            self.sourceID = sourceID
            // A command issued for the previous photo must not carry over.
            requestID = request?.id
            animationID = UUID()
            zoomTarget = nil
            gestureAnchor = nil
            gesturePhotoAnchor = nil
            pendingImage = nil
            lastPointerLocation = nil
            isPanning = false
            zoom(to: 1, centeredAt: .zero, animated: false)
            lastPointerLocation = nil
            photoView.image = nil
            fittedImage = .zero
            reportScale()
        }
        if photoView.image !== image {
            if let image, photoView.image != nil, gestureAnchor != nil || zoomTarget != nil || isPanning {
                // Uploading an original-size bitmap mid-gesture can stall the
                // compositor. Keep the existing texture until interaction ends.
                pendingImage = image
            } else {
                pendingImage = nil
                photoView.image = image
                fitDocument()
            }
        }
        if let request, request.id != requestID {
            requestID = request.id
            switch request.action {
            case .scale(let scale): zoom(to: scale)
            case .step(let increasing):
                zoom(to: PhotoZoomSteps.next(from: zoomTarget ?? magnification, increasing: increasing))
            }
        }
    }

    override func layout() {
        super.layout()
        fitDocument()
    }

    override func setFrameSize(_ newSize: NSSize) {
        // Percentage feedback can cause SwiftUI to propose the same frame on
        // every zoom tick. Retiling here would fight the focal-point transform.
        guard newSize != frame.size else { return }
        let center = relativeVisibleCenter()
        super.setFrameSize(newSize)
        tile()
        fitDocument(preserving: center)
    }

    private func relativeVisibleCenter() -> CGPoint {
        let size = photoView.frame.size
        return CGPoint(x: size.width > 0 ? contentView.bounds.midX / size.width : 0.5,
                       y: size.height > 0 ? contentView.bounds.midY / size.height : 0.5)
    }

    private func fitDocument(preserving savedCenter: CGPoint? = nil) {
        let viewport = contentView.frame.size
        guard viewport.width > 0, viewport.height > 0, let image = photoView.image,
              image.size.width > 0, image.size.height > 0 else { return }
        guard savedCenter != nil || viewport != fittedViewport || image.size != fittedImage else { return }
        let relativeCenter = savedCenter ?? relativeVisibleCenter()
        fittedViewport = viewport
        fittedImage = image.size
        let fit = min(viewport.width / image.size.width, viewport.height / image.size.height)
        photoView.setFrameSize(CGSize(width: image.size.width * fit, height: image.size.height * fit))
        let bounds = contentView.bounds
        contentView.scroll(to: CGPoint(x: relativeCenter.x * photoView.frame.width - bounds.width / 2,
                                      y: relativeCenter.y * photoView.frame.height - bounds.height / 2))
        reflectScrolledClipView(contentView)
    }

    func zoom(to value: CGFloat, centeredAt point: CGPoint? = nil, animated: Bool = true) {
        let target = min(max(value, minMagnification), maxMagnification)
        if let point { lastPointerLocation = photoView.convert(point, to: nil) }
        let center = point ?? focalPoint()
        let id = UUID()
        animationID = id
        zoomTarget = target
        (contentView as? PhotoZoomClipView)?.preservesAnchor = true
        if !animated || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Going through the animator also cancels any older AppKit property
            // animation. A direct setter alone lets that animation keep running.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                animator().setMagnification(target, centeredAt: center)
            }
            zoomTarget = nil
            settleBounds(animated: false)
            applyPendingImage()
            reportScale(force: true)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().setMagnification(target, centeredAt: center)
            } completionHandler: { [weak self] in
                guard let self, self.animationID == id else { return }
                self.zoomTarget = nil
                self.settleBounds(animated: true)
                self.applyPendingImage()
                self.reportScale(force: true)
            }
        }
    }

    override func magnify(with event: NSEvent) {
        magnify(by: event.magnification, at: event.locationInWindow, phase: event.phase)
    }

    /// Capture one window-space anchor for the entire pinch. Default scroll-view
    /// gesture handling does not guarantee the photo under the pointer stays put.
    func magnify(by delta: CGFloat, at windowPoint: CGPoint, phase: NSEvent.Phase) {
        if gestureAnchor == nil || phase.contains(.began) {
            gestureAnchor = windowPoint
            gesturePhotoAnchor = photoView.convert(windowPoint, from: nil)
            (contentView as? PhotoZoomClipView)?.preservesAnchor = true
            recordFocus(at: windowPoint)
            if zoomTarget != nil { zoom(to: magnification, animated: false) }
        }
        let anchor = gesturePhotoAnchor ?? photoView.convert(windowPoint, from: nil)
        let target = min(max(magnification * max(0.01, 1 + delta), minMagnification), maxMagnification)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setMagnification(target, centeredAt: anchor)
        // Preserve the initial photo point, including the letterboxed axis.
        // Recomputing a new photo point each tick accumulates clamp/rounding drift.
        let actual = photoView.convert(gestureAnchor ?? windowPoint, from: nil)
        contentView.scroll(to: CGPoint(x: contentView.bounds.origin.x + anchor.x - actual.x,
                                      y: contentView.bounds.origin.y + anchor.y - actual.y))
        reflectScrolledClipView(contentView)
        CATransaction.commit()
        if phase.contains(.ended) || phase.contains(.cancelled) || phase.isEmpty {
            gestureAnchor = nil
            gesturePhotoAnchor = nil
            settleBounds(animated: true)
            applyPendingImage()
            reportScale(force: true)
        }
    }

    func recordFocus(at windowPoint: CGPoint) {
        lastPointerLocation = windowPoint
    }

    private func focalPoint() -> CGPoint {
        if let lastPointerLocation, bounds.contains(convert(lastPointerLocation, from: nil)) {
            let point = photoView.convert(lastPointerLocation, from: nil)
            return CGPoint(x: min(max(point.x, 0), photoView.bounds.width),
                           y: min(max(point.y, 0), photoView.bounds.height))
        }
        return CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }

    func setPanning(_ value: Bool) {
        isPanning = value
        if !value { applyPendingImage() }
    }

    private func applyPendingImage() {
        guard gestureAnchor == nil, zoomTarget == nil, !isPanning, let pendingImage else { return }
        self.pendingImage = nil
        photoView.image = pendingImage
        fitDocument()
    }

    private func settleBounds(animated: Bool) {
        guard gestureAnchor == nil, zoomTarget == nil else { return }
        (contentView as? PhotoZoomClipView)?.preservesAnchor = false
        let origin = contentView.constrainBoundsRect(contentView.bounds).origin
        guard origin != contentView.bounds.origin else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.18 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(origin)
        }
    }

    func toggleZoom(at point: CGPoint) {
        let pixelScale = window?.backingScaleFactor ?? 2
        let actualSize = (photoView.image?.size.width ?? 0) / max(1, photoView.frame.width * pixelScale)
        zoom(to: magnification > 1.01 ? 1 : min(6, max(2, actualSize)), centeredAt: point)
    }

    private func reportScale(force: Bool = false) {
        // The native transform remains at input/display cadence. Publishing a
        // SwiftUI state change for every pinch sample needlessly relays out chrome.
        guard gestureAnchor == nil else { return }
        if !force, zoomTarget != nil, ProcessInfo.processInfo.systemUptime - lastScaleReportTime < 0.05 { return }
        guard !reportingScheduled else { return }
        reportingScheduled = true
        // KVO may fire during updateNSView. Coalesce reports outside that update
        // and read the latest value, avoiding stale SwiftUI writes during a pinch.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportingScheduled = false
            guard self.gestureAnchor == nil else { return }
            self.lastScaleReportTime = ProcessInfo.processInfo.systemUptime
            self.onScaleChange?(self.magnification)
            let showsPanCursor = self.magnification > 1.01
            if self.showsPanCursor != showsPanCursor {
                self.showsPanCursor = showsPanCursor
                self.window?.invalidateCursorRects(for: self.photoView)
            }
        }
    }
}

private final class PhotoZoomClipView: NSClipView {
    var preservesAnchor = false

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        if preservesAnchor { return proposedBounds }
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if documentView.frame.width < result.width {
            result.origin.x = (documentView.frame.width - result.width) / 2
        }
        if documentView.frame.height < result.height {
            result.origin.y = (documentView.frame.height - result.height) / 2
        }
        return result
    }
}

final class PhotoZoomImageView: NSImageView {
    weak var zoomScroll: PhotoZoomScrollView?
    private var dragOrigin: CGPoint?
    private var scrollOrigin = CGPoint.zero
    private var focusTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        if let focusTrackingArea { removeTrackingArea(focusTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        focusTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) { zoomScroll?.recordFocus(at: event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { zoomScroll?.recordFocus(at: event.locationInWindow) }

    override func resetCursorRects() {
        if let zoomScroll, zoomScroll.magnification > 1.01 {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let zoomScroll else { return }
        zoomScroll.recordFocus(at: event.locationInWindow)
        zoomScroll.onSingleClick?()
        if event.clickCount == 2 {
            zoomScroll.toggleZoom(at: convert(event.locationInWindow, from: nil))
        } else if zoomScroll.magnification > 1.01 {
            dragOrigin = event.locationInWindow
            scrollOrigin = zoomScroll.contentView.bounds.origin
            zoomScroll.setPanning(true)
            NSCursor.closedHand.push()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let zoomScroll, let dragOrigin else { return }
        let factor = zoomScroll.magnification
        zoomScroll.contentView.scroll(to: CGPoint(
            x: scrollOrigin.x - (event.locationInWindow.x - dragOrigin.x) / factor,
            y: scrollOrigin.y - (event.locationInWindow.y - dragOrigin.y) / factor))
        zoomScroll.reflectScrolledClipView(zoomScroll.contentView)
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil { NSCursor.pop() }
        dragOrigin = nil
        zoomScroll?.setPanning(false)
    }
}
