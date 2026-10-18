import SwiftUI

enum PhotoGroupingMode: String, CaseIterable, Identifiable {
    case all
    case month
    case day

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "所有"
        case .month: return "月"
        case .day: return "日"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "photo.stack"
        case .month: return "calendar"
        case .day: return "calendar.day.timeline.left"
        }
    }
}

enum PhotoSelectionScope {
    case all
    case month
    case day
}

struct PhotoGridView: View {
    @EnvironmentObject var store: PhotoStore
    @AppStorage("photoGridSize") private var gridSize: Double = 110
    @AppStorage("photoGroupingMode") private var groupingMode: PhotoGroupingMode = .all
    @State private var lastSelectedPhoto: PhotoEntry?
    @State private var baseGridSize: Double?
    @State private var selectedWatermarkSelection: WatermarkPhotoSelection?
    private let minGridSize: Double = 80
    private let maxGridSize: Double = 220

    private var isSelectMode: Bool { store.isSelectMode }
    private var watermarkableSelectedPhotos: [PhotoEntry] {
        store.selectedPhotoEntries.filter { $0.hasJpg || $0.hasNef }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(gridSize), maximum: CGFloat(gridSize) + 50), spacing: 4)]
    }

    /// 触控板捏合缩放照片网格：以手势开始时的尺寸为基准按比例缩放，实时更新缩略图大小。
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = baseGridSize ?? gridSize
                if baseGridSize == nil { baseGridSize = base }
                gridSize = min(max(base * Double(value.magnification), minGridSize), maxGridSize)
            }
            .onEnded { _ in
                baseGridSize = nil
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            gridToolbar
                .padding(.horizontal, 22)
                .padding(.vertical, 7)
                .background(.bar)

            Divider()

            if store.isSelectMode {
                selectionCommandPanel
                    .animation(.snappy(duration: 0.2), value: store.selectedCount)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(.bar)
                    .transition(.move(edge: .top).combined(with: .opacity))

                Divider()
            }

            ShortcutHintBar()

            if store.isEnriching {
                EnrichProgressBar()
            }

            Divider()

            photoContent
                .simultaneousGesture(magnifyGesture)
        }
        .animation(.snappy(duration: 0.24), value: store.isSelectMode)
        .animation(.snappy(duration: 0.24), value: store.isEnriching)
        .sheet(item: $selectedWatermarkSelection) { selection in
            WatermarkExportView(store: store, photos: selection.photos)
        }
    }

    @ViewBuilder
    private var photoContent: some View {
        if store.filteredPhotos.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("没有匹配的照片")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PhotoGridContent(
                store: store,
                gridSize: CGFloat(gridSize),
                columns: columns,
                groupingMode: groupingMode,
                isSelectMode: store.isSelectMode,
                lastSelectedPhoto: $lastSelectedPhoto
            )
        }
    }

    private var gridToolbar: some View {
        GeometryReader { geometry in
            toolbarLayout(for: geometry.size.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 26)
    }

    @ViewBuilder
    private func toolbarLayout(for width: CGFloat) -> some View {
        if width >= 650 {
            HStack(spacing: 12) {
                normalToolbar
                Spacer(minLength: 24)
                gridSizeControl(width: 150)
            }
        } else if width >= 500 {
            HStack(spacing: 8) {
                Text("\(store.photoCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                selectionMenu
                groupingPicker(width: 120)
                    .labelsHidden()
                Spacer(minLength: 4)
                gridSizeControl(width: 80)
            }
        } else if width >= 420 {
            HStack(spacing: 8) {
                Text("\(store.photoCount) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
                selectionMenu
                compactGroupingMenu
                Spacer(minLength: 0)
                gridSizeControl(width: 64)
            }
        } else {
            HStack(spacing: 8) {
                selectionMenu
                compactGroupingMenu
                Spacer(minLength: 0)
            }
        }
    }

    private var normalToolbar: some View {
        HStack(spacing: 8) {
            Text("\(store.photoCount) 张照片 · \(store.totalSize)")
                .font(.caption)
                .foregroundStyle(.secondary)

            selectionMenu
            groupingPicker(width: 148)
                .labelsHidden()
        }
    }

    private var selectionMenu: some View {
        Menu {
            Button {
                beginSelectMode()
            } label: {
                Label("进入选择模式", systemImage: "checkmark.circle")
            }

            Divider()

            Button {
                selectPhotos(.all)
            } label: {
                Label("选择所有照片", systemImage: "photo.stack")
            }

            Button {
                selectPhotos(.month)
            } label: {
                Label("选择当前月份", systemImage: "calendar")
            }
            .disabled(selectionReferencePhoto == nil)

            Button {
                selectPhotos(.day)
            } label: {
                Label("选择当前日期", systemImage: "calendar.day.timeline.left")
            }
            .disabled(selectionReferencePhoto == nil)
        } label: {
            Label("选择", systemImage: "checkmark.circle")
                .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func groupingPicker(width: CGFloat) -> some View {
        Picker("分组", selection: $groupingMode) {
            ForEach(PhotoGroupingMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: width)
        .help("按拍摄时间分组")
    }

    private var compactGroupingMenu: some View {
        Menu {
            Picker("分组", selection: $groupingMode) {
                ForEach(PhotoGroupingMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
        } label: {
            Label(groupingMode.title, systemImage: groupingMode.systemImage)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .help("按拍摄时间分组")
    }

    private func gridSizeControl(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Slider(value: $gridSize, in: minGridSize...maxGridSize)
                .frame(width: width)
                .help("缩略图 \(Int(gridSize))px")
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
    }

    private var selectionCommandPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                regularSelectionPanel
                denseSelectionPanel
                compactSelectionPanel
            }
            selectionExportActions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 1280, minHeight: 42, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.34))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.7)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var selectionExportActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Text("仅对已选 \(store.selectedCount) 张")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    store.exportSelectedPhotos()
                } label: {
                    Label("导出所选照片…", systemImage: "square.and.arrow.up")
                }
                .disabled(store.selectedCount == 0 || store.isExporting)
                Button {
                    selectedWatermarkSelection = WatermarkPhotoSelection(photos: watermarkableSelectedPhotos)
                } label: {
                    Label("所选 \(watermarkableSelectedPhotos.count) 张添加边框 / 水印…", systemImage: "photo.badge.plus")
                }
                .disabled(store.isExporting || watermarkableSelectedPhotos.isEmpty)
            }

            HStack {
                Text("仅对已选 \(store.selectedCount) 张")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("导出所选照片…") { store.exportSelectedPhotos() }
                        .disabled(store.selectedCount == 0 || store.isExporting)
                    Button("所选 \(watermarkableSelectedPhotos.count) 张添加边框 / 水印…") {
                        selectedWatermarkSelection = WatermarkPhotoSelection(photos: watermarkableSelectedPhotos)
                    }
                    .disabled(store.isExporting || watermarkableSelectedPhotos.isEmpty)
                } label: {
                    Label("导出所选…", systemImage: "square.and.arrow.up")
                }
            }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var regularSelectionPanel: some View {
        HStack(spacing: 10) {
            selectionCommitSection
            PanelDivider(height: 24)
            ratingSection
            PanelDivider(height: 24)
            tagSection
            PanelDivider(height: 24)
            clearSection
            Spacer(minLength: 8)
            deleteSection
        }
    }

    private var denseSelectionPanel: some View {
        HStack(spacing: 8) {
            compactSelectionCommitSection
            PanelDivider(height: 22)
            denseRatingSection
            PanelDivider(height: 22)
            denseTagSection
            PanelDivider(height: 22)
            denseClearSection
            Spacer(minLength: 6)
            deleteSection
        }
    }

    private var compactSelectionPanel: some View {
        HStack(spacing: 7) {
            compactSelectionCommitSection
            Menu {
                Button("清除评分") { store.batchClearRating() }
                ForEach(1...5, id: \.self) { rating in
                    Button("\(rating) 星") { store.batchSetRating(rating) }
                }
            } label: {
                Label("评分", systemImage: "star")
            }
            .disabled(store.selectedCount == 0)
            Menu {
                ForEach(store.availableTags) { tag in
                    Button(tag.displayName) { store.batchAddTag(tag.name) }
                }
                Divider()
                Button("清除标签") { store.batchClearTags() }
            } label: {
                Label("标签", systemImage: "tag")
            }
            .disabled(store.selectedCount == 0)
            Spacer(minLength: 0)
            deleteSection
        }
        .font(.caption)
        .menuStyle(.button)
        .controlSize(.small)
    }

    private var selectionCommitSection: some View {
        HStack(spacing: 7) {
            HStack(spacing: 5) {
                Image(systemName: store.selectedCount > 0 ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(store.selectedCount > 0 ? Color.accentColor : Color.secondary)
                Text(store.selectedCount > 0 ? "\(store.selectedCount) 张" : "未选")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            .frame(width: 64, alignment: .leading)

            Button {
                finishSelectMode()
            } label: {
                Label("完成", systemImage: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 28)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(SelectionPrimaryButtonStyle())
            .disabled(!isSelectMode)

            Button {
                cancelSelectMode()
            } label: {
                Label("取消", systemImage: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(height: 28)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(SelectionSecondaryButtonStyle())
            .disabled(!isSelectMode)
        }
    }

    private var compactSelectionCommitSection: some View {
        HStack(spacing: 6) {
            Text(store.selectedCount > 0 ? "\(store.selectedCount) 张" : "未选")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .frame(width: 48, alignment: .leading)

            Button {
                finishSelectMode()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(SelectionIconButtonStyle(width: 28, height: 28))
            .disabled(!isSelectMode)
            .help("完成")

            Button {
                cancelSelectMode()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(SelectionIconButtonStyle(width: 28, height: 28))
            .disabled(!isSelectMode)
            .help("取消")
        }
    }

    private var ratingSection: some View {
        HStack(spacing: 6) {
            BatchSectionLabel(title: "评分", systemImage: "star")

            ForEach(1...5, id: \.self) { rating in
                Button(action: { store.batchSetRating(rating) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.3 + Double(rating) * 0.14))
                        Text("\(rating)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .buttonStyle(SelectionIconButtonStyle(width: 40, height: 30))
                .disabled(store.selectedCount == 0)
                .help("\(rating)星")
            }
        }
    }

    private var denseRatingSection: some View {
        HStack(spacing: 4) {
            Image(systemName: "star")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            ForEach(1...5, id: \.self) { rating in
                Button(action: { store.batchSetRating(rating) }) {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange.opacity(0.3 + Double(rating) * 0.14))
                        Text("\(rating)")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(SelectionIconButtonStyle(width: 34, height: 28))
                .disabled(store.selectedCount == 0)
                .help("\(rating)星")
            }
        }
    }

    private var tagSection: some View {
        HStack(spacing: 6) {
            BatchSectionLabel(title: "标签", systemImage: "tag")

            ForEach(store.availableTags) { tag in
                Button(action: { store.batchAddTag(tag.name) }) {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                }
                .buttonStyle(SelectionIconButtonStyle(width: 28, height: 28, cornerRadius: 7))
                .disabled(store.selectedCount == 0)
                .help(tag.displayName)
            }
        }
    }

    private var denseTagSection: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            ForEach(store.availableTags) { tag in
                Button(action: { store.batchAddTag(tag.name) }) {
                    Circle()
                        .fill(tag.color)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 1))
                }
                .buttonStyle(SelectionIconButtonStyle(width: 24, height: 28, cornerRadius: 7))
                .disabled(store.selectedCount == 0)
                .help(tag.displayName)
            }
        }
    }

    private var clearSection: some View {
        HStack(spacing: 6) {
            BatchSectionLabel(title: "清除", systemImage: "eraser")

            Button(action: { store.batchClearRating() }) {
                Image(systemName: "star.slash")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(SelectionIconButtonStyle(width: 34, height: 30))
            .disabled(store.selectedCount == 0)
            .help("清除评分")

            Button(action: { store.batchClearTags() }) {
                Image(systemName: "tag.slash")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(SelectionIconButtonStyle(width: 34, height: 30))
            .disabled(store.selectedCount == 0)
            .help("清除标签")
        }
    }

    private var denseClearSection: some View {
        HStack(spacing: 4) {
            Button(action: { store.batchClearRating() }) {
                Image(systemName: "star.slash")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(SelectionIconButtonStyle(width: 30, height: 28))
            .disabled(store.selectedCount == 0)
            .help("清除评分")

            Button(action: { store.batchClearTags() }) {
                Image(systemName: "tag.slash")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(SelectionIconButtonStyle(width: 30, height: 28))
            .disabled(store.selectedCount == 0)
            .help("清除标签")
        }
    }

    private var deleteSection: some View {
        Button(role: .destructive) {
            store.requestDeleteSelected()
        } label: {
            Label("删除", systemImage: "trash")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .frame(height: 28)
        }
        .buttonStyle(SelectionDestructiveButtonStyle())
        .disabled(store.selectedCount == 0)
    }

    private var selectionReferencePhoto: PhotoEntry? {
        store.selectedPhoto ?? store.selectedPhotoEntries.first ?? store.filteredPhotos.first
    }

    private func selectPhotos(_ scope: PhotoSelectionScope) {
        beginSelectMode()

        switch scope {
        case .all:
            groupingMode = .all
            store.selectAll()
        case .month:
            groupingMode = .month
            selectPhotos(matching: .month)
        case .day:
            groupingMode = .day
            selectPhotos(matching: .day)
        }
    }

    private func selectPhotos(matching component: Calendar.Component) {
        guard let reference = selectionReferencePhoto else { return }
        let calendar = Calendar.current
        let ids = Set(store.filteredPhotos
            .filter { calendar.isDate($0.fileDate, equalTo: reference.fileDate, toGranularity: component) }
            .map(\.id))
        store.selectPhotoIds(ids)
    }

    private func beginSelectMode() {
        guard !store.isSelectMode else { return }
        store.enterSelectMode()
    }

    private func finishSelectMode() {
        store.confirmSelectMode()
        lastSelectedPhoto = nil
    }

    private func cancelSelectMode() {
        store.cancelSelectMode()
        lastSelectedPhoto = nil
    }
}

// MARK: - Grid Content & Drag Selection

struct PhotoGridSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let photoIndices: [Int]
}

/// The layout is stable while selection and marks change. Store only indices so cards
/// always read the current PhotoEntry rather than a stale cached rating or tag.
private final class PhotoGroupCache {
    private var version = -1
    private var mode: PhotoGroupingMode = .all
    private var ascending = true
    private var cached: [PhotoGridSection] = []

    func sections(photos: [PhotoEntry], version: Int, mode: PhotoGroupingMode,
                  ascending: Bool) -> [PhotoGridSection] {
        guard version != self.version || mode != self.mode || ascending != self.ascending else {
            return cached
        }
        self.version = version
        self.mode = mode
        self.ascending = ascending

        if mode == .all {
            cached = [PhotoGridSection(id: "all", title: "所有照片",
                                       subtitle: "\(photos.count) 张",
                                       photoIndices: Array(photos.indices))]
            return cached
        }

        let calendar = Calendar.current
        let granularity: Calendar.Component = mode == .month ? .month : .day
        let components: Set<Calendar.Component> = mode == .month ? [.year, .month] : [.year, .month, .day]
        let titleFormatter = DateFormatter()
        titleFormatter.locale = Locale(identifier: "zh_CN")
        titleFormatter.dateFormat = mode == .month ? "yyyy年M月" : "yyyy年M月d日"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "zh_CN")
        weekdayFormatter.dateFormat = "EEEE"

        var grouped: [Date: [Int]] = [:]
        for index in photos.indices {
            let date = photos[index].fileDate
            let key = calendar.date(from: calendar.dateComponents(components, from: date)) ?? date
            grouped[key, default: []].append(index)
        }
        cached = grouped.keys.sorted(by: ascending ? (<) : (>)).map { date in
            let indices = (grouped[date] ?? []).sorted {
                ascending ? photos[$0].fileDate < photos[$1].fileDate
                          : photos[$0].fileDate > photos[$1].fileDate
            }
            let count = indices.count
            return PhotoGridSection(
                id: "\(granularity)-\(date.timeIntervalSince1970)",
                title: titleFormatter.string(from: date),
                subtitle: mode == .day ? "\(weekdayFormatter.string(from: date)) · \(count) 张" : "\(count) 张",
                photoIndices: indices
            )
        }
        return cached
    }
}

private struct PhotoGroupHeader: View {
    let group: PhotoGridSection
    let isSelectMode: Bool
    let isSelected: Bool
    let onToggleSelection: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(group.subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if isSelectMode {
                Button(action: onToggleSelection) {
                    Label(isSelected ? "取消本组" : "选择本组", systemImage: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                }
                .buttonStyle(SelectionSecondaryButtonStyle())
                .help(isSelected ? "取消选择本组照片" : "选择本组照片")
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PhotoGridContent: View {
    @ObservedObject var store: PhotoStore
    let gridSize: CGFloat
    let columns: [GridItem]
    let groupingMode: PhotoGroupingMode
    let isSelectMode: Bool
    @Binding var lastSelectedPhoto: PhotoEntry?
    /// 非观察的帧缓存（引用型），避免滚动时用 @State 逐帧触发整个网格重算。
    @State private var frameStore = FrameStore()
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var dragBaselineSelection: Set<String> = []
    @State private var dragSelectionMode: DragSelectionMode = .replace
    @State private var cachedPhotoIds: Set<String> = []
    @State private var lastDragUpdateTime: CFAbsoluteTime = 0
    @State private var didDragSelect = false
    @State private var watermarkSelection: WatermarkPhotoSelection?
    @State private var groupCache = PhotoGroupCache()

    private let gridCoordinateSpace = "photo-grid-space"

    private func selectionOverlay(for rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.14))
            .overlay(
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 1)
            )
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    private var selectionRect: CGRect? {
        guard let dragStart, let dragCurrent else { return nil }
        return CGRect(
            x: min(dragStart.x, dragCurrent.x),
            y: min(dragStart.y, dragCurrent.y),
            width: abs(dragCurrent.x - dragStart.x),
            height: abs(dragCurrent.y - dragStart.y)
        )
    }

    private var photoGroups: [PhotoGridSection] {
        groupCache.sections(photos: store.filteredPhotos,
                            version: store.filteredPhotosVersion,
                            mode: groupingMode,
                            ascending: store.filterOptions.sortAscending)
    }

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 4) {
                        if groupingMode == .all {
                            ForEach(store.filteredPhotos) { photo in
                                photoCard(photo)
                            }
                        } else {
                            ForEach(photoGroups) { group in
                                Section {
                                    ForEach(group.photoIndices, id: \.self) { index in
                                        photoCard(store.filteredPhotos[index])
                                    }
                                } header: {
                                    PhotoGroupHeader(
                                        group: group,
                                        isSelectMode: isSelectMode,
                                        isSelected: isGroupSelected(group)
                                    ) {
                                        toggleGroupSelection(group)
                                    }
                                }
                            }
                        }
                    }
                    .subtleScrollbars()
                    .background {
                        // One measurement for the grid, including the actual space
                        // left by scrollbars. Keyboard navigation needs only this count.
                        GeometryReader { gridGeometry in
                            Color.clear.preference(
                                key: PhotoGridColumnCountPreferenceKey.self,
                                value: max(1, Int((gridGeometry.size.width + 4) / (gridSize + 4)))
                            )
                        }
                    }
                    .padding(4)
                    .frame(minHeight: geometry.size.height, alignment: .topLeading)
                    .coordinateSpace(name: gridCoordinateSpace)
                    .overlay(alignment: .topLeading) {
                        if let selectionRect {
                            selectionOverlay(for: selectionRect)
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(gridInteractionGesture)
                    .onPreferenceChange(PhotoItemFramePreferenceKey.self) { frames in
                        guard dragStart != nil else { return }
                        frameStore.frames.merge(frames, uniquingKeysWith: { _, new in new })
                        updateDragSelection()
                    }
                }
                .padding(.horizontal, 14)
                .onPreferenceChange(PhotoGridColumnCountPreferenceKey.self) { count in
                    if count > 0 { store.updateGridColumnCount(count) }
                }
                .onAppear {
                    cachedPhotoIds = Set(store.filteredPhotos.map(\.id))
                }
                .onChange(of: store.filteredPhotosVersion) { _, _ in
                    frameStore.frames.removeAll(keepingCapacity: true)
                    cachedPhotoIds = Set(store.filteredPhotos.map(\.id))
                }
            }
            .onChange(of: store.selectedPhoto?.id) { _, newId in
                guard dragStart == nil else { return }
                if let newId = newId {
                    proxy.scrollTo(newId, anchor: .center)
                }
            }
            .task(id: store.viewMode) {
                guard store.viewMode == .grid, let selectedId = store.selectedPhoto?.id else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(selectedId, anchor: .center)
            }
        }
        .sheet(item: $watermarkSelection) { selection in
            WatermarkExportView(store: store, photos: selection.photos)
        }
    }

    private func photoCard(_ photo: PhotoEntry) -> some View {
        SelectablePhotoCardView(
            photo: photo,
            gridSize: gridSize,
            isSelected: store.selectedPhotos.contains(photo.id),
            isPrimary: store.selectedPhoto?.id == photo.id,
            isSelectMode: isSelectMode
        )
        // Cards own click selection. Keeping this separate from the grid's drag gesture
        // avoids coordinate-space hit-test failures that otherwise make a click a no-op.
        .contentShape(Rectangle())
        .onTapGesture {
            resignTextInputFocus()
            handleTap(photo: photo)
        }
        .overlay(alignment: .bottomTrailing) {
            let count = store.versionCount(for: photo)
            if !photo.isVersionCopy && count > 1 {
                Button {
                    store.toggleVersions(for: photo)
                } label: {
                    Label("\(count)", systemImage: "square.stack.3d.up")
                        .font(.system(size: 9, weight: .bold))
                        .padding(4)
                        .foregroundStyle(.white)
                        .background(.black.opacity(0.65), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(store.expandedVersionSources.contains(photo.sourceID) ? "收起裁剪版本" : "展开裁剪版本")
                .padding(4)
            }
        }
        .id(photo.id)
        .contextMenu {
            PhotoContextMenu(store: store, photo: photo) { photos in
                watermarkSelection = WatermarkPhotoSelection(photos: photos)
            }
        }
        .onAppear {
            store.preloadThumbnails(around: photo, size: gridSize)
        }
        .background {
            PhotoItemFrameReader(photoID: photo.id, coordinateSpace: gridCoordinateSpace, dragStart: $dragStart)
        }
    }

    private func isGroupSelected(_ group: PhotoGridSection) -> Bool {
        let ids = Set(group.photoIndices.map { store.filteredPhotos[$0].id })
        return !ids.isEmpty && ids.isSubset(of: store.selectedPhotos)
    }

    private func toggleGroupSelection(_ group: PhotoGridSection) {
        let ids = Set(group.photoIndices.map { store.filteredPhotos[$0].id })
        guard !ids.isEmpty else { return }

        if ids.isSubset(of: store.selectedPhotos) {
            store.selectPhotoIds(store.selectedPhotos.subtracting(ids))
        } else {
            store.selectPhotoIds(store.selectedPhotos.union(ids))
        }

        activateSelectModeIfNeeded()
        if let selected = store.selectedPhoto {
            lastSelectedPhoto = selected
        }
    }

    /// 网格只负责拖拽框选。单击由卡片自身处理，避免依赖帧缓存做坐标反查。
    private var gridInteractionGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(gridCoordinateSpace))
            .onChanged { value in
                if !didDragSelect {
                    let dx = value.location.x - value.startLocation.x
                    let dy = value.location.y - value.startLocation.y
                    guard dx * dx + dy * dy >= 36 else { return }
                    resignTextInputFocus()
                    frameStore.frames.removeAll(keepingCapacity: true)
                    didDragSelect = true
                    dragStart = value.startLocation
                    dragBaselineSelection = store.selectedPhotos
                    dragSelectionMode = currentDragSelectionMode
                    lastDragUpdateTime = 0
                }
                dragCurrent = value.location
                updateDragSelection()
            }
            .onEnded { _ in
                if didDragSelect {
                    updateDragSelection(force: true)
                    if store.selectedCount > 0, !store.isSelectMode {
                        store.enterSelectMode()
                    }
                }
                dragStart = nil
                dragCurrent = nil
                didDragSelect = false
                dragBaselineSelection = []
                dragSelectionMode = .replace
                frameStore.frames.removeAll(keepingCapacity: true)
            }
    }

    @MainActor
    private func resignTextInputFocus() {
        guard KeyboardShortcutHandler.isTextFieldFocused else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var currentDragSelectionMode: DragSelectionMode {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            return .toggle
        }
        if flags.contains(.shift) {
            return .add
        }
        return .replace
    }

    private func updateDragSelection(force: Bool = false) {
        guard let selectionRect, !frameStore.frames.isEmpty else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if !force {
            guard now - lastDragUpdateTime >= 0.016 else { return }
        }
        lastDragUpdateTime = now

        let rectSelectedIds = frameStore.frames.reduce(into: Set<String>()) { result, item in
            guard cachedPhotoIds.contains(item.key) else { return }
            if item.value.intersects(selectionRect) {
                result.insert(item.key)
            }
        }

        let selectedIds: Set<String>
        switch dragSelectionMode {
        case .replace:
            selectedIds = rectSelectedIds
        case .add:
            selectedIds = dragBaselineSelection.union(rectSelectedIds)
        case .toggle:
            selectedIds = dragBaselineSelection.symmetricDifference(rectSelectedIds)
        }

        store.selectPhotoIds(selectedIds)
        if let selected = store.selectedPhoto {
            lastSelectedPhoto = selected
        }
    }

    private func handleTap(photo: PhotoEntry) {
        let isCommandPressed = NSEvent.modifierFlags.contains(.command)
        let isShiftPressed = NSEvent.modifierFlags.contains(.shift)

        if isSelectMode {
            if isShiftPressed, let last = lastSelectedPhoto {
                store.selectRange(from: last, to: photo)
            } else {
                store.toggleSelection(photo)
                lastSelectedPhoto = photo
            }
        } else {
            if isShiftPressed, let last = lastSelectedPhoto {
                store.selectRange(from: last, to: photo)
                activateSelectModeIfNeeded()
            } else if isCommandPressed {
                store.toggleSelection(photo)
                lastSelectedPhoto = photo
                activateSelectModeIfNeeded()
            } else {
                store.selectPhoto(photo)
                store.isInspectorVisible = true
                lastSelectedPhoto = photo
            }
        }
    }

    private func activateSelectModeIfNeeded() {
        guard !store.isSelectMode, store.selectedCount > 1 else { return }
        store.enterSelectMode()
    }
}

private enum DragSelectionMode {
    case replace
    case add
    case toggle
}

/// Frames are collected only during drag selection. Keeping the cache outside
/// observable state avoids invalidating the grid when those frames arrive.
private final class FrameStore {
    var frames: [String: CGRect] = [:]
}

private struct PhotoItemFrameReader: View {
    let photoID: String
    let coordinateSpace: String
    @Binding var dragStart: CGPoint?

    var body: some View {
        // The binding lets cells in retained lazy sections observe tracking
        // directly, without relying on their ForEach builder being reevaluated.
        if dragStart != nil {
            GeometryReader { geometry in
                Color.clear.preference(key: PhotoItemFramePreferenceKey.self,
                                       value: [photoID: geometry.frame(in: .named(coordinateSpace))])
            }
        }
    }
}

private struct PhotoGridColumnCountPreferenceKey: PreferenceKey {
    static let defaultValue = 0

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = max(value, nextValue())
    }
}

struct PhotoItemFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
