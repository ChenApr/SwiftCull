import SwiftUI

/// The image always shows the complete source; the saved crop only initializes the editable frame.
struct PhotoCropEditorView: View {
    @EnvironmentObject private var store: PhotoStore
    @Environment(\.dismiss) private var dismiss
    let photo: PhotoEntry

    @State private var image: NSImage?
    @State private var fullWidth = 0
    @State private var fullHeight = 0
    @State private var crop: CropRect = .full
    @State private var aspect: CropAspectRatio = .free
    @State private var newVersionName = ""
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var steadyPan: CGSize = .zero
    @State private var dragStartCrop: CropRect?
    @State private var dragMode: DragMode = .pan
    @State private var spaceHeld = false
    @State private var keyMonitor: Any?

    private enum DragMode { case pan, move, topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("裁剪 · \(photo.displayName)").font(.headline)
                Spacer()
                Text("拖动框内移动 · 拖动四角调整 · 空格拖动平移 · 捏合缩放 · 双击复位")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)

            Picker("裁剪比例", selection: Binding(
                get: { aspect },
                set: { selected in
                    guard fullWidth > 0, fullHeight > 0 else { aspect = selected; return }
                    crop = CropGeometry.fitted(crop, imageWidth: fullWidth,
                                               imageHeight: fullHeight, aspect: selected)
                    aspect = selected
                }
            )) {
                ForEach(CropAspectRatio.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .disabled(fullWidth == 0)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.9)
                    if let image {
                        let frame = imageFrame(canvas: geometry.size, image: image)
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                        cropOverlay(imageFrame: frame)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
                .contentShape(Rectangle())
                .gesture(editorDrag(canvas: geometry.size))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        zoom = min(8, max(1, steadyZoom * value.magnification))
                        limitPan(canvas: geometry.size)
                    }
                    .onEnded { _ in steadyZoom = zoom })
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    zoom = 1; steadyZoom = 1; pan = .zero; steadyPan = .zero
                })
                .clipped()
                .onChange(of: geometry.size) { _, size in limitPan(canvas: size) }
            }
            .frame(minWidth: 700, minHeight: 480)

            HStack(spacing: 12) {
                Button("恢复原片") { crop = .full; aspect = .free }
                Spacer()
                TextField("新版本名称（可选）", text: $newVersionName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                Button("另存为新版本") { save(createCopy: true) }
                    .disabled(image == nil)
                Button("取消") { dismiss() }
                Button("保存到当前版本") { save(createCopy: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(image == nil)
            }
            .padding(16)
        }
        .frame(minWidth: 760, minHeight: 570)
        .onAppear {
            crop = photo.cropRect ?? .full
            aspect = photo.cropAspect ?? .free
            newVersionName = "裁剪 \(store.versions(for: photo).count)"
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
                if event.keyCode == 49 {
                    if NSApp.keyWindow?.firstResponder is NSTextView { return event }
                    spaceHeld = event.type == .keyDown
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            spaceHeld = false
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            spaceHeld = false
        }
        .task(id: photo.id) {
            let path = photo.primaryImagePath
            let result = await Task.detached(priority: .userInitiated) { () -> (CGImage, Int, Int)? in
                guard let dimensions = try? CropImageService.orientedDimensions(path: path),
                      let image = try? CropImageService.image(path: path, maxPixelSize: 2400) else {
                    return nil
                }
                return (image, dimensions.width, dimensions.height)
            }.value
            if let result, !Task.isCancelled {
                image = NSImage(cgImage: result.0, size: NSSize(width: result.0.width, height: result.0.height))
                fullWidth = result.1
                fullHeight = result.2
            }
        }
    }

    private func save(createCopy: Bool) {
        if store.saveCrop(crop.isFull ? nil : crop, aspect: aspect, for: photo,
                          createCopy: createCopy, name: newVersionName) {
            dismiss()
        }
    }

    private func imageFrame(canvas: CGSize, image: NSImage) -> CGRect {
        CropViewport.imageFrame(canvas: canvas, image: image.size, zoom: zoom, pan: pan)
    }

    private func limitPan(canvas: CGSize) {
        guard let image else { return }
        pan = CropViewport.clampedPan(pan, canvas: canvas, image: image.size, zoom: zoom)
        steadyPan = pan
    }

    private func cropFrame(in imageFrame: CGRect) -> CGRect {
        CGRect(x: imageFrame.minX + imageFrame.width * crop.x,
               y: imageFrame.minY + imageFrame.height * crop.y,
               width: imageFrame.width * crop.width,
               height: imageFrame.height * crop.height)
    }

    @ViewBuilder
    private func cropOverlay(imageFrame: CGRect) -> some View {
        let selection = cropFrame(in: imageFrame)
        Path { path in
            path.addRect(imageFrame)
            path.addRect(selection)
        }
        .fill(.black.opacity(0.56), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        Rectangle().stroke(.white, lineWidth: 2)
            .frame(width: selection.width, height: selection.height)
            .position(x: selection.midX, y: selection.midY)
            .allowsHitTesting(false)
        ForEach(0..<4, id: \.self) { index in
            let x = index.isMultiple(of: 2) ? selection.minX : selection.maxX
            let y = index < 2 ? selection.minY : selection.maxY
            Rectangle().fill(.white)
                .frame(width: 13, height: 13)
                .position(x: x, y: y)
                .allowsHitTesting(false)
        }
    }

    private func editorDrag(canvas: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let image else { return }
                let frame = imageFrame(canvas: canvas, image: image)
                if dragStartCrop == nil {
                    dragStartCrop = crop
                    let box = cropFrame(in: frame)
                    let point = value.startLocation
                    let threshold: CGFloat = 18
                    if spaceHeld { dragMode = .pan }
                    else if hypot(point.x - box.minX, point.y - box.minY) < threshold { dragMode = .topLeft }
                    else if hypot(point.x - box.maxX, point.y - box.minY) < threshold { dragMode = .topRight }
                    else if hypot(point.x - box.minX, point.y - box.maxY) < threshold { dragMode = .bottomLeft }
                    else if hypot(point.x - box.maxX, point.y - box.maxY) < threshold { dragMode = .bottomRight }
                    else if box.contains(point) { dragMode = .move }
                    else { dragMode = .pan }
                }
                guard let start = dragStartCrop else { return }
                if dragMode == .pan {
                    pan = CropViewport.clampedPan(
                        CGSize(width: steadyPan.width + value.translation.width,
                               height: steadyPan.height + value.translation.height),
                        canvas: canvas, image: image.size, zoom: zoom)
                    return
                }
                let dx = Double(value.translation.width / max(1, frame.width))
                let dy = Double(value.translation.height / max(1, frame.height))
                if dragMode != .move {
                    let right = dragMode == .topRight || dragMode == .bottomRight
                    let bottom = dragMode == .bottomLeft || dragMode == .bottomRight
                    let ratio = fullWidth > 0 && fullHeight > 0
                        ? aspect.imageRatio(width: fullWidth, height: fullHeight)
                            .map { $0 * Double(fullHeight) / Double(fullWidth) }
                        : nil
                    crop = CropGeometry.resized(start, dx: dx, dy: dy,
                                                right: right, bottom: bottom,
                                                normalizedRatio: ratio)
                    return
                }
                var left = start.x, right = start.x + start.width
                var top = start.y, bottom = start.y + start.height
                switch dragMode {
                case .move:
                    left = min(max(0, start.x + dx), 1 - start.width)
                    top = min(max(0, start.y + dy), 1 - start.height)
                    right = left + start.width; bottom = top + start.height
                case .topLeft, .topRight, .bottomLeft, .bottomRight, .pan: break
                }
                crop = CropRect(x: left, y: top, width: right - left, height: bottom - top)
            }
            .onEnded { _ in dragStartCrop = nil; steadyPan = pan }
    }
}
