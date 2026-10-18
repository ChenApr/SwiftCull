import Foundation
import SwiftUI
import Combine
import AppKit

struct DetectedVolume: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    let icon: String
}

enum PhotoViewMode: Sendable {
    case grid
    case single
}

@MainActor
class PhotoStore: ObservableObject {
    @Published var photos: [PhotoEntry] = []
    @Published var filteredPhotos: [PhotoEntry] = []
    /// 每当 filteredPhotos 的成员或顺序变化时自增，供视图做轻量 onChange 触发（避免全量 map(\.id)）
    @Published private(set) var filteredPhotosVersion = 0
    @Published var selectedPhoto: PhotoEntry? {
        didSet {
            if oldValue?.id != selectedPhoto?.id { exitVideoPlaybackMode() }
        }
    }
    @Published var selectedPhotos: Set<String> = []
    @Published var filterOptions = FilterOptions()
    @Published var isLoading = false
    @Published var loadingProgress: Double = 0
    @Published var loadingStatus: String = ""
    @Published var isEnriching = false
    @Published var enrichProgress: Double = 0
    @Published var enrichStatus: String = ""
    @Published var sourcePath: String = ""
    @Published var errorMessage: String?
    @Published var showingDeleteConfirmation = false
    @Published private(set) var isDeleting = false
    @Published var photosToDelete: [PhotoEntry] = []
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportMessage: String?
    @Published var copyStatus: String?
    @Published var viewMode: PhotoViewMode = .grid {
        didSet {
            if viewMode != .single { exitVideoPlaybackMode() }
        }
    }
    @Published private(set) var isVideoPlaybackMode = false
    let videoPlaybackController = VideoPlaybackController()
    @Published var isSidebarVisible = true
    @Published var isInspectorVisible = false
    @Published var showingShortcutGuide = false
    @Published var isSelectMode = false
    @Published var detectedVolumes: [DetectedVolume] = []
    @Published var cropEditorPhoto: PhotoEntry?
    @Published var livePhotoEditorPhoto: PhotoEntry?
    @Published var livePhotoInitialTime: Double = 0
    @Published var expandedVersionSources: Set<String> = []
    private var cropVersions: [String: [CropVersion]] = [:]

    private let fileService: FileService
    private let tagService = TagService.shared
    private let ratingService: RatingService
    private let thumbnailService = ThumbnailService.shared
    let finderTagService = FinderTagService.shared
    private let projectMetadata: ProjectMetadataService
    private let tagWriteQueue = DispatchQueue(label: "com.swiftcull.tag-writes", qos: .utility)
    private var sidecarEntries: [String: PhotoMetadata] = [:]
    private var latestCopyID = UUID()
    private var enrichmentTask: Task<Void, Never>?
    private var tagWriteIDs: [String: UUID] = [:]

    /// 选择模式下被编辑过的照片在编辑前的原始状态（用于「取消」纯内存回滚，零磁盘 IO）
    private struct OriginalPhotoState {
        let rating: Int
        let tags: [String]
    }
    private var editedOriginals: [String: OriginalPhotoState] = [:]

    private var gridColumnCount = 1
    private var currentLoadID = UUID()
    private var lastPreheatKey: String?
    private var preheatTask: Task<Void, Never>?
    /// filteredPhotos 的 id→下标缓存，随 applyFilters 重建，供滚动预热/方向键导航 O(1) 定位。
    private var filteredIndexById: [String: Int] = [:]
    private var cachedTotalSize = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
    private var tagColorLookup: [String: Int] {
        finderTagService.tagColorLookup
    }

    init(fileService: FileService = .shared, ratingService: RatingService = .shared,
         projectMetadata: ProjectMetadataService = .shared) {
        self.fileService = fileService
        self.ratingService = ratingService
        self.projectMetadata = projectMetadata
    }

