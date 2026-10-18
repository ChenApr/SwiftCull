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
            if oldValue?.id != selectedPhoto?.id {
                exitVideoPlaybackMode()
                scheduleVisibleTagLoad()
                schedulePreviewPreheat()
            }
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
    @Published private(set) var captureDatesReady = false
    private(set) var needsDateGrouping = false
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
            guard oldValue != viewMode else { return }
            scheduleVisibleTagLoad()
            schedulePreviewPreheat()
            if viewMode == .single {
                preheatTask?.cancel()
                thumbnailService.preloadThumbnails(paths: [], size: 128)
            }
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
    private let dateIndex: PhotoDateIndex
    private var dateRequestID = UUID()
    private var tagIndexTask: Task<Void, Never>?
    private var visibleTagTask: Task<Void, Never>?
    private var visiblePhotoIDs: Set<String> = []
    private(set) var isGridScrolling = false
    private var deferredTagValues: [String: [String]] = [:]
    private var deferredTagRevisions: [String: UUID] = [:]
    private var loadedTagSources: Set<String> = []
    private var tagFilterReady = false
    private var editSessionID = UUID()
    private struct PendingTagAction {
        let id = UUID()
        let loadID: UUID
        let sessionID: UUID
        let photos: [PhotoEntry]
        let action: () -> Void
    }
    private var pendingTagActions: [PendingTagAction] = []
    private var tagActionTask: Task<Void, Never>?
    private var tagWriteIDs: [String: UUID] = [:]

    /// 选择模式下被编辑过的照片在编辑前的原始状态（用于「取消」纯内存回滚，零磁盘 IO）
    private struct OriginalPhotoState {
        let rating: Int
        let tags: [String]
    }
    private var editedOriginals: [String: OriginalPhotoState] = [:]

    private var gridColumnCount = 1
    private var currentLoadID = UUID()
    private var latestLoadRequestID = UUID()
    private var lastPreheatKey: String?
    private var preheatTask: Task<Void, Never>?
    private var previewPreheatTask: Task<Void, Never>?
    /// filteredPhotos 的 id→下标缓存，随 applyFilters 重建，供滚动预热/方向键导航 O(1) 定位。
    private var filteredIndexById: [String: Int] = [:]
    private var cachedTotalSize = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
    private var tagColorLookup: [String: Int] {
        finderTagService.tagColorLookup
    }

    init(fileService: FileService = .shared, ratingService: RatingService = .shared,
         projectMetadata: ProjectMetadataService = .shared, dateIndex: PhotoDateIndex = .shared) {
        self.fileService = fileService
        self.ratingService = ratingService
        self.projectMetadata = projectMetadata
        self.dateIndex = dateIndex
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
        // Termination cannot await the main actor. Finish already requested edits
        // before draining their writes; ordinary browsing never uses this sync path.
        while let pending = pendingTagActions.first {
            let values = tagWriteQueue.sync {
                Dictionary(uniqueKeysWithValues: pending.photos.map {
                    ($0.sourceID, tagService.getTagsForPhotoPair($0))
                })
            }
            finishTagAction(pending, values: values)
        }
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
        let ids = Set(targets.map(\.id))
        let selectionMode = isSelectMode
        withLoadedTags(for: ids) { [self] in
            let current = photos.filter { ids.contains($0.id) }
            let remove = current.allSatisfy { $0.tags.contains(tag) }
            if selectionMode {
                updateLoadedTag(tag, adding: !remove, for: ids)
            } else {
                current.forEach { remove ? removeLoadedTag(tag, from: $0) : addLoadedTag(tag, to: $0) }
            }
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
        let requestID = UUID()
        latestLoadRequestID = requestID
        let folderPath = sourcePath
        // Preserve accepted tag edits before replacing the folder/session.
        await tagActionTask?.value
        guard latestLoadRequestID == requestID else { return }
        let loadID = UUID()
        enrichmentTask?.cancel()
        enrichmentTask = nil
        dateRequestID = UUID()
        tagIndexTask?.cancel()
        tagIndexTask = nil
        visibleTagTask?.cancel()
        visibleTagTask = nil
        visiblePhotoIDs = []
        isGridScrolling = false
        GridImageDelivery.shared.setScrolling(false)
        deferredTagValues = [:]
        deferredTagRevisions = [:]
        loadedTagSources = []
        tagFilterReady = false
        captureDatesReady = false
        editSessionID = UUID()
        currentLoadID = loadID
        tagWriteIDs.removeAll()
        lastPreheatKey = nil
        preheatTask?.cancel()
        preheatTask = nil
        previewPreheatTask?.cancel()
        previewPreheatTask = nil
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
        filteredIndexById = [:]
        loadingProgress = 1
        loadingStatus = fast.isEmpty ? "未找到可识别的照片" : "加载完成"
        isLoading = false

        applyFilters()
    }

    /// Date and tag indexes are independent: ordinary browsing opens no image headers.
    func setDateGroupingEnabled(_ enabled: Bool) {
        needsDateGrouping = enabled
        refreshMetadataDemand()
    }

    func waitForCaptureDates() async -> Bool {
        let loadID = currentLoadID
        await enrichmentTask?.value
        return currentLoadID == loadID && captureDatesReady
    }

    func areTagsLoaded(for photo: PhotoEntry) -> Bool {
        loadedTagSources.contains(photo.sourceID)
    }

    private func updateIndexStatus() {
        isEnriching = enrichmentTask != nil || tagIndexTask != nil
        if enrichmentTask != nil {
            enrichStatus = "正在建立拍摄日期索引，完成后更新时间顺序与分组…"
        } else if tagIndexTask != nil {
            enrichStatus = "正在读取 Finder 标签，完成后应用筛选…"
        } else {
            enrichStatus = ""
            enrichProgress = 0
        }
    }

    private func refreshMetadataDemand() {
        guard !isLoading, !photos.isEmpty else { return }
        let needsDates = filterOptions.sortOption == .date || filterOptions.dateFilterEnabled || needsDateGrouping
        if !needsDates {
            enrichmentTask?.cancel()
            enrichmentTask = nil
            dateRequestID = UUID()
        } else if !captureDatesReady && enrichmentTask == nil {
            let loadID = currentLoadID
            let requestID = UUID()
            dateRequestID = requestID
            let folder = sourcePath
            let sources = photos.filter { !$0.isVersionCopy && !$0.isDeleted }
            let index = dateIndex
            enrichmentTask = Task(priority: .utility) { [weak self] in
                // Give initial visible thumbnails a head start.
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                var dates: [String: Date] = [:]
                for start in stride(from: 0, to: sources.count, by: 64) {
                    guard await self?.waitForGridIdle(loadID: loadID) == true else { await index.flush(); return }
                    guard !Task.isCancelled else { await index.flush(); return }
                    let batch = Array(sources[start..<min(start + 64, sources.count)])
                    let values = await index.dates(for: batch, folderPath: folder)
                    guard let self, !Task.isCancelled, self.currentLoadID == loadID,
                          self.dateRequestID == requestID else { await index.flush(); return }
                    dates.merge(values) { _, new in new }
                    self.enrichProgress = Double(min(start + 64, sources.count)) / Double(max(1, sources.count))
                }
                await index.flush()
                guard await self?.waitForGridIdle(loadID: loadID) == true else { return }
                guard let self, !Task.isCancelled, self.currentLoadID == loadID,
                      self.dateRequestID == requestID else { return }
                // Commit the complete index once. Selecting a photo never changes grid order.
                var updated = self.photos
                for i in updated.indices {
                    if let date = dates[updated[i].sourceID] { updated[i].fileDate = date }
                }
                self.photos = updated
                if let id = self.selectedPhoto?.id {
                    self.selectedPhoto = updated.first { $0.id == id && !$0.isDeleted }
                }
                self.captureDatesReady = true
                self.enrichmentTask = nil
                self.applyFilters()
            }
        }

        if filterOptions.tagFilter == nil {
            tagIndexTask?.cancel()
            tagIndexTask = nil
        } else if !tagFilterReady && tagIndexTask == nil {
            let loadID = currentLoadID
            let sources = photos.filter { !$0.isVersionCopy && !$0.isDeleted && !loadedTagSources.contains($0.sourceID) }
            tagIndexTask = Task(priority: .utility) { [weak self] in
                let revisions = self?.tagWriteIDs ?? [:]
                var allValues: [String: [String]] = [:]
                for start in stride(from: 0, to: sources.count, by: 64) {
                    guard await self?.waitForGridIdle(loadID: loadID) == true else { return }
                    guard let self, !Task.isCancelled, self.currentLoadID == loadID else { return }
                    let batch = Array(sources[start..<min(start + 64, sources.count)])
                    let values = await self.readTags(batch)
                    guard !Task.isCancelled, self.currentLoadID == loadID else { return }
                    allValues.merge(values) { _, new in new }
                    if self.enrichmentTask == nil {
                        self.enrichProgress = Double(min(start + 64, sources.count)) / Double(max(1, sources.count))
                    }
                }
                guard await self?.waitForGridIdle(loadID: loadID) == true else { return }
                guard let self, !Task.isCancelled, self.currentLoadID == loadID else { return }
                self.acceptTags(allValues, revisions: revisions)
                self.tagFilterReady = true
                self.tagIndexTask = nil
                self.applyFilters()
            }
        }
        updateIndexStatus()
    }

    func photoDidAppear(_ photo: PhotoEntry) {
        visiblePhotoIDs.insert(photo.id)
        if viewMode == .grid && !isGridScrolling { scheduleVisibleTagLoad() }
    }

    func photoDidDisappear(_ photo: PhotoEntry) {
        visiblePhotoIDs.remove(photo.id)
        if viewMode == .grid && !isGridScrolling { scheduleVisibleTagLoad() }
    }

    func setGridScrolling(_ scrolling: Bool) {
        guard scrolling != isGridScrolling else { return }
        isGridScrolling = scrolling
        GridImageDelivery.shared.setScrolling(scrolling)
        if scrolling {
            visibleTagTask?.cancel()
        } else {
            let values = deferredTagValues
            let revisions = deferredTagRevisions
            deferredTagValues = [:]
            deferredTagRevisions = [:]
            acceptTags(values, revisions: revisions)
            scheduleVisibleTagLoad()
        }
    }

    private func waitForGridIdle(loadID: UUID) async -> Bool {
        while isGridScrolling {
            do { try await Task.sleep(for: .milliseconds(30)) } catch { return false }
            guard currentLoadID == loadID else { return false }
        }
        return !Task.isCancelled && currentLoadID == loadID
    }

    private func scheduleVisibleTagLoad() {
        visibleTagTask?.cancel()
        let loadID = currentLoadID
        visibleTagTask = Task(priority: .utility) { [weak self] in
            // Coalesce card appearances; continuous scrolling prioritizes thumbnails.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, self.currentLoadID == loadID, !self.isLoading, !self.isGridScrolling else { return }
            let selected = self.selectedPhoto?.sourceID
            var seen: Set<String> = []
            let targets = self.photos.filter {
                !self.loadedTagSources.contains($0.sourceID) &&
                ((self.viewMode == .grid && self.visiblePhotoIDs.contains($0.id)) || $0.sourceID == selected) &&
                !$0.isDeleted && seen.insert($0.sourceID).inserted
            }
            let revisions = self.tagWriteIDs
            let values = await self.readTags(targets)
            guard !Task.isCancelled, self.currentLoadID == loadID else { return }
            if self.isGridScrolling {
                self.deferredTagValues.merge(values) { _, new in new }
                for source in values.keys { self.deferredTagRevisions[source] = revisions[source] }
                return
            }
            self.acceptTags(values, revisions: revisions)
        }
    }

    private func readTags(_ targets: [PhotoEntry]) async -> [String: [String]] {
        var values: [String: [String]] = [:]
        for photo in targets {
            guard !Task.isCancelled else { break }
            let tags: [String] = await withCheckedContinuation { continuation in
                tagWriteQueue.async {
                    continuation.resume(returning: TagService.shared.getTagsForPhotoPair(photo))
                }
            }
            values[photo.sourceID] = tags
        }
        return values
    }

    private func acceptTags(_ values: [String: [String]], revisions: [String: UUID]) {
        let accepted = values.filter { !loadedTagSources.contains($0.key) && tagWriteIDs[$0.key] == revisions[$0.key] }
        guard !accepted.isEmpty else { return }
        loadedTagSources.formUnion(accepted.keys)
        var updated = photos
        var photosChanged = false
        for i in updated.indices {
            guard let tags = accepted[updated[i].sourceID] else { continue }
            if updated[i].tags != tags { updated[i].tags = tags; photosChanged = true }
            // A rating-only edit may have captured a not-yet-loaded tag baseline.
            if let original = editedOriginals[updated[i].id] {
                editedOriginals[updated[i].id] = OriginalPhotoState(rating: original.rating, tags: tags)
            }
        }
        if photosChanged { photos = updated }
        var filtered = filteredPhotos
        var filteredChanged = false
        for i in filtered.indices {
            if let tags = accepted[filtered[i].sourceID], filtered[i].tags != tags {
                filtered[i].tags = tags
                filteredChanged = true
            }
        }
        if filteredChanged { filteredPhotos = filtered }
        if let source = selectedPhoto?.sourceID, let tags = accepted[source] { selectedPhoto?.tags = tags }
    }

    /// Tag edits wait for their original disk values, in user action order.
    /// Captured IDs and session tokens prevent delayed edits affecting another selection/folder.
    private func withLoadedTags(for ids: Set<String>, action: @escaping () -> Void) {
        var seen: Set<String> = []
        let targets = photos.filter {
            ids.contains($0.id) && !loadedTagSources.contains($0.sourceID) && seen.insert($0.sourceID).inserted
        }
        if targets.isEmpty && pendingTagActions.isEmpty {
            action()
            return
        }
        let pending = PendingTagAction(loadID: currentLoadID, sessionID: editSessionID, photos: targets, action: action)
        pendingTagActions.append(pending)
        guard tagActionTask == nil else { return }
        tagActionTask = Task { [weak self] in
            while let self, let next = self.pendingTagActions.first {
                let targets = next.photos.filter { !self.loadedTagSources.contains($0.sourceID) }
                let values = await self.readTags(targets)
                self.finishTagAction(next, values: values)
            }
            self?.tagActionTask = nil
        }
    }

    private func finishTagAction(_ pending: PendingTagAction, values: [String: [String]]) {
        guard pendingTagActions.first?.id == pending.id else { return }
        pendingTagActions.removeFirst()
        guard pending.loadID == currentLoadID, pending.sessionID == editSessionID else { return }
        acceptTags(values, revisions: tagWriteIDs)
        pending.action()
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
        guard viewMode == .grid else { return }
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
            guard let self, self.viewMode == .grid, self.currentLoadID == loadID,
                  self.filteredPhotosVersion == photosVersion else { return }
            let lowerBound = max(0, centerIndex - columns * 2)
            let upperBound = min(self.filteredPhotos.count, centerIndex + columns * 4 + 1)
            let items = self.filteredPhotos[lowerBound..<upperBound].map { photo in
                (path: photo.primaryFilePath, crop: photo.cropRect)
            }
            self.thumbnailService.preloadThumbnails(paths: items, size: CGFloat(quantizedSize))
        }
    }

    func previewDidLoad(photoID: String) {
        guard selectedPhoto?.id == photoID else { return }
        schedulePreviewPreheat(delay: .zero)
    }

    private func schedulePreviewPreheat(delay: Duration = .milliseconds(500)) {
        previewPreheatTask?.cancel()
        guard viewMode == .single, let selected = selectedPhoto,
              let center = filteredIndexById[selected.id] else {
            thumbnailService.preloadInspectorThumbnails(photos: [])
            return
        }
        let neighbors = [1, -1, 2].compactMap { offset -> PhotoEntry? in
            let index = center + offset
            return filteredPhotos.indices.contains(index) ? filteredPhotos[index] : nil
        }
        let loadID = currentLoadID
        previewPreheatTask = Task { [weak self] in
            // Do not compete with the current original decode. Its completion
            // warms neighbors immediately; the delay also covers video/failure paths.
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.currentLoadID == loadID, self.viewMode == .single,
                  self.selectedPhoto?.id == selected.id else { return }
            self.thumbnailService.preloadInspectorThumbnails(photos: neighbors)
        }
    }

    func applyFilters() {
        refreshMetadataDemand()
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

            if tagFilterReady, let tagFilter, !photo.tags.contains(tagFilter) { continue }

            // 日期范围过滤（仅开启时生效）
            if filterOptions.dateFilterEnabled && captureDatesReady {
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
        case .date where !captureDatesReady:
            // Keep the displayed order until the complete capture-date index is
            // ready, instead of temporarily sorting by unrelated filesystem dates.
            sorted = representatives.sorted {
                let lhs = filteredIndexById[$0.id] ?? Int.max
                let rhs = filteredIndexById[$1.id] ?? Int.max
                if lhs != rhs { return filterOptions.sortAscending ? lhs < rhs : lhs > rhs }
                return $0.baseName < $1.baseName
            }
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
        var all = photos
        for index in all.indices where all[index].sourceID == photo.sourceID { all[index].rating = rating }
        if all != photos { photos = all }
        var filtered = filteredPhotos
        for index in filtered.indices where filtered[index].sourceID == photo.sourceID { filtered[index].rating = rating }
        if filtered != filteredPhotos { filteredPhotos = filtered }
        if selectedPhoto?.sourceID == photo.sourceID { selectedPhoto?.rating = rating }
        syncSidecar()
    }

    func clearTags(for photo: PhotoEntry) {
        withLoadedTags(for: [photo.id]) { [self] in clearLoadedTags(for: photo) }
    }

    private func clearLoadedTags(for photo: PhotoEntry) {
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
        withLoadedTags(for: ids) { [self] in updateLoadedTag(tag, adding: adding, for: ids) }
    }

    private func updateLoadedTag(_ tag: String, adding: Bool, for ids: Set<String>) {
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
        withLoadedTags(for: ids) { [self] in clearLoadedTags(for: ids) }
    }

    private func clearLoadedTags(for ids: Set<String>) {
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
        withLoadedTags(for: [photo.id]) { [self] in addLoadedTag(tag, to: photo) }
    }

    private func addLoadedTag(_ tag: String, to photo: PhotoEntry) {
        guard let index = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        var currentTags = photos[index].tags
        if !currentTags.contains(tag) {
            currentTags.append(tag)
            scheduleTagWrite(currentTags, for: photos[index])
            setSharedTags(currentTags, sourceID: photo.sourceID)
        }
    }

    func removeTag(_ tag: String, from photo: PhotoEntry) {
        withLoadedTags(for: [photo.id]) { [self] in removeLoadedTag(tag, from: photo) }
    }

    private func removeLoadedTag(_ tag: String, from photo: PhotoEntry) {
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
        editSessionID = UUID()
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
        // Cancelling a drag selection must not close an already-open inspector.
        // Refresh its focused entry so rolled-back ratings and tags are displayed.
        if isInspectorVisible, let focusedID = selectedPhoto?.id {
            selectedPhoto = photos.first { $0.id == focusedID && !$0.isDeleted }
        } else {
            selectedPhoto = nil
        }
        isSelectMode = false
    }

    /// 完成：把本次会话的改动一次性落盘（标签写盘在后台线程）
    func confirmSelectMode() {
        withLoadedTags(for: []) { [self] in finishSelectModeEdits() }
    }

    private func finishSelectModeEdits() {
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
            openFolder(from: [url])
        }
    }

    @discardableResult
    func openFolder(from urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first else {
            exportMessage = "请每次拖入一个照片文件夹。"
            return false
        }
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
              values.isDirectory == true, values.isPackage != true else {
            exportMessage = "请选择一个有效的文件夹，而不是照片或应用程序。"
            return false
        }
        sourcePath = url.standardizedFileURL.path
        Task { await loadPhotos() }
        return true
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
                    _ = try autoreleasepool { try WatermarkService.export(request: request, to: directory) }
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
                    ? "已导出 \(completed) 张照片到 \(directory.path)"
                    : "照片导出完成：\(completed) 张成功，\(failed) 张失败。首个错误：\(firstFailure ?? "未知错误")"
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
