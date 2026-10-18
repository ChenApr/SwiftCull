import SwiftUI
import AVKit

private struct GridThumbnailLoadingKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var gridThumbnailLoadingEnabled: Bool {
        get { self[GridThumbnailLoadingKey.self] }
        set { self[GridThumbnailLoadingKey.self] = newValue }
    }
}

struct AsyncThumbnailView: View {
    @Environment(\.gridThumbnailLoadingEnabled) private var loadingEnabled
    let photoId: String
    let imagePath: String
    let size: CGFloat
    let isVideo: Bool
    let crop: CropRect?

    init(photoId: String, imagePath: String, size: CGFloat, isVideo: Bool = false, crop: CropRect? = nil) {
        self.photoId = photoId
        self.imagePath = imagePath
        self.size = size
        self.isVideo = isVideo
        self.crop = crop
        let cached = ThumbnailService.shared.getCached(ThumbnailService.cacheKey(path: imagePath, size: size, crop: crop))
        self._image = State(initialValue: cached)
    }

    @State private var image: NSImage?
    @State private var loadTask: Task<Void, Never>?
    @State private var deliveryID = UUID()

    private var renderSize: CGFloat {
        CGFloat(ThumbnailService.quantizedSize(size))
    }

    private var cacheId: String {
        ThumbnailService.cacheKey(path: imagePath, size: size, crop: crop)
    }

    var body: some View {
        Group {
            if let image = image {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                    if isVideo {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 2)
                                    .padding(4)
                            }
                        }
                    }
                }
            } else if isVideo {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    Image(systemName: "video.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            } else {
                ZStack {
                    Color(nsColor: .textBackgroundColor)
                    Image(systemName: "photo")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            GridImageDelivery.shared.cancel(id: deliveryID)
            deliveryID = UUID()
        }
        .onChange(of: cacheId) { _, _ in
            // 保留旧缩略图，待新尺寸就绪后再替换，缩放时不闪烁
            loadTask?.cancel()
            loadThumbnail()
        }
        .onChange(of: loadingEnabled) { _, enabled in
            if enabled { loadThumbnail() }
            else {
                loadTask?.cancel()
                loadTask = nil
                GridImageDelivery.shared.cancel(id: deliveryID)
                deliveryID = UUID()
            }
        }
    }

    private func loadThumbnail() {
        loadTask?.cancel()
        GridImageDelivery.shared.cancel(id: deliveryID)
        deliveryID = UUID()
        guard loadingEnabled else { return }
        let service = ThumbnailService.shared

        if let cached = service.getCached(cacheId) {
            if image !== cached { self.image = cached }
            return
        }

        guard !imagePath.isEmpty else { return }

        let requestCacheId = cacheId
        let requestPath = imagePath
        let requestSize = renderSize
        let requestCrop = crop
        let requestDeliveryID = deliveryID
        loadTask = Task { @MainActor in
            let newImage = await service.thumbnail(path: requestPath, id: requestCacheId,
                                                   size: requestSize, crop: requestCrop)
            guard !Task.isCancelled else { return }
            guard cacheId == requestCacheId, let newImage else { return }
            GridImageDelivery.shared.submit(id: requestDeliveryID) {
                guard deliveryID == requestDeliveryID else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { self.image = newImage }
            }
        }
    }
}

/// A bounded, cached preview for the inspector. Full-size viewing keeps its
/// independent decode path below so zooming is not limited by this thumbnail.
struct InspectorThumbnailView: View {
    let photo: PhotoEntry
    @State private var image: NSImage?
    @State private var loadedKey: String?

    private var cacheKey: String { ThumbnailService.inspectorCacheKey(for: photo) }

    var body: some View {
        Group {
            if let image, loadedKey == cacheKey {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: cacheKey) {
            let requestKey = cacheKey
            let service = ThumbnailService.shared
            let loaded: NSImage?
            if let cached = service.getCached(requestKey) {
                loaded = cached
            } else {
                loaded = await service.inspectorThumbnail(for: photo)
            }
            guard !Task.isCancelled, requestKey == cacheKey else { return }
            // Image arrival must not inherit the grid/inspector layout animation.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                image = loaded
                loadedKey = requestKey
            }
        }
    }
}

struct DetailThumbnailView: View {
    let photo: PhotoEntry
    let zoomRequest: PhotoZoomRequest?
    @Binding var scale: CGFloat
    var onSingleClick: () -> Void
    var onImageReady: () -> Void = {}
    @Environment(\.displayScale) private var displayScale
    @State private var image: NSImage?
    @State private var loadedKey: String?
    @State private var loadedPixels = 0
    @State private var navigationTiming = PreviewNavigationTiming()

    private var sourceKey: String { "\(photo.id)|\(PhotoPreviewService.sourceKey(for: photo))" }

    var body: some View {
        GeometryReader { geometry in
            let pixels = PhotoPreviewService.pixelTier(viewport: geometry.size, displayScale: displayScale, zoom: scale)
            let displayedImage = loadedKey == sourceKey ? image
                : (PhotoPreviewService.shared.cached(for: photo, pixels: pixels)
                    ?? ThumbnailService.shared.getCached(ThumbnailService.inspectorCacheKey(for: photo)))
            PhotoZoomViewport(image: displayedImage, sourceID: sourceKey, request: zoomRequest,
                              onScaleChange: { scale = $0 }, onSingleClick: onSingleClick)
                .overlay {
                    if displayedImage == nil {
                        ProgressView().controlSize(.small).allowsHitTesting(false)
                    }
                }
                .task(id: "\(sourceKey)|\(pixels)") {
                    let requestKey = sourceKey
                    let changingPhoto = loadedKey != requestKey
                    let started = ProcessInfo.processInfo.systemUptime
                    let rapidNavigation = changingPhoto && navigationTiming.isRapid(at: started)
                    // A smaller viewport/zoom must not downgrade a sharper image.
                    if !changingPhoto, loadedPixels >= pixels { return }
                    if let cached = PhotoPreviewService.shared.cached(for: photo, pixels: pixels) {
                        commit(cached, key: requestKey, pixels: pixels)
                        onImageReady()
                        return
                    }
                    if changingPhoto {
                        let preview = await ThumbnailService.shared.inspectorThumbnail(for: photo)
                        guard !Task.isCancelled else { return }
                        commit(preview, key: requestKey, pixels: 960)
                    }
                    guard !photo.isVideoOnly else { onImageReady(); return }
                    // Resize and live zoom settle before increasing decode resolution.
                    // AppKit keeps transforming the existing image throughout the gesture.
                    if rapidNavigation || !changingPhoto {
                        let remaining = 0.12 - (ProcessInfo.processInfo.systemUptime - started)
                        if remaining > 0 {
                            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                        }
                    }
                    let loaded = await PhotoPreviewService.shared.image(for: photo, pixels: pixels)
                    guard !Task.isCancelled, requestKey == sourceKey, let loaded else { return }
                    commit(loaded, key: requestKey, pixels: pixels)
                    onImageReady()
                }
        }
    }

    private func commit(_ loaded: NSImage?, key: String, pixels: Int) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            image = loaded
            loadedKey = key
            loadedPixels = pixels
        }
    }
}

/// Per-view timing has no published state, so navigation bookkeeping adds no render.
private final class PreviewNavigationTiming {
    private var previous = -Double.infinity

    func isRapid(at time: Double) -> Bool {
        defer { previous = time }
        return time - previous < 0.15
    }
}

