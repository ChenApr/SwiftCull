import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var showInspector = false
    @State private var availableWidth: CGFloat = 1200

    private let sidebarBreakpoint: CGFloat = 1120
    private let inspectorBreakpoint: CGFloat = 800

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                FilterSidebar()
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
            } detail: {
                mainContent
                    .inspector(isPresented: $showInspector) {
                        inspectorPanel
                            .inspectorColumnWidth(min: 320, ideal: 360, max: 460)
                    }
                    .toolbar { toolbarContent }
            }
            .navigationSplitViewStyle(.balanced)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { adapt(to: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in adapt(to: width) }
        }
        .alert("确认删除", isPresented: $store.showingDeleteConfirmation) {
            Button("取消", role: .cancel) {
                store.photosToDelete = []
            }
            Button("移至废纸篓", role: .destructive) {
                store.confirmDelete()
            }
        } message: {
            if store.photosToDelete.count == 1 {
                let hasVersions = store.photosToDelete.first.map { store.versionCount(for: $0) > 1 } ?? false
                Text(hasVersions
                     ? "将此照片的所有格式文件移至废纸篓，并移除它的裁剪版本？原文件可通过废纸篓恢复。"
                     : "将此照片（所有格式文件）移至废纸篓？此操作可通过废纸篓恢复。")
            } else {
                Text("将 \(store.photosToDelete.count) 张照片（所有格式文件）移至废纸篓？此操作可通过废纸篓恢复。")
            }
        }
        .alert("导出结果", isPresented: Binding(
            get: { store.exportMessage != nil },
            set: { if !$0 { store.exportMessage = nil } }
        )) {
            Button("好的") { store.exportMessage = nil }
        } message: {
            Text(store.exportMessage ?? "")
        }
        .sheet(isPresented: $store.showingShortcutGuide) {
            ShortcutGuideView()
        }
        .sheet(item: $store.cropEditorPhoto) { photo in
            PhotoCropEditorView(photo: photo).environmentObject(store)
        }
        .task {
            store.detectVolumes()
            await store.loadPhotos()
        }
        .onChange(of: store.selectedPhoto?.id) { _, newId in
            if newId == nil {
                showInspector = false
            } else if !store.isSelectMode, availableWidth >= inspectorBreakpoint {
                showInspector = true
            }
        }
        .onChange(of: store.isSidebarVisible) { _, isVisible in
            sidebarVisibility = isVisible ? .all : .detailOnly
        }
        .onChange(of: sidebarVisibility) { _, visibility in
            if visibility == .all, availableWidth < sidebarBreakpoint {
                showInspector = false
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                store.selectPath()
            } label: {
                Label("打开文件夹", systemImage: "folder.badge.plus")
            }
            .tint(.accentColor)

            Button {
                Task { await store.loadPhotos() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }

            if store.viewMode == .single {
                Button {
                    store.viewMode = .grid
                } label: {
                    Label("返回网格", systemImage: "square.grid.2x2")
                }
            }

            Button {
                if !showInspector, availableWidth < sidebarBreakpoint {
                    sidebarVisibility = .detailOnly
                }
                showInspector.toggle()
            } label: {
                Label(showInspector ? "隐藏详情" : "显示详情", systemImage: "sidebar.right")
            }
            .disabled(store.selectedPhoto == nil)

            ToolbarInfoView()
        }
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if store.selectedPhoto != nil {
            PhotoDetailView(showsPreview: store.viewMode == .grid)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        Label("当前照片详情", systemImage: "info.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showInspector = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("隐藏详情")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 36))
                    .foregroundStyle(.tertiary)
                Text("选择一张照片查看详情")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func adapt(to width: CGFloat) {
        availableWidth = width
        // Keep the grid usable as the window narrows: hide filters before the inspector.
        let targetSidebar: NavigationSplitViewVisibility = width >= sidebarBreakpoint ? .all : .detailOnly
        if sidebarVisibility != targetSidebar {
            sidebarVisibility = targetSidebar
        }
        if width < inspectorBreakpoint, showInspector {
            showInspector = false
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if store.isLoading {
            VStack(spacing: 16) {
                ProgressView(value: store.loadingProgress)
                    .frame(width: 220)
                Text(store.loadingStatus.isEmpty ? "正在加载照片..." : store.loadingStatus)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.sourcePath.isEmpty || store.errorMessage != nil {
            WelcomeView()
        } else if store.photos.isEmpty {
            WelcomeView()
        } else if store.viewMode == .single, let photo = store.selectedPhoto {
            PhotoSinglePreviewView(photo: photo)
        } else {
            PhotoGridView()
        }
    }
}
