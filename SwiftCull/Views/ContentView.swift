import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var store: PhotoStore
    @State private var availableWidth: CGFloat = 1200

    private let sidebarBreakpoint: CGFloat = 1120
    private let inspectorBreakpoint: CGFloat = 800

    var body: some View {
        GeometryReader { geometry in
            NavigationSplitView(columnVisibility: Binding(
                get: { store.isSidebarVisible ? .all : .detailOnly },
                set: { store.isSidebarVisible = $0 != .detailOnly }
            )) {
                FilterSidebar()
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
            } detail: {
                mainContent
                    .inspector(isPresented: $store.isInspectorVisible) {
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
                     ? "将此照片的所有格式文件移至废纸篓？裁剪记录将保留，恢复原文件并刷新后可继续编辑。"
                     : "将此照片（所有格式文件）移至废纸篓？此操作可通过废纸篓恢复。")
            } else {
                Text("将 \(store.photosToDelete.count) 张照片（所有格式文件）移至废纸篓？此操作可通过废纸篓恢复。")
            }
        }
        .alert("操作结果", isPresented: Binding(
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
        .sheet(item: $store.livePhotoEditorPhoto) { photo in
            LivePhotoExportView(photo: photo, initialTime: store.livePhotoInitialTime)
        }
        .overlay(alignment: .top) {
            if let status = store.copyStatus {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .task {
            store.detectVolumes()
            await store.loadPhotos()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            store.flushPendingWrites()
        }
        .onChange(of: store.selectedPhoto?.id) { _, newId in
            if newId == nil {
                store.isInspectorVisible = false
            }
        }
        .onChange(of: store.isSidebarVisible) { _, isVisible in
            if isVisible, availableWidth < sidebarBreakpoint {
                store.isInspectorVisible = false
            }
        }
        .onChange(of: store.isInspectorVisible) { _, isVisible in
            if isVisible, availableWidth < sidebarBreakpoint {
                store.isSidebarVisible = false
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

            Button(action: store.toggleInspector) {
                Label(store.isInspectorVisible ? "隐藏详情" : "显示详情", systemImage: "sidebar.right")
            }
            .disabled(store.selectedPhoto == nil)
            .help("显示或隐藏右栏 (⌘⇧B)")

            ToolbarInfoView()
        }
    }

    @ViewBuilder
    private var inspectorPanel: some View {
        if store.selectedPhoto != nil {
            PhotoDetailView(showsPreview: store.viewMode == .grid)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack {
                        SectionHeader(icon: "info.circle", title: "当前照片详情")
                        Spacer()
                        Button {
                            store.isInspectorVisible = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("隐藏详情")
                    }
                    .padding(.horizontal, 12)
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
        let crossedSidebarBreakpoint = (width >= sidebarBreakpoint) != (availableWidth >= sidebarBreakpoint)
        availableWidth = width
        // Keep the grid usable as the window narrows: hide filters before the inspector.
        if crossedSidebarBreakpoint {
            store.isSidebarVisible = width >= sidebarBreakpoint
        }
        if width < inspectorBreakpoint, store.isInspectorVisible {
            store.isInspectorVisible = false
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

struct SidebarCommands: Commands {
    @ObservedObject var store: PhotoStore

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(store.isSidebarVisible ? "隐藏左栏" : "显示左栏") {
                store.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)

            Button(store.isInspectorVisible ? "隐藏右栏" : "显示右栏") {
                store.toggleInspector()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(store.selectedPhoto == nil)
        }
    }
}
