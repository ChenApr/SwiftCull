import AppKit
import SwiftUI

/// Detect actual native scrolling (including trackpad momentum) without publishing
/// scroll offsets into SwiftUI on every frame. Only active/idle transitions escape.
struct GridScrollActivity: NSViewRepresentable {
    @Environment(\.gridThumbnailLoadingEnabled) private var isActive
    var onActivity: (Bool) -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.onActivity = onActivity
        view.attach()
        view.isActive = isActive
    }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }

    final class Anchor: NSView {
        var onActivity: ((Bool) -> Void)?
        private weak var scroll: NSScrollView?
        private var observer: NSObjectProtocol?
        private var idle: DispatchWorkItem?
        private var active = false
        private var previous = CGPoint.zero
        var isActive = true

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleAttach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleAttach() }
        override func layout() { super.layout(); attach() }

        private func scheduleAttach() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        func attach() {
            guard let enclosing = enclosingScrollView, enclosing !== scroll else { return }
            detach()
            scroll = enclosing
            previous = enclosing.contentView.bounds.origin
            enclosing.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: enclosing.contentView, queue: .main) { [weak self] _ in self?.boundsChanged() }
        }

        private func boundsChanged() {
            guard let origin = scroll?.contentView.bounds.origin, origin != previous else { return }
            previous = origin
            guard isActive else { return }
            if !active { active = true; onActivity?(true) }
            idle?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.active = false
                self.onActivity?(false)
            }
            idle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            idle?.cancel()
            idle = nil
            scroll = nil
            if active { active = false; onActivity?(false) }
        }
    }
}