    /// Wait for queued Finder-tag writes before scanning metadata again. This
    /// preserves the old read-after-write behavior without blocking the main
    /// actor while the extended-attribute writes are in progress.
    private func waitForTagWrites() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            tagWriteQueue.async {
                continuation.resume()
            }
        }
    }

    /// Drain background tags and delayed sidecars before the process exits.
    func flushPendingWrites() {
        tagWriteQueue.sync {}
        let failures = projectMetadata.flush()
        if !failures.isEmpty {
            exportMessage = "评分保存失败：\(failures.joined(separator: "\n"))"
            print("[ProjectMetadata] \(exportMessage!)")
        }
    }

    private func buildPhotoIndexMap() -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(photos.count)
        for index in photos.indices {
            map[photos[index].id] = index
        }
        return map
    }

    private func buildFilteredIndexMap() -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(filteredPhotos.count)
        for index in filteredPhotos.indices {
            map[filteredPhotos[index].id] = index
        }
        return map
    }

    var photoCount: Int { filteredPhotos.count }
    var totalPhotoCount: Int { photos.count }

    var totalSize: String { cachedTotalSize }

    private func calculateTotalSize() -> String {
        var seenSources: Set<String> = []
        let total = filteredPhotos.reduce(Int64(0)) { total, photo in
            guard seenSources.insert(photo.sourceID).inserted else { return total }
            switch filterOptions.fileTypeFilter {
            case .jpgOnly:
                return total + (photo.jpgFileSize ?? 0)
            case .nefOnly:
                return total + (photo.nefFileSize ?? 0)
            case .jpgAndNef:
                return total + (photo.jpgFileSize ?? 0) + (photo.nefFileSize ?? 0)
            case .movOnly:
                return total + (photo.movFileSize ?? 0)
            case .all, .hasMov:
                return total + photo.totalFileSize
            }
        }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    var selectedPhotoEntries: [PhotoEntry] {
        guard !selectedPhotos.isEmpty else { return [] }
        return filteredPhotos.filter { selectedPhotos.contains($0.id) }
    }

    var selectedCount: Int { selectedPhotos.count }

    var canEditSelectedCrop: Bool {
        selectedPhotos.count == 1 && selectedPhoto.map {
            selectedPhotos.contains($0.id) && !$0.hasMov
        } == true
    }

    func versions(for photo: PhotoEntry) -> [PhotoEntry] {
        photos.filter { $0.sourceID == photo.sourceID && !$0.isDeleted }
    }

    func versionCount(for photo: PhotoEntry) -> Int {
        cropVersions[photo.sourceID]?.count ?? 1
    }

    func toggleVersions(for photo: PhotoEntry) {
        if expandedVersionSources.contains(photo.sourceID) {
            expandedVersionSources.remove(photo.sourceID)
            if selectedPhoto?.sourceID == photo.sourceID, selectedPhoto?.isVersionCopy == true,
               let main = photos.first(where: { $0.sourceID == photo.sourceID && !$0.isVersionCopy }) {
                selectPhoto(main)
            }
        } else {
            expandedVersionSources.insert(photo.sourceID)
        }
        applyFilters()
    }

    func editCrop(_ photo: PhotoEntry) {
        guard !photo.hasMov else { return }
        cropEditorPhoto = photo
    }

    func openLivePhotoEditor(for photo: PhotoEntry) {
        guard photo.movPath != nil else { return }
        livePhotoInitialTime = isVideoPlaybackMode && selectedPhoto?.id == photo.id
            ? videoPlaybackController.currentTime : 0
        videoPlaybackController.player?.pause()
        livePhotoEditorPhoto = photo
    }

    @discardableResult
    func editSelectedCrop() -> Bool {
        guard canEditSelectedCrop, let photo = selectedPhoto else { return false }
        editCrop(photo)
        return true
    }

    func previewPhoto(_ photo: PhotoEntry) {
        guard !photo.primaryImagePath.isEmpty else {
            if let movPath = photo.movPath { QuickLookHelper.shared.preview(URL(fileURLWithPath: movPath)) }
            return
        }
        guard photo.cropRect != nil else {
            QuickLookHelper.shared.preview(URL(fileURLWithPath: photo.primaryImagePath))
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                do {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("SwiftCull-CropPreview-\(UUID().uuidString)")
                    return .success(try CropImageService.write(photo: photo,
                                                               sourcePath: photo.primaryImagePath,
                                                               into: folder))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let url): QuickLookHelper.shared.preview(url)
            case .failure(let error): self?.exportMessage = "预览裁剪照片失败：\(error.localizedDescription)"
            }
        }
    }

    @discardableResult
    func saveCrop(_ crop: CropRect?, aspect: CropAspectRatio, for photo: PhotoEntry,
                  createCopy: Bool, name: String) -> Bool {
        guard !sourcePath.isEmpty, !photo.hasMov else { return false }
        guard let source = photos.first(where: { $0.sourceID == photo.sourceID && $0.versionID == nil }) else { return false }
        let cleanCrop = crop?.normalized.isFull == true ? nil : crop?.normalized
        var versions = cropVersions[photo.sourceID] ?? [CropVersion(id: nil, name: nil, crop: nil)]
        let version: CropVersion
        if createCopy {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultName = "裁剪 \(versions.filter { $0.id != nil }.count + 1)"
            version = CropVersion(id: UUID(), name: trimmed.isEmpty ? defaultName : trimmed,
                                  crop: cleanCrop, aspect: aspect)
            versions.append(version)
        } else {
            version = CropVersion(id: photo.versionID, name: photo.versionName,
                                  crop: cleanCrop, aspect: aspect)
            if let index = versions.firstIndex(where: { $0.id == photo.versionID }) {
                versions[index] = version
            } else {
                versions.append(version)
            }
        }
        var updatedCatalog = cropVersions
        updatedCatalog[photo.sourceID] = versions
        do { try CropCatalog.save(updatedCatalog, folder: sourcePath) }
        catch { exportMessage = "裁剪版本保存失败：\(error.localizedDescription)"; return false }
        cropVersions = updatedCatalog
        if createCopy { expandedVersionSources.insert(photo.sourceID) }
        let updated = source.asVersion(version)
        if createCopy {
            photos.append(updated)
        } else if let index = photos.firstIndex(where: { $0.id == photo.id }) {
            photos[index] = updated
        }
        applyFilters()
        selectPhoto(updated)
        cropEditorPhoto = nil
        return true
    }

    func renameVersion(_ photo: PhotoEntry, to name: String) {
        guard photo.isVersionCopy else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var versions = cropVersions[photo.sourceID],
              let index = versions.firstIndex(where: { $0.id == photo.versionID }) else { return }
        versions[index].name = trimmed
        var updatedCatalog = cropVersions
        updatedCatalog[photo.sourceID] = versions
        do { try CropCatalog.save(updatedCatalog, folder: sourcePath) }
        catch { exportMessage = "版本重命名失败：\(error.localizedDescription)"; return }
        cropVersions = updatedCatalog
        if let photoIndex = photos.firstIndex(where: { $0.id == photo.id }) { photos[photoIndex].versionName = trimmed }
        applyFilters()
        if selectedPhoto?.id == photo.id { selectedPhoto?.versionName = trimmed }
    }

    func removeVersion(_ photo: PhotoEntry) {
        guard photo.isVersionCopy else { return }
        var updatedCatalog = cropVersions
        updatedCatalog[photo.sourceID]?.removeAll { $0.id == photo.versionID }
        do { try CropCatalog.save(updatedCatalog, folder: sourcePath) }
        catch { exportMessage = "删除版本失败：\(error.localizedDescription)"; return }
        cropVersions = updatedCatalog
        photos.removeAll { $0.id == photo.id }
        selectedPhotos.remove(photo.id)
        if selectedPhoto?.id == photo.id { selectPhoto(photos.first { $0.sourceID == photo.sourceID }) }
        applyFilters()
    }

    /// Actions on a selected card use the visible selection; an unselected card is a single target.
    func contextPhotos(clicked photo: PhotoEntry? = nil, useSelection: Bool = true) -> [PhotoEntry] {
        PhotoActionScope.targets(clicked: photo, selectedIDs: selectedPhotos,
                                 visiblePhotos: filteredPhotos, fallback: selectedPhoto,
                                 useSelection: useSelection && viewMode == .grid)
    }

    @discardableResult
    func copyOriginalFiles(clicked photo: PhotoEntry? = nil, useSelection: Bool = true) -> Bool {
        let targets = contextPhotos(clicked: photo, useSelection: useSelection)
        guard !targets.isEmpty else { return false }
        let copyID = UUID()
        latestCopyID = copyID
        copyStatus = nil
        guard targets.contains(where: { $0.cropRect != nil || $0.isVersionCopy }) else {
            do {
                _ = try CropClipboardService.copy(targets)
                return true
            } catch {
                exportMessage = "复制照片失败：\(error.localizedDescription)"
                return false
            }
        }

        copyStatus = "正在准备裁剪后的文件…"
        Task { @MainActor in
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try CropClipboardService.prepare(targets)
                }.value
                guard latestCopyID == copyID else {
                    CropClipboardService.discard(prepared)
                    return
                }
                _ = try CropClipboardService.commit(prepared)
                copyStatus = "已复制裁剪后的文件，可在 Finder 中粘贴"
                try? await Task.sleep(for: .seconds(3))
                if latestCopyID == copyID { copyStatus = nil }
            } catch {
                guard latestCopyID == copyID else { return }
                copyStatus = nil
                exportMessage = "复制裁剪照片失败：\(error.localizedDescription)"
            }
        }
        return true
    }

    func contextSetRating(_ rating: Int, clicked photo: PhotoEntry, useSelection: Bool = true) {
        let targets = contextPhotos(clicked: photo, useSelection: useSelection)
        if isSelectMode {
            setRatings(rating, for: Set(targets.map(\.id)))
        } else {
            targets.forEach { setRating(rating, for: $0) }
        }
    }

    func contextToggleTag(_ tag: String, clicked photo: PhotoEntry, useSelection: Bool = true) {
        let targets = contextPhotos(clicked: photo, useSelection: useSelection)
        let remove = targets.allSatisfy { $0.tags.contains(tag) }
        if isSelectMode {
            updateTag(tag, adding: !remove, for: Set(targets.map(\.id)))
        } else {
            targets.forEach { remove ? removeTag(tag, from: $0) : addTag(tag, to: $0) }
        }
    }

    func contextClearTags(clicked photo: PhotoEntry, useSelection: Bool = true) {
        let targets = contextPhotos(clicked: photo, useSelection: useSelection)
        if isSelectMode {
            clearTags(for: Set(targets.map(\.id)))
        } else {
            targets.forEach { clearTags(for: $0) }
        }
    }

    var availableTags: [FinderTag] {
        finderTagService.availableTags
    }

    func loadPhotos() async {
        let loadID = UUID()
        let folderPath = sourcePath
        enrichmentTask?.cancel()
        enrichmentTask = nil
        currentLoadID = loadID
        tagWriteIDs.removeAll()
        lastPreheatKey = nil
        preheatTask?.cancel()
        preheatTask = nil
        thumbnailService.cancelPending()
        thumbnailService.clearInMemoryCache()
        thumbnailService.cleanupDiskCache()
        isLoading = true
        loadingProgress = 0
        loadingStatus = "准备读取文件夹..."
        errorMessage = nil
        selectedPhoto = nil
        cropEditorPhoto = nil
        expandedVersionSources = []
        selectedPhotos = []
        photosToDelete = []
        showingDeleteConfirmation = false
        isSelectMode = false
        editedOriginals = [:]
        viewMode = .grid
        isEnriching = false
        enrichProgress = 0
        enrichStatus = ""

        await waitForTagWrites()
        let metadataService = projectMetadata
        let saveFailures = await Task.detached(priority: .utility) { metadataService.flush() }.value
        guard currentLoadID == loadID else { return }
        if !saveFailures.isEmpty {
            exportMessage = "评分保存失败，数据仍待重试：\(saveFailures.joined(separator: "\n"))"
        }

        if folderPath.isEmpty {
            photos = []
            filteredPhotos = []
            cachedTotalSize = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
            filteredPhotosVersion &+= 1
            isLoading = false
            loadingProgress = 0
            loadingStatus = ""
            return
        }

        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folderPath, isDirectory: &isDir) || !isDir.boolValue {
            errorMessage = "路径不存在或不是文件夹: \(folderPath)"
            isLoading = false
            loadingProgress = 0
            loadingStatus = ""
            return
        }

        loadingStatus = "正在扫描照片文件..."
        loadingProgress = 0.4

        // 第一阶段：快速列出文件（文件系统日期），立即展示网格
        let fast = await fileService.scanFilesFast(at: folderPath)
        guard currentLoadID == loadID else { return }

        // Both metadata files may live on a slow card. Read them off the main actor.
        let metadataTask = Task.detached(priority: .utility) {
            metadataService.load(from: folderPath)
        }
        let cropTask = Task.detached(priority: .utility) {
            CropCatalog.load(folder: folderPath)
        }
        let loadedMetadata = await metadataTask.value
        let loadedCrops = await cropTask.value
        guard currentLoadID == loadID else { return }
        sidecarEntries = loadedMetadata
        cropVersions = loadedCrops
        var initial = fast.flatMap { source -> [PhotoEntry] in
            let versions = cropVersions[source.sourceID] ?? [CropVersion(id: nil, name: nil, crop: nil)]
            let main = versions.first(where: { $0.id == nil }) ?? CropVersion(id: nil, name: nil, crop: nil)
            return [source.asVersion(main)] + versions.filter { $0.id != nil }.map(source.asVersion)
        }
        for i in initial.indices {
            if let rating = sidecarEntries[initial[i].sourceID]?.rating {
                initial[i].rating = min(5, max(0, rating))
                ratingService.setRating(initial[i].rating, for: initial[i].sourceID, folderPath: folderPath)
            } else {
                initial[i].rating = ratingService.getRating(for: initial[i].sourceID, folderPath: folderPath)
            }
        }

        photos = initial
        applyFilters()
        loadingProgress = 1
        loadingStatus = fast.isEmpty ? "未找到可识别的照片" : "加载完成"
        isLoading = false

        guard !fast.isEmpty else { return }

        // 第二阶段：后台补充 EXIF 拍摄日期与 Finder 标签，完成后按拍摄日期平滑重排
        let task = Task { [weak self] in
            guard let self else { return }
            await self.enrichPhotos(loadID: loadID)
        }
        enrichmentTask = task
        await task.value
        if currentLoadID == loadID {
            enrichmentTask = nil
        }
    }

    /// 后台补充拍摄日期与标签，带细粒度进度；完成后按最终拍摄日期重排
    private func enrichPhotos(loadID: UUID) async {
        let snapshot = photos
        let sourceEntries = Dictionary(grouping: snapshot, by: \.sourceID).compactMap { $0.value.first }
        let total = sourceEntries.count
        guard total > 0 else { return }

        isEnriching = true
        enrichProgress = 0
        enrichStatus = "正在读取拍摄信息…"

        struct EnrichResult: Sendable {
            let sourceID: String
            let captureDate: Date?
            let tags: [String]
        }

        // A card is much slower at many concurrent metadata reads than at a small
        // bounded stream. Keep visible thumbnail work ahead of this utility queue.
        let maxConcurrentReads = 2
        var results: [EnrichResult] = []
        results.reserveCapacity(total)
        var completedCount = 0

        await withTaskGroup(of: EnrichResult?.self) { group in
            var nextIndex = 0

            func addNextRead() {
                guard nextIndex < sourceEntries.count else { return }
                let photo = sourceEntries[nextIndex]
                nextIndex += 1
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return nil }
                    let tagService = TagService.shared
                    return EnrichResult(
                        sourceID: photo.sourceID,
                        captureDate: FileService.captureDate(for: photo),
                        tags: tagService.getTagsForPhotoPair(photo)
                    )
                }
            }

            for _ in 0..<min(maxConcurrentReads, sourceEntries.count) {
                addNextRead()
            }

            while let result = await group.next() {
                guard !Task.isCancelled, currentLoadID == loadID else {
                    group.cancelAll()
                    break
                }
                if let result {
                    results.append(result)
                }
                completedCount += 1
                enrichProgress = Double(completedCount) / Double(total)
                enrichStatus = "正在读取拍摄信息 \(completedCount)/\(total)"
                addNextRead()
            }
        }

        guard !Task.isCancelled, currentLoadID == loadID else { isEnriching = false; return }

        var dateMap: [String: Date] = [:]
        var tagMap: [String: [String]] = [:]
        for result in results {
            if let date = result.captureDate { dateMap[result.sourceID] = date }
            tagMap[result.sourceID] = result.tags
        }

        var rebuilt: [PhotoEntry] = []
        rebuilt.reserveCapacity(photos.count)
        for photo in photos {
            let exifDate = dateMap[photo.sourceID]
            let needsRebuild = exifDate != nil && exifDate != photo.fileDate
            var updated: PhotoEntry
            if needsRebuild {
                updated = PhotoEntry(
                    baseName: photo.baseName,
                    jpgPath: photo.jpgPath,
                    nefPath: photo.nefPath,
                    movPath: photo.movPath,
                    jpgFileSize: photo.jpgFileSize,
                    nefFileSize: photo.nefFileSize,
                    movFileSize: photo.movFileSize,
                    fileDate: exifDate!,
                    modificationDate: photo.modificationDate
                )
                updated = updated.asVersion(CropVersion(id: photo.versionID, name: photo.versionName,
                                                        crop: photo.cropRect, aspect: photo.cropAspect))
                updated.rating = photo.rating
                updated.tags = photo.tags
                updated.isDeleted = photo.isDeleted
            } else {
                updated = photo
            }
            // 标签：未处于用户编辑中的照片，采用磁盘读取的最新标签
            if editedOriginals[photo.id] == nil, let tags = tagMap[photo.sourceID] {
                updated.tags = tags
            }
            rebuilt.append(updated)
        }

        photos = rebuilt
        withAnimation(.snappy(duration: 0.3)) {
            applyFilters()
        }

        enrichProgress = 1
        enrichStatus = ""
        isEnriching = false
    }

    // MARK: - Sidecar 标注同步

    /// 将当前 photos 中有标注的条目写入 sidecar
    private func syncSidecar() {
        guard !sourcePath.isEmpty else { return }
        var entries: [String: PhotoMetadata] = [:]
        for photo in photos {
            if photo.rating > 0 {
                entries[photo.sourceID] = PhotoMetadata(rating: photo.rating)
            }
        }
        sidecarEntries = entries
        projectMetadata.scheduleSave(entries: entries, folderPath: sourcePath)
    }

    func preloadThumbnails(around photo: PhotoEntry, size: CGFloat) {
        guard let centerIndex = filteredIndexById[photo.id] else { return }
        let quantizedSize = ThumbnailService.quantizedSize(size)
        let columns = max(1, gridColumnCount)
        // 按「行」去重：同一行内多张卡片相继 onAppear 只触发一次预热，减少重复窗口扫描。
        let row = centerIndex / columns
        let key = "\(filteredPhotosVersion)|\(row)|\(quantizedSize)|\(columns)"
        guard key != lastPreheatKey else { return }
        lastPreheatKey = key

        // Coalesce the row appearances in a scroll update before scanning the
        // preheat window. Visible cards still request their images immediately.
        preheatTask?.cancel()
        let loadID = currentLoadID
        let photosVersion = filteredPhotosVersion
        preheatTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(30)) }
            catch { return }
            guard let self, self.currentLoadID == loadID,
                  self.filteredPhotosVersion == photosVersion else { return }
            let lowerBound = max(0, centerIndex - columns * 2)
            let upperBound = min(self.filteredPhotos.count, centerIndex + columns * 4 + 1)
            let items = self.filteredPhotos[lowerBound..<upperBound].map { photo in
                (path: photo.primaryFilePath, crop: photo.cropRect)
            }
            self.thumbnailService.preloadThumbnails(paths: items, size: CGFloat(quantizedSize))
        }
    }

    func applyFilters() {
        let trimmedQuery = filterOptions.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = trimmedQuery.isEmpty ? nil : trimmedQuery.lowercased()
        let ratingFilter = filterOptions.ratingFilter
        let fileTypeFilter = filterOptions.fileTypeFilter
        let tagFilter = filterOptions.tagFilter

        var result = [PhotoEntry]()
        result.reserveCapacity(photos.count)

        for photo in photos {
            if photo.isDeleted { continue }
            if photo.isVersionCopy && !expandedVersionSources.contains(photo.sourceID) { continue }

            if let query, !photo.baseName.lowercased().contains(query),
               !photo.displayName.lowercased().contains(query) { continue }

            switch ratingFilter {
            case .all: break
            case .unrated: if photo.rating != 0 { continue }
            default: if photo.rating != ratingFilter.rawValue { continue }
            }

            switch fileTypeFilter {
            case .all: break
            case .jpgOnly: if !photo.hasJpg { continue }
            case .nefOnly: if !photo.hasNef { continue }
            case .jpgAndNef: if !(photo.hasJpg && photo.hasNef) { continue }
            case .movOnly: if !photo.isVideoOnly { continue }
            case .hasMov: if !photo.hasMov { continue }
            }

            if let tagFilter, !photo.tags.contains(tagFilter) { continue }

            // 日期范围过滤（仅开启时生效）
            if filterOptions.dateFilterEnabled {
                if let start = filterOptions.startDate, photo.fileDate < start { continue }
                if let end = filterOptions.endDate, photo.fileDate > end { continue }
            }

            result.append(photo)
        }

        filteredPhotos = sortPhotos(result)
        filteredIndexById = buildFilteredIndexMap()
        cachedTotalSize = calculateTotalSize()
        filteredPhotosVersion &+= 1
    }

    private func sortPhotos(_ photos: [PhotoEntry]) -> [PhotoEntry] {
        let grouped = Dictionary(grouping: photos, by: \.sourceID)
        let representatives = grouped.values.compactMap { group in
            group.first(where: { !$0.isVersionCopy }) ?? group.first
        }
        let sorted: [PhotoEntry]
        switch filterOptions.sortOption {
        case .name:
            sorted = representatives.sorted { $0.baseName < $1.baseName }
        case .date:
            sorted = representatives.sorted { $0.fileDate == $1.fileDate ? $0.baseName < $1.baseName : $0.fileDate < $1.fileDate }
        case .rating:
            sorted = representatives.sorted { $0.rating == $1.rating ? $0.baseName < $1.baseName : $0.rating > $1.rating }
        case .size:
            sorted = representatives.sorted { $0.totalFileSize == $1.totalFileSize ? $0.baseName < $1.baseName : $0.totalFileSize > $1.totalFileSize }
        }
        let sources = filterOptions.sortAscending ? sorted : Array(sorted.reversed())
        return sources.flatMap { source in
            (grouped[source.sourceID] ?? []).sorted {
                if $0.isVersionCopy != $1.isVersionCopy { return !$0.isVersionCopy }
                return $0.displayName < $1.displayName
            }
        }
    }

    func setRating(_ rating: Int, for photo: PhotoEntry) {
        ratingService.setRating(rating, for: photo.sourceID, folderPath: sourcePath)
        for index in photos.indices where photos[index].sourceID == photo.sourceID { photos[index].rating = rating }
        for index in filteredPhotos.indices where filteredPhotos[index].sourceID == photo.sourceID { filteredPhotos[index].rating = rating }
        if selectedPhoto?.sourceID == photo.sourceID { selectedPhoto?.rating = rating }
        syncSidecar()
    }

    func clearTags(for photo: PhotoEntry) {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        scheduleTagWrite([], for: photos[index])
        setSharedTags([], sourceID: photo.sourceID)
    }

    private func scheduleTagWrite(_ tags: [String], for photo: PhotoEntry) {
        let colorLookup = tagColorLookup
        let loadID = currentLoadID
        let writeID = UUID()
        tagWriteIDs[photo.sourceID] = writeID
        tagWriteQueue.async {
            let service = TagService.shared
            let result = service.writeTagsForPhotoPair(tags, photo: photo, colorLookup: colorLookup)
            guard !result.succeeded else { return }
            let actualTags = service.getTagsForPhotoPair(photo)
            Task { @MainActor [weak self] in
                guard let self, self.currentLoadID == loadID,
                      self.tagWriteIDs[photo.sourceID] == writeID else { return }
                self.setSharedTags(actualTags, sourceID: photo.sourceID)
                let names = result.failedPaths.map { ($0 as NSString).lastPathComponent }.joined(separator: "、")
                self.exportMessage = "Finder 标签写入失败：\(names.isEmpty ? photo.displayName : names)。已重新读取实际标签。"
            }
        }
    }

    private func setSharedTags(_ tags: [String], sourceID: String) {
        for index in photos.indices where photos[index].sourceID == sourceID { photos[index].tags = tags }
        for index in filteredPhotos.indices where filteredPhotos[index].sourceID == sourceID { filteredPhotos[index].tags = tags }
        if selectedPhoto?.sourceID == sourceID { selectedPhoto?.tags = tags }
    }

    func toggleSinglePreview() {
        if viewMode == .single {
            viewMode = .grid
            return
        }
        if selectedPhoto == nil, let first = filteredPhotos.first {
            selectPhoto(first)
        }
        if selectedPhoto != nil {
            viewMode = .single
        }
    }

    var canPlaySelectedVideo: Bool { selectedPhoto?.movPath != nil }

    @discardableResult
    func enterVideoPlaybackMode(for photo: PhotoEntry? = nil) -> Bool {
        if let photo, selectedPhoto?.id != photo.id { selectPhoto(photo) }
        guard let path = selectedPhoto?.movPath else { return false }
        viewMode = .single
        videoPlaybackController.load(URL(fileURLWithPath: path))
        isVideoPlaybackMode = true
        return true
    }

    @discardableResult
    func toggleVideoPlaybackMode() -> Bool {
        if isVideoPlaybackMode {
            exitVideoPlaybackMode()
            return true
        }
        return enterVideoPlaybackMode()
    }

    @discardableResult
    func toggleVideoPlaybackMode(for photo: PhotoEntry) -> Bool {
        if isVideoPlaybackMode, selectedPhoto?.id == photo.id {
            exitVideoPlaybackMode()
            return true
        }
        return enterVideoPlaybackMode(for: photo)
    }

    func exitVideoPlaybackMode() {
        guard isVideoPlaybackMode else { return }
        isVideoPlaybackMode = false
        videoPlaybackController.stop()
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }

    func toggleInspector() {
        guard selectedPhoto != nil else { return }
        isInspectorVisible.toggle()
    }

    // MARK: - 批量操作（选择模式下仅改内存，落盘延迟到「完成」）

    /// 记录一张照片在本次选择会话中首次被编辑前的原始状态
    private func captureOriginalIfNeeded(_ id: String, index: Int) {
        guard editedOriginals[id] == nil else { return }
        editedOriginals[id] = OriginalPhotoState(rating: photos[index].rating, tags: photos[index].tags)
    }

    func batchSetRating(_ rating: Int) {
        setRatings(rating, for: selectedPhotos)
    }

    private func setRatings(_ rating: Int, for ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let sourceIDs = Set(photos.filter { ids.contains($0.id) }.map(\.sourceID))
        let ids = Set(photos.filter { sourceIDs.contains($0.sourceID) }.map(\.id))
        let photoMap = buildPhotoIndexMap()
        let filteredMap = buildFilteredIndexMap()

        for id in ids {
            if let index = photoMap[id] {
                captureOriginalIfNeeded(id, index: index)
                photos[index].rating = rating
            }
            if let filteredIndex = filteredMap[id] {
                filteredPhotos[filteredIndex].rating = rating
            }
        }
        if let selected = selectedPhoto, ids.contains(selected.id) {
            selectedPhoto?.rating = rating
        }
    }

    func batchClearRating() {
        batchSetRating(0)
    }

    func batchAddTag(_ tag: String) {
        updateTag(tag, adding: true, for: selectedPhotos)
    }

    private func updateTag(_ tag: String, adding: Bool, for ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let sourceIDs = Set(photos.filter { ids.contains($0.id) }.map(\.sourceID))
        let ids = Set(photos.filter { sourceIDs.contains($0.sourceID) }.map(\.id))
        let photoMap = buildPhotoIndexMap()
        let filteredMap = buildFilteredIndexMap()

        for id in ids {
            if let index = photoMap[id] {
                captureOriginalIfNeeded(id, index: index)
                if adding && !photos[index].tags.contains(tag) {
                    photos[index].tags.append(tag)
                } else if !adding {
                    photos[index].tags.removeAll { $0 == tag }
                }
            }
            if let filteredIndex = filteredMap[id] {
                if adding && !filteredPhotos[filteredIndex].tags.contains(tag) {
                    filteredPhotos[filteredIndex].tags.append(tag)
                } else if !adding {
                    filteredPhotos[filteredIndex].tags.removeAll { $0 == tag }
                }
            }
        }
        if let selected = selectedPhoto, ids.contains(selected.id) {
            if adding && !selected.tags.contains(tag) {
                selectedPhoto?.tags.append(tag)
            } else if !adding {
                selectedPhoto?.tags.removeAll { $0 == tag }
            }
        }
    }

    func batchClearTags() {
        clearTags(for: selectedPhotos)
    }

    private func clearTags(for ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let sourceIDs = Set(photos.filter { ids.contains($0.id) }.map(\.sourceID))
        let ids = Set(photos.filter { sourceIDs.contains($0.sourceID) }.map(\.id))
        let photoMap = buildPhotoIndexMap()
        let filteredMap = buildFilteredIndexMap()

        for id in ids {
            if let index = photoMap[id] {
                captureOriginalIfNeeded(id, index: index)
                photos[index].tags = []
            }
            if let filteredIndex = filteredMap[id] {
                filteredPhotos[filteredIndex].tags = []
            }
        }
        if let selected = selectedPhoto, ids.contains(selected.id) {
            selectedPhoto?.tags = []
        }
    }

    func addTag(_ tag: String, to photo: PhotoEntry) {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        var currentTags = photos[index].tags
        if !currentTags.contains(tag) {
            currentTags.append(tag)
            scheduleTagWrite(currentTags, for: photos[index])
            setSharedTags(currentTags, sourceID: photo.sourceID)
        }
    }

    func removeTag(_ tag: String, from photo: PhotoEntry) {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        var currentTags = photos[index].tags
        currentTags.removeAll { $0 == tag }
        scheduleTagWrite(currentTags, for: photos[index])
        setSharedTags(currentTags, sourceID: photo.sourceID)
    }

    // MARK: - 选择模式

    func enterSelectMode() {
        editedOriginals = [:]
        isSelectMode = true
    }

    /// 取消：纯内存回滚被编辑过的照片，零磁盘 IO
    func cancelSelectMode() {
        if !editedOriginals.isEmpty {
            let photoMap = buildPhotoIndexMap()
            let filteredMap = buildFilteredIndexMap()
            for (id, original) in editedOriginals {
                if let index = photoMap[id] {
                    photos[index].rating = original.rating
                    photos[index].tags = original.tags
                }
                if let filteredIndex = filteredMap[id] {
                    filteredPhotos[filteredIndex].rating = original.rating
                    filteredPhotos[filteredIndex].tags = original.tags
                }
            }
        }
        editedOriginals = [:]
        selectedPhotos = []
        selectedPhoto = nil
        isSelectMode = false
    }

    /// 完成：把本次会话的改动一次性落盘（标签写盘在后台线程）
    func confirmSelectMode() {
        persistSelectModeEdits()
        editedOriginals = [:]
        selectedPhotos = []
        selectedPhoto = nil
        isSelectMode = false
    }

    private func persistSelectModeEdits() {
        guard !editedOriginals.isEmpty, !sourcePath.isEmpty else { return }
        let photoMap = buildPhotoIndexMap()

        struct PendingWrite: Sendable {
            let photo: PhotoEntry
            let ratingChanged: Bool
            let tagsChanged: Bool
        }
        var pending: [PendingWrite] = []
        var ratingChangedAtAll = false

        var queuedSources: Set<String> = []
        for (id, original) in editedOriginals {
            guard let index = photoMap[id] else { continue }
            let current = photos[index]
            guard queuedSources.insert(current.sourceID).inserted else { continue }
            let ratingChanged = current.rating != original.rating
            let tagsChanged = current.tags != original.tags
            guard ratingChanged || tagsChanged else { continue }
            if ratingChanged { ratingChangedAtAll = true }
            pending.append(PendingWrite(photo: current, ratingChanged: ratingChanged, tagsChanged: tagsChanged))
        }

        guard !pending.isEmpty else { return }

        // Keep folder identity captured by the current session. Tag writes remain serialized.
        for write in pending {
            if write.ratingChanged {
                ratingService.setRating(write.photo.rating, for: write.photo.sourceID, folderPath: sourcePath)
            }
            if write.tagsChanged {
                scheduleTagWrite(write.photo.tags, for: write.photo)
            }
        }

        if ratingChangedAtAll {
            syncSidecar()
        }
    }

    func selectPhoto(_ photo: PhotoEntry?) {
        selectedPhoto = photo
        if let photo = photo {
            selectedPhotos = [photo.id]
        } else {
            selectedPhotos = []
        }
        DispatchQueue.main.async {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    func toggleSelection(_ photo: PhotoEntry) {
        if selectedPhotos.contains(photo.id) {
            selectedPhotos.remove(photo.id)
            if selectedPhoto?.id == photo.id {
                selectedPhoto = selectedPhotos.isEmpty ? nil :
                    filteredPhotos.first { selectedPhotos.contains($0.id) }
            }
        } else {
            selectedPhotos.insert(photo.id)
            selectedPhoto = photo
        }
    }

    func selectRange(from start: PhotoEntry, to end: PhotoEntry) {
        guard let startIndex = filteredPhotos.firstIndex(where: { $0.id == start.id }),
              let endIndex = filteredPhotos.firstIndex(where: { $0.id == end.id }) else { return }

        let range = min(startIndex, endIndex)...max(startIndex, endIndex)
        for i in range {
            selectedPhotos.insert(filteredPhotos[i].id)
        }
        selectedPhoto = end
    }

    func selectAll() {
        if !isSelectMode {
            enterSelectMode()
        }
        selectedPhotos = Set(filteredPhotos.map { $0.id })
        if let first = filteredPhotos.first {
            selectedPhoto = first
        }
    }

    func selectPhotoIds(_ ids: Set<String>) {
        selectedPhotos = ids
        selectedPhoto = filteredPhotos.first { ids.contains($0.id) }
    }

    func updateGridColumnCount(_ count: Int) {
        gridColumnCount = max(1, count)
    }

    func navigateToPrevious() {
        navigate(offset: -1)
    }

    func navigateToNext() {
        navigate(offset: 1)
    }

    func navigateUp() { navigate(offset: -gridColumnCount) }
    func navigateDown() { navigate(offset: gridColumnCount) }
    func navigateLeft() { navigateToPrevious() }
    func navigateRight() { navigateToNext() }

    private func navigate(offset: Int) {
        guard !filteredPhotos.isEmpty else { return }
        let currentIndex: Int
        if let current = selectedPhoto,
           let index = filteredIndexById[current.id] {
            currentIndex = index
        } else {
            currentIndex = offset >= 0 ? -1 : filteredPhotos.count
        }

        let nextIndex = min(max(currentIndex + offset, 0), filteredPhotos.count - 1)
        let next = filteredPhotos[nextIndex]
        selectedPhoto = next
        selectedPhotos = [next.id]
    }

    func requestDelete(_ photo: PhotoEntry) {
        guard !isDeleting else { return }
        photosToDelete = [photo]
        showingDeleteConfirmation = true
    }

    func requestDeleteSelected() {
        guard !isDeleting else { return }
        let entries = selectedPhotoEntries.isEmpty ? selectedPhoto.map { [$0] } ?? [] : selectedPhotoEntries
        guard !entries.isEmpty else { return }
        photosToDelete = entries
        showingDeleteConfirmation = true
    }

    func confirmDelete() {
        guard !isDeleting else { return }
        let deleteRequest = photosToDelete
        let sourceIDs = Set(deleteRequest.map(\.sourceID))
        guard !sourceIDs.isEmpty else { return }
        let requestedDeleteIds = Set(photos.filter { sourceIDs.contains($0.sourceID) }.map(\.id))
        let previousFilteredPhotos = filteredPhotos
        let selectionAnchorIndex = deletionSelectionAnchorIndex(
            deleteIds: requestedDeleteIds,
            in: previousFilteredPhotos
        )

        photosToDelete = []
        showingDeleteConfirmation = false
        isDeleting = true
        let loadID = currentLoadID
        let fileServiceRef = self.fileService
        let photosToTrash = sourceIDs.compactMap { source in
            deleteRequest.first { $0.sourceID == source }
        }
        Task {
            await waitForTagWrites()
            let outcomes = await Task.detached(priority: .utility) {
                photosToTrash.map { ($0.sourceID, fileServiceRef.movePhotoToTrash($0)) }
            }.value
            isDeleting = false
            let failures = outcomes.flatMap { $0.1.failures }
            if !failures.isEmpty {
                exportMessage = "移至废纸篓未全部完成：\(failures.joined(separator: "\n"))。失败文件仍保留，裁剪记录未删除。"
            }
            // A folder switch or refresh can happen while disk operations are running.
            guard currentLoadID == loadID else { return }
            let results = Dictionary(uniqueKeysWithValues: outcomes)
            for index in photos.indices {
                guard let result = results[photos[index].sourceID] else { continue }
                if result.succeeded {
                    photos[index].isDeleted = true
                } else if !result.removedPaths.isEmpty {
                    photos[index] = photos[index].removingFiles(at: result.removedPaths)
                }
            }
            // Retain the catalog even after success so restoring the source from Trash
            // and refreshing also restores its nondestructive edits.
            let previousSelection = selectedPhoto
            applyFilters()
            selectedPhotos.formIntersection(Set(filteredPhotos.map(\.id)))
            if let previousSelection,
               let surviving = filteredPhotos.first(where: { $0.id == previousSelection.id }) {
                selectedPhoto = surviving
            } else {
                selectPhotoAfterDeletion(anchorIndex: selectionAnchorIndex)
            }
        }
    }

    private func deletionSelectionAnchorIndex(deleteIds: Set<String>, in photos: [PhotoEntry]) -> Int {
        if let selectedPhoto,
           deleteIds.contains(selectedPhoto.id),
           let selectedIndex = photos.firstIndex(where: { $0.id == selectedPhoto.id }) {
            return selectedIndex
        }

        let deletedIndexes = photos.indices.filter { deleteIds.contains(photos[$0].id) }
        if let firstDeletedIndex = deletedIndexes.min() {
            return firstDeletedIndex
        }

        if let selectedPhoto,
           let selectedIndex = photos.firstIndex(where: { $0.id == selectedPhoto.id }) {
            return selectedIndex
        }

        return 0
    }

    private func selectPhotoAfterDeletion(anchorIndex: Int) {
        guard !filteredPhotos.isEmpty else {
            selectedPhotos = []
            selectedPhoto = nil
            return
        }

        let nextIndex = min(anchorIndex, filteredPhotos.count - 1)
        let nextPhoto = filteredPhotos[nextIndex]
        selectedPhoto = nextPhoto
        selectedPhotos = [nextPhoto.id]
    }

    func detectVolumes() {
        let fm = FileManager.default
        let volumesRoot = "/Volumes"
        guard let volumeNames = try? fm.contentsOfDirectory(atPath: volumesRoot) else {
            detectedVolumes = []
            return
        }

        var results: [DetectedVolume] = []

        let homePath = NSHomeDirectory()
        let homePictures = (homePath as NSString).appendingPathComponent("Pictures")
        if fm.fileExists(atPath: homePictures) {
            results.append(DetectedVolume(name: "图片文件夹", path: homePictures, icon: "photo.on.rectangle"))
        }

        let homeDesktop = (homePath as NSString).appendingPathComponent("Desktop")
        if fm.fileExists(atPath: homeDesktop) {
            results.append(DetectedVolume(name: "桌面", path: homeDesktop, icon: "desktopcomputer"))
        }

        for name in volumeNames {
            let volPath = (volumesRoot as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: volPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let dcimPath = (volPath as NSString).appendingPathComponent("DCIM")
            if fm.fileExists(atPath: dcimPath) {
                let dcimSubDirs = scanDCIMSubdirectories(at: dcimPath, volumeName: name)
                if dcimSubDirs.isEmpty {
                    results.append(DetectedVolume(name: "\(name) — DCIM", path: dcimPath, icon: "sdcard"))
                } else {
                    results.append(contentsOf: dcimSubDirs)
                }
                continue
            }

            let hasMediaFiles = containsMediaFiles(at: volPath)
            if hasMediaFiles {
                results.append(DetectedVolume(name: name, path: volPath, icon: "externaldrive"))
            }
        }

        detectedVolumes = results
    }

    private func scanDCIMSubdirectories(at dcimPath: String, volumeName: String) -> [DetectedVolume] {
        let fm = FileManager.default
        guard let subDirs = try? fm.contentsOfDirectory(atPath: dcimPath) else { return [] }

        var results: [DetectedVolume] = []
        for dirName in subDirs {
            let subPath = (dcimPath as NSString).appendingPathComponent(dirName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subPath, isDirectory: &isDir), isDir.boolValue else { continue }
            if containsMediaFiles(at: subPath) {
                results.append(DetectedVolume(name: "\(volumeName) — \(dirName)", path: subPath, icon: "sdcard"))
            }
        }
        return results
    }

    private func containsMediaFiles(at path: String) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return false }
        let mediaExts: Set<String> = ["jpg", "jpeg", "nef", "cr2", "arw", "raw", "mov", "mp4", "heic", "png", "tiff"]
        return contents.contains { name in
            let ext = (name as NSString).pathExtension.lowercased()
            return mediaExts.contains(ext)
        }
    }

    func selectPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: sourcePath)

        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            Task {
                await loadPhotos()
            }
        }
    }

    func exportFilteredPhotos() {
        exportPhotos(filteredPhotos, scope: "筛选")
    }

    func exportSelectedPhotos() {
        exportPhotos(selectedPhotoEntries, scope: "所选")
    }

    private func exportPhotos(_ photosToExport: [PhotoEntry], scope: String) {
        guard !isExporting else { return }
        guard !photosToExport.isEmpty else {
            exportMessage = "没有可导出的照片"
            return
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())

        let defaultFileName = "\(dateStr)-\(filterOptions.exportFileNameSuffix)"
            + (scope == "所选" ? "-selected" : "")

        let panel = NSOpenPanel()
        panel.title = "导出\(scope)照片"
        panel.prompt = "选择保存位置"
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "将在所选位置创建文件夹「\(defaultFileName)」"

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }

        let destinationDir = (selectedURL.path as NSString).appendingPathComponent(defaultFileName)
        let fileTypeFilter = filterOptions.fileTypeFilter
        let total = photosToExport.count
        isExporting = true
        exportProgress = 0

        // 文件拷贝在后台线程执行，避免阻塞主线程冻结 UI；进度回到主线程更新
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var exported = 0
            var failed = 0

            if !fm.fileExists(atPath: destinationDir) {
                try? fm.createDirectory(atPath: destinationDir, withIntermediateDirectories: true)
            }

            for (index, photo) in photosToExport.enumerated() {
                let files: [(path: String, subdirectory: String?)]
                switch fileTypeFilter {
                case .jpgOnly:
                    files = photo.jpgPath.map { [($0, nil)] } ?? []
                case .nefOnly:
                    files = photo.nefPath.map { [($0, nil)] } ?? []
                case .jpgAndNef:
                    files = [
                        photo.jpgPath.map { ($0, "JPG") },
                        photo.nefPath.map { ($0, "RAW") }
                    ].compactMap { $0 }
                case .movOnly:
                    files = photo.movPath.map { [($0, nil)] } ?? []
                case .all, .hasMov:
                    files = [
                        photo.jpgPath.map { ($0, nil) },
                        photo.nefPath.map { ($0, nil) },
                        photo.movPath.map { ($0, nil) }
                    ].compactMap { $0 }
                }
                for (sourcePath, subdirectory) in files {
                    let fileDestination = subdirectory.map {
                        (destinationDir as NSString).appendingPathComponent($0)
                    } ?? destinationDir
                    if !fm.fileExists(atPath: fileDestination) {
                        try? fm.createDirectory(atPath: fileDestination, withIntermediateDirectories: true)
                    }
                    do {
                        if sourcePath == photo.movPath {
                            let source = URL(fileURLWithPath: sourcePath)
                            let stem = source.deletingPathExtension().lastPathComponent +
                                (photo.isVersionCopy ? "_\(photo.versionID!.uuidString.prefix(8))" : "")
                            var candidate = URL(fileURLWithPath: fileDestination)
                                .appendingPathComponent(stem).appendingPathExtension(source.pathExtension)
                            var suffix = 2
                            while fm.fileExists(atPath: candidate.path) {
                                candidate = URL(fileURLWithPath: fileDestination)
                                    .appendingPathComponent("\(stem)_\(suffix)")
                                    .appendingPathExtension(source.pathExtension)
                                suffix += 1
                            }
                            try fm.copyItem(at: source, to: candidate)
                        } else {
                            _ = try CropImageService.copyOrRender(photo: photo, sourcePath: sourcePath,
                                                                  into: URL(fileURLWithPath: fileDestination))
                        }
                        exported += 1
                    } catch {
                        failed += 1
                    }
                }
                let progress = Double(index + 1) / Double(max(total, 1))
                await MainActor.run { [weak self] in self?.exportProgress = progress }
            }

            let finalExported = exported
            let finalFailed = failed
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isExporting = false
                self.exportProgress = 0
                if finalFailed == 0 {
                    self.exportMessage = "已导出 \(total) 张照片（\(finalExported) 个文件）"
                } else {
                    self.exportMessage = "导出完成：\(total) 张照片，\(finalExported) 个成功，\(finalFailed) 个失败"
                }
            }
        }
    }

    func exportWatermarkedPhotos(_ requests: [WatermarkExportRequest], to directory: URL) {
        guard !requests.isEmpty, !isExporting else { return }
        isExporting = true
        exportProgress = 0

        Task.detached(priority: .utility) {
            var exported = 0
            var failures: [String] = []
            for (index, request) in requests.enumerated() {
                do {
                    try WatermarkService.export(request: request, to: directory)
                    exported += 1
                } catch {
                    failures.append("\(request.photo.displayName)：\(error.localizedDescription)")
                }
                let progress = Double(index + 1) / Double(requests.count)
                await MainActor.run { [weak self] in self?.exportProgress = progress }
            }

            let completed = exported
            let firstFailure = failures.first
            let failed = failures.count
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isExporting = false
                self.exportProgress = 0
                self.exportMessage = failed == 0
                    ? "已输出 \(completed) 张水印照片到 \(directory.path)"
                    : "水印导出完成：\(completed) 张成功，\(failed) 张失败。首个错误：\(firstFailure ?? "未知错误")"
            }
        }
    }

    func exportOriginalPhoto(_ photo: PhotoEntry) {
        guard !isExporting else { return }
        let paths = [photo.jpgPath, photo.nefPath, photo.movPath].compactMap { $0 }
        guard !paths.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "导出原文件"
        panel.prompt = "导出到此目录"
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        isExporting = true
        exportProgress = 0
        Task.detached(priority: .utility) {
            var count = 0
            var errors: [String] = []
            for (index, path) in paths.enumerated() {
                let source = URL(fileURLWithPath: path)
                do {
                    if path == photo.movPath {
                        _ = try CropImageService.copyOrRender(
                            photo: photo.asVersion(CropVersion(id: nil, name: nil, crop: nil)),
                            sourcePath: path, into: directory)
                    } else {
                        _ = try CropImageService.copyOrRender(photo: photo, sourcePath: path, into: directory)
                    }
                    count += 1
                } catch {
                    errors.append("\(source.lastPathComponent)：\(error.localizedDescription)")
                }
                await MainActor.run { [weak self] in
                    self?.exportProgress = Double(index + 1) / Double(paths.count)
                }
            }
            let result = errors.isEmpty ? "已导出 \(count) 个原文件到 \(directory.path)"
                : "已导出 \(count) 个原文件，\(errors.count) 个失败。\(errors[0])"
            await MainActor.run { [weak self] in
                self?.isExporting = false
                self?.exportProgress = 0
                self?.exportMessage = result
            }
        }
    }
}
