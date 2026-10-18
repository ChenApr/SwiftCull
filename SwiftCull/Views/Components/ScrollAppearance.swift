import SwiftUI
import AppKit

extension View {
    /// Apply inside scroll content so only its enclosing native scroll view changes.
    func subtleScrollbars(hidden: Bool = false) -> some View {
        background(ScrollAppearance(hidden: hidden))
    }
}

private struct ScrollAppearance: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.hiddenIndicators = hidden
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.hiddenIndicators = hidden
        view.scheduleUpdate()
    }

    final class AnchorView: NSView {
        var hiddenIndicators = false
        private var updateScheduled = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleUpdate()
        }

        override func layout() {
            super.layout()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !updateScheduled else { return }
            updateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateScheduled = false
                guard let scroll = self.enclosingScrollView else { return }
                if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
                if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
                if scroll.hasVerticalScroller == self.hiddenIndicators {
                    scroll.hasVerticalScroller = !self.hiddenIndicators
                }
                if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
                if scroll.verticalScroller?.controlSize != .small { scroll.verticalScroller?.controlSize = .small }
            }
        }
    }
}
