import AppKit

/// Decoding stays off-main. During a scroll, new image state is committed in small
/// batches instead of invalidating dozens of cells in the same display frame.
@MainActor
final class GridImageDelivery {
    static let shared = GridImageDelivery()
    private var pending: [UUID: () -> Void] = [:]
    private var drainTask: Task<Void, Never>?
    private(set) var isScrolling = false

    func setScrolling(_ scrolling: Bool) {
        isScrolling = scrolling
        if !scrolling { scheduleDrain() }
    }

    func submit(id: UUID, update: @escaping () -> Void) {
        if !isScrolling && pending.isEmpty { update(); return }
        pending[id] = update
        scheduleDrain()
    }

    func cancel(id: UUID) { pending.removeValue(forKey: id) }

    private func scheduleDrain() {
        guard drainTask == nil, !pending.isEmpty else { return }
        drainTask = Task { [weak self] in
            while let self, !self.pending.isEmpty {
                // Keep first-pass scrolling populated, but do not deliver an
                // entire row of decoded images as one burst of SwiftUI updates.
                do { try await Task.sleep(for: .milliseconds(self.isScrolling ? 16 : 8)) }
                catch { break }
                let ids = Array(self.pending.keys.prefix(self.isScrolling ? 2 : 6))
                for id in ids { self.pending.removeValue(forKey: id)?() }
            }
            self?.drainTask = nil
        }
    }
}
