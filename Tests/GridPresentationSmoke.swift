import AppKit
import Combine

@main
enum GridPresentationSmoke {
    @MainActor static func settle() async { try! await Task.sleep(for: .milliseconds(40)) }

    @MainActor static func main() async {
        _ = NSApplication.shared
        let suite = "SwiftCull.GridPresentation.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PhotoStore(ratingService: RatingService(defaults: defaults))
        let date = Date()
        store.photos = (0..<1800).map { index in
            PhotoEntry(baseName: "photo-\(index)", jpgPath: nil, nefPath: nil, movPath: nil,
                       jpgFileSize: nil, nefFileSize: nil, movFileSize: nil,
                       fileDate: date, modificationDate: date)
        }
        store.applyFilters()
        let grid = PhotoGridPresentation(store: store)
        await settle()
        let card = grid.cards[10]
        let unchanged = grid.cards[11]
        var updates = 0
        var unrelated = 0
        var layouts = 0
        var reveals = 0
        var subscription: Set<AnyCancellable> = []
        card.$value.dropFirst().sink { _ in updates += 1 }.store(in: &subscription)
        unchanged.$value.dropFirst().sink { _ in unrelated += 1 }.store(in: &subscription)
        grid.$layoutVersion.dropFirst().sink { _ in layouts += 1 }.store(in: &subscription)
        grid.revealSelection.sink { _ in reveals += 1 }.store(in: &subscription)
        for i in 0..<100 { store.enrichProgress = Double(i) / 100 }
        await settle()
        precondition(updates == 0 && unrelated == 0 && layouts == 0)
        store.setRating(4, for: card.value.photo)
        await settle()
        precondition(updates == 1 && unrelated == 0 && layouts == 0)
        precondition(grid.cards[10] === card && grid.cards[11] === unchanged)
        store.selectPhoto(card.value.photo)
        await settle()
        precondition(updates == 2 && unrelated == 0 && reveals == 1)
        store.toggleSinglePreview()
        await settle()
        precondition(!grid.isActive)
        let count = updates
        store.selectPhoto(unchanged.value.photo)
        store.setRating(2, for: card.value.photo)
        await settle()
        precondition(updates == count && unrelated == 0 && reveals == 1 && layouts == 0,
                     "Hidden grid must receive no card updates or scroll requests")
        store.toggleSinglePreview()
        await settle()
        precondition(grid.isActive && grid.selectedID == unchanged.id && reveals == 2)
        precondition(card.value.photo.rating == 2 && unchanged.value.primary)
        precondition(layouts == 0)
        store.filterOptions.searchText = "photo-17"
        store.applyFilters()
        await settle()
        precondition(layouts == 1 && grid.photos.count == store.filteredPhotos.count)

        // Native scroll activity suppresses background tag work, including onAppear.
        let target = store.filteredPhotos.first!
        store.setGridScrolling(true)
        store.photoDidAppear(target)
        try! await Task.sleep(for: .milliseconds(250))
        precondition(!store.areTagsLoaded(for: target))
        store.setGridScrolling(false)
        for _ in 0..<100 where !store.areTagsLoaded(for: target) {
            try! await Task.sleep(for: .milliseconds(10))
        }
        precondition(store.areTagsLoaded(for: target))
        store.flushPendingWrites()
        print("Grid presentation passed: 1800 entries, 100 progress changes cause 0 grid/card updates; one rating updates 1 card and 0 layouts; hidden grid frozen, selection restored once, filter structure and idle tag reads")
        withExtendedLifetime(subscription) {}
    }
}
