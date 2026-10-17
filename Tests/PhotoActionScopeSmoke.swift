import Foundation

@main
struct PhotoActionScopeSmoke {
    static func main() {
        let date = Date()
        let photos = (1...3).map { number in
            PhotoEntry(baseName: "test-\(number)", jpgPath: "/tmp/test-\(number).jpg",
                       nefPath: nil, movPath: nil, jpgFileSize: 1, nefFileSize: nil,
                       movFileSize: nil, fileDate: date, modificationDate: date)
        }
        let selected: Set<String> = [photos[0].id, photos[1].id]
        func ids(_ clicked: PhotoEntry?, selection: Set<String> = selected,
                 useSelection: Bool = true) -> [String] {
            PhotoActionScope.targets(clicked: clicked, selectedIDs: selection,
                                     visiblePhotos: photos, fallback: photos[0],
                                     useSelection: useSelection).map(\.id)
        }
        precondition(ids(photos[0]) == [photos[0].id, photos[1].id])
        precondition(ids(photos[1]) == [photos[0].id, photos[1].id])
        precondition(ids(photos[2]) == [photos[2].id])
        precondition(ids(photos[0], useSelection: false) == [photos[0].id])
        precondition(ids(photos[0], selection: [photos[0].id]) == [photos[0].id])
        precondition(ids(nil) == [photos[0].id, photos[1].id])
        let visible = Array(photos.prefix(2))
        precondition(PhotoActionScope.targets(clicked: photos[0],
                                             selectedIDs: [photos[0].id, photos[1].id, photos[2].id],
                                             visiblePhotos: visible, fallback: photos[0],
                                             useSelection: true).map(\.id) == [photos[0].id, photos[1].id])
        print("Photo action scope smoke test passed")
    }
}
