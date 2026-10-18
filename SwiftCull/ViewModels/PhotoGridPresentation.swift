import Combine
import Foundation

/// A card observes its own value instead of the entire library and progress state.
@MainActor
final class PhotoGridCardState: ObservableObject, Identifiable {
    struct Value: Equatable {
        let photo: PhotoEntry
        let selected: Bool
        let primary: Bool
        let versionCount: Int
        let versionsExpanded: Bool
    }

    let id: String
    @Published private(set) var value: Value

    init(_ value: Value) {
        id = value.photo.id
        self.value = value
    }

    func update(_ value: Value) {
        if self.value != value { self.value = value }
    }
}

/// Keeps lazy-grid identity stable across mark updates and freezes it under the
/// large preview. Progress publishers deliberately do not feed this projection.
@MainActor
final class PhotoGridPresentation: ObservableObject {
    @Published private(set) var layoutVersion = 0
    @Published private(set) var selectionVersion = 0
    private(set) var isActive = true
    let revealSelection = PassthroughSubject<String, Never>()
    private(set) var photos: [PhotoEntry] = []
    private(set) var cards: [PhotoGridCardState] = []
    private(set) var selectedIDs: Set<String> = []
    private(set) var selectedID: String?
    private(set) var ascending = false
    private(set) var isSelectMode = false
    private weak var store: PhotoStore?
    private var subscriptions: Set<AnyCancellable> = []
    private var scheduled = false
    private var dataDirty = true
    private var cardsByID: [String: PhotoGridCardState] = [:]

    init(store: PhotoStore) {
        self.store = store
        synchronize()
        // @Published emits before its value changes. Coalesce mutations and read
        // their final values on the next main-loop turn.
        store.$filteredPhotos.sink { [weak self] _ in
            self?.dataDirty = true
            self?.schedule()
        }.store(in: &subscriptions)
        store.$selectedPhotos.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        store.$selectedPhoto.map { $0?.id }.removeDuplicates()
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        store.$filterOptions.map(\.sortAscending).removeDuplicates()
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        store.$expandedVersionSources.sink { [weak self] _ in
            self?.dataDirty = true
            self?.schedule()
        }.store(in: &subscriptions)
        store.$isSelectMode.removeDuplicates().sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        store.$viewMode.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
    }

    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.synchronize()
        }
    }

    private func synchronize() {
        guard let store else { return }
        guard store.viewMode == .grid else {
            if isActive { isActive = false }
            return
        }
        let incoming = store.filteredPhotos
        let layoutChanged = ascending != store.filterOptions.sortAscending || (dataDirty &&
            (incoming.count != photos.count || zip(incoming, photos).contains { $0.id != $1.id || $0.fileDate != $1.fileDate }))
        let selectionChanged = selectedIDs != store.selectedPhotos || selectedID != store.selectedPhoto?.id
        let modeChanged = isSelectMode != store.isSelectMode
        let restoreSelection = !isActive && layoutChanged
        let oldSelected = selectedID
        let changedSelection = selectedIDs.symmetricDifference(store.selectedPhotos)
            .union([selectedID, store.selectedPhoto?.id].compactMap { $0 })
        selectedIDs = store.selectedPhotos
        selectedID = store.selectedPhoto?.id
        ascending = store.filterOptions.sortAscending
        isSelectMode = store.isSelectMode

        if dataDirty {
            var next: [PhotoGridCardState] = []
            var nextByID: [String: PhotoGridCardState] = [:]
            next.reserveCapacity(incoming.count)
            for photo in incoming {
                let value = PhotoGridCardState.Value(photo: photo, selected: selectedIDs.contains(photo.id),
                                                    primary: selectedID == photo.id,
                                                    versionCount: store.versionCount(for: photo),
                                                    versionsExpanded: store.expandedVersionSources.contains(photo.sourceID))
                if let card = cardsByID[photo.id] {
                    card.update(value)
                    next.append(card)
                    nextByID[photo.id] = card
                } else {
                    let card = PhotoGridCardState(value)
                    next.append(card)
                    nextByID[photo.id] = card
                }
            }
            cards = next
            cardsByID = nextByID
            dataDirty = false
        } else {
            // Arrow navigation and drag selection touch only the changed IDs.
            for id in changedSelection {
                guard let card = cardsByID[id] else { continue }
                let value = card.value
                card.update(.init(photo: value.photo, selected: selectedIDs.contains(id), primary: selectedID == id,
                                  versionCount: value.versionCount, versionsExpanded: value.versionsExpanded))
            }
        }
        // Group layout only depends on membership, order and dates. Tag/rating
        // arrivals update the individual card without invalidating LazyVGrid.
        if layoutChanged {
            photos = incoming
            layoutVersion &+= 1
        }
        if selectionChanged || modeChanged { selectionVersion &+= 1 }
        if !isActive { isActive = true }
        if let selectedID, oldSelected != selectedID || restoreSelection {
            revealSelection.send(selectedID)
        }
    }
}
