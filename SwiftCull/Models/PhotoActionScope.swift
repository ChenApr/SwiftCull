import Foundation

/// Resolves the targets before a context action runs, in the same order as the visible grid.
enum PhotoActionScope {
    static func targets(clicked: PhotoEntry?, selectedIDs: Set<String>,
                        visiblePhotos: [PhotoEntry], fallback: PhotoEntry?,
                        useSelection: Bool) -> [PhotoEntry] {
        if let clicked {
            if useSelection, selectedIDs.count > 1, selectedIDs.contains(clicked.id) {
                return visiblePhotos.filter { selectedIDs.contains($0.id) }
            }
            return [clicked]
        }
        if useSelection, selectedIDs.count > 1 {
            return visiblePhotos.filter { selectedIDs.contains($0.id) }
        }
        return fallback.map { [$0] } ?? []
    }
}
