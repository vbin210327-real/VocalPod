import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

struct LibraryView: View {
    let library: LibraryStore
    let player: AudioPlayer
    @State private var photosPresented = false
    @State private var filesPresented = false
    @State private var selectedVideo: PhotosPickerItem?
    @State private var playerPresented = false
    @State private var errorMessage: String?
    @State private var renameClip: AudioClip?
    @State private var renamePresented = false
    @State private var newName = ""
    @State private var deleteClip: AudioClip?
    @State private var deletePresented = false
    @State private var query = ""
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draggedClipID: UUID?
    @State private var rowTapAllowedAfter = ContinuousClock.now
    @State private var dragLocation = CGPoint.zero
    @State private var dragGrabOffset: CGFloat = 0
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var listSize = CGSize.zero
    @GestureState private var reorderGestureActive = false
    @State private var importing = false
    @State private var importStatus = "正在读取视频…"
    @State private var importTask: Task<Void, Never>?
    @State private var analyzingClipID: UUID?
    @State private var analysisTask: Task<Void, Never>?

    private struct NumberedClip: Identifiable {
        let clip: AudioClip
        let number: Int
        var id: UUID { clip.id }
    }

    // Position is row data, so moving a stable clip ID also refreshes its number.
    private var numberedClips: [NumberedClip] {
        library.clips.enumerated().compactMap { index, clip in
            guard query.isEmpty || clip.title.localizedCaseInsensitiveContains(query) else { return nil }
            return NumberedClip(clip: clip, number: index + 1)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        collectionHeader
                        if library.clips.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(numberedClips) { row in
                                    clipRow(row.clip, number: row.number)
                                        .id(row.id)
                                        .opacity(draggedClipID == row.id ? 0 : 1)
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(key: LibraryRowFrames.self, value: [row.id: geometry.frame(in: .named("library.reorder"))])
                                            }
                                        }
                                        .simultaneousGesture(reorderGesture(for: row.id), including: importing || !query.isEmpty ? .subviews : .all)
                                }
                            }
                            if numberedClips.isEmpty {
                                Text("没有找到这段声音")
                                    .font(.system(size: 15)).foregroundStyle(PodStyle.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
                .scrollDisabled(draggedClipID != nil)
                .coordinateSpace(name: "library.reorder")
                .onGeometryChange(for: CGSize.self) { $0.size } action: { listSize = $0 }
                .onPreferenceChange(LibraryRowFrames.self) { frames in
                    rowFrames = frames
                    if draggedClipID != nil { moveDraggedClip(at: dragLocation.y) }
                }
                .overlay(alignment: .topLeading) {
                    if let draggedClipID, let row = numberedClips.first(where: { $0.id == draggedClipID }) {
                        clipDragPreview(row.clip, number: row.number)
                            .offset(x: 12, y: dragLocation.y - dragGrabOffset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onChange(of: reorderGestureActive) { _, active in
                    if !active { finishDragging() }
                }
                .task(id: autoScrollDirection) {
                    let direction = autoScrollDirection
                    guard direction != 0 else { return }
                    while !Task.isCancelled, draggedClipID != nil {
                        let visible = library.clips.indices.filter { index in
                            guard let frame = rowFrames[library.clips[index].id] else { return false }
                            return frame.maxY > 0 && frame.minY < listSize.height
                        }
                        if let edge = direction < 0 ? visible.first : visible.last {
                            let next = min(library.clips.count - 1, max(0, edge + direction))
                            if next != edge {
                                scrollProxy.scrollTo(library.clips[next].id, anchor: direction < 0 ? .top : .bottom)
                            }
                        }
                        do { try await Task.sleep(for: .milliseconds(160)) }
                        catch { return }
                    }
                }
            }
            .background { SilverBackground() }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if importing || player.currentClip != nil {
                    VStack(spacing: 12) {
                        if importing { importProgress }
                        if player.currentClip != nil { miniPlayer }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                    .background {
                        LinearGradient(colors: [PodStyle.background.opacity(0), PodStyle.background, Color(white: 0.84)], startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea(edges: .bottom)
                    }
                }
            }
        }
        .foregroundStyle(PodStyle.accent)
        .photosPicker(isPresented: $photosPresented, selection: $selectedVideo, matching: .videos, preferredItemEncoding: .current)
        .fileImporter(isPresented: $filesPresented, allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
            switch result {
            case .success(let url):
                beginImport {
                    let access = url.startAccessingSecurityScopedResource()
                    defer {
                        if access { url.stopAccessingSecurityScopedResource() }
                        removeOwnedInboxCopy(url)
                    }
                    await extract(from: url, title: url.deletingPathExtension().lastPathComponent)
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onChange(of: selectedVideo) { _, item in
            guard let item else { return }
            beginImport {
                do {
                    guard let movie = try await item.loadTransferable(type: ImportedMovie.self) else {
                        throw ImportUIError.unavailable
                    }
                    defer { try? FileManager.default.removeItem(at: movie.url) }
                    try Task.checkCancellation()
                    await extract(from: movie.url, title: "录屏 \(Date.now.formatted(.dateTime.month().day().hour().minute()))")
                } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
                selectedVideo = nil
            }
        }
        .onOpenURL { url in
            guard !importing else {
                errorMessage = "正在提取上一段录屏，请完成后再导入。"
                removeOwnedInboxCopy(url)
                return
            }
            beginImport {
                let access = url.startAccessingSecurityScopedResource()
                defer {
                    if access { url.stopAccessingSecurityScopedResource() }
                    removeOwnedInboxCopy(url)
                }
                await extract(from: url, title: url.deletingPathExtension().lastPathComponent)
            }
        }
        .task {
            do { try library.enableAutomaticTrimming() }
            catch { errorMessage = error.localizedDescription }
            player.connectLibrary(library)
            if let issue = library.loadError { errorMessage = "声音库暂时无法读取，已有文件会保留。\(issue)" }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VocalPod-Imports", isDirectory: true)
            // These are only picker copies left by a previously interrupted import.
            if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                for file in files { try? FileManager.default.removeItem(at: file) }
            }
        }
        .onChange(of: library.clips) { _, _ in
            player.refreshLibrary()
        }
        .fullScreenCover(isPresented: $playerPresented) {
            PlayerView(player: player, library: library)
        }
        .alert("暂时无法完成", isPresented: Binding(get: { !playerPresented && (errorMessage != nil || player.errorMessage != nil) }, set: { if !$0 { errorMessage = nil; player.errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil; player.errorMessage = nil }
        } message: { Text(errorMessage ?? player.errorMessage ?? "请重试。") }
        .alert("重命名", isPresented: $renamePresented, presenting: renameClip) { clip in
            TextField("声音名称", text: $newName).accessibilityIdentifier("rename.field")
            Button("取消", role: .cancel) { renameClip = nil }
            Button("保存") {
                do { try library.rename(clip, to: newName) } catch { errorMessage = error.localizedDescription }
                renameClip = nil
            }
        }
        .confirmationDialog("删除这段声音？", isPresented: $deletePresented, titleVisibility: .visible, presenting: deleteClip) { clip in
            Button("删除声音", role: .destructive) {
                do {
                    try library.delete(clip)
                    if player.currentClip?.id == clip.id { player.stop() }
                } catch { errorMessage = error.localizedDescription }
                deleteClip = nil
            }
        } message: { _ in Text("这会删除 App 内保存的音频，原视频不受影响。") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PodMark(size: 37)
            Text("VocalPod")
                .font(.system(size: 24, weight: .semibold)).tracking(-0.8)
            Spacer()
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    searchPresented.toggle()
                    if !searchPresented { query = "" }
                }
                searchFocused = searchPresented
            } label: {
                Image(systemName: searchPresented ? "xmark" : "magnifyingglass")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PodPressStyle())
            .accessibilityLabel(searchPresented ? "关闭搜索" : "搜索声音")
            .accessibilityIdentifier("library.search.toggle")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                MetalDisc()
                PodMark(size: 42, color: PodStyle.secondary)
            }
            .frame(width: 140, height: 140)
            Text("暂无声音")
                .font(.system(size: 15))
                .foregroundStyle(PodStyle.secondary)
                .accessibilityIdentifier("library.empty")
        }
        .frame(maxWidth: .infinity).padding(.top, 70)
    }

    private var collectionHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Text("声音库")
                    .font(.system(size: 32, weight: .semibold)).tracking(-1)
                Spacer(minLength: 16)
                importButton
            }
            if searchPresented {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(PodStyle.secondary)
                    TextField("搜索声音", text: $query)
                        .font(.system(size: 16)).focused($searchFocused)
                        .submitLabel(.search).autocorrectionDisabled()
                        .accessibilityIdentifier("library.search")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").frame(width: 32, height: 44)
                        }
                        .buttonStyle(.plain).accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 14).frame(minHeight: 48)
                .background { SilverSurface(radius: 14) }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func moveClips(_ source: IndexSet, to destination: Int) {
        guard !importing, query.isEmpty else { return }
        do {
            try library.move(fromOffsets: source, toOffset: destination)
        } catch { errorMessage = error.localizedDescription }
    }


    private func finishDragging() {
        // Button release may arrive just after the long-press recognizer ends.
        // Suppress that same release without delaying ordinary taps.
        rowTapAllowedAfter = ContinuousClock.now.advanced(by: .milliseconds(150))
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draggedClipID = nil
        }
    }

    private var autoScrollDirection: Int {
        guard draggedClipID != nil else { return 0 }
        if dragLocation.y < 50 { return -1 }
        if dragLocation.y > listSize.height - 50 { return 1 }
        return 0
    }

    private func reorderGesture(for clipID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("library.reorder")))
            .updating($reorderGestureActive) { value, active, _ in
                if case .second(true, _) = value { active = true }
            }
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                if draggedClipID == nil {
                    draggedClipID = clipID
                    dragGrabOffset = drag.startLocation.y - (rowFrames[clipID]?.minY ?? drag.startLocation.y)
                }
                dragLocation = drag.location
                moveDraggedClip(at: drag.location.y)
            }
            .onEnded { _ in finishDragging() }
    }

    private func moveDraggedClip(at y: CGFloat) {
        guard let draggedClipID,
              let source = library.clips.firstIndex(where: { $0.id == draggedClipID }) else { return }
        let visible = library.clips.compactMap { clip -> (UUID, CGRect)? in
            guard let frame = rowFrames[clip.id] else { return nil }
            return (clip.id, frame)
        }.sorted { $0.1.minY < $1.1.minY }
        guard let targetID = visible.first(where: { y < $0.1.maxY })?.0 ?? visible.last?.0,
              targetID != draggedClipID,
              let target = library.clips.firstIndex(where: { $0.id == targetID }) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            moveClips(IndexSet(integer: source), to: target > source ? target + 1 : target)
        }
    }

    private func clipLabel(_ clip: AudioClip, number: Int, selected: Bool) -> some View {
        HStack(spacing: 14) {
            Text(String(format: "%02d", number))
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .monospacedDigit().frame(minWidth: 23, alignment: .leading)
            Text(clip.title)
                .font(.system(size: 19, weight: selected ? .semibold : .medium))
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(PodStyle.time(clip.playbackDuration))
                .font(.system(size: 14)).monospacedDigit()
                .foregroundStyle(PodStyle.secondary)
                .fixedSize()
        }
        .padding(.leading, 26).padding(.trailing, 2)
        .padding(.vertical, 22)
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }

    private func clipDragPreview(_ clip: AudioClip, number: Int) -> some View {
        HStack(spacing: 0) {
            clipLabel(clip, number: number, selected: false)
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .medium))
                .frame(width: 40, height: 56)
        }
        .padding(.trailing, 15)
        .padding(.vertical, 3)
        .frame(width: max(1, listSize.width - 24))
        .foregroundStyle(PodStyle.accent)
        // A normal row for every clip: no selected silver panel, scale or glow.
        .background(PodStyle.background)
        .transaction { $0.disablesAnimations = true }
    }

    private func clipRow(_ clip: AudioClip, number: Int) -> some View {
        let selected = player.currentClip?.id == clip.id && draggedClipID == nil
        return HStack(spacing: 0) {
            Button { openClip(clip) } label: {
                clipLabel(clip, number: number, selected: selected)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("clip.\(clip.id)")
            .accessibilityValue(String(number))
            .accessibilityHint(query.isEmpty ? "长按拖动可调整顺序" : "")
            .accessibilityActions {
                if query.isEmpty && !importing {
                    if number > 1 {
                        Button("上移") { moveClips(IndexSet(integer: number - 1), to: number - 2) }
                    }
                    if number < library.clips.count {
                        Button("下移") { moveClips(IndexSet(integer: number - 1), to: number + 1) }
                    }
                }
            }
            if analyzingClipID == clip.id {
                ProgressView().tint(PodStyle.accent).frame(width: 40)
                    .accessibilityLabel("正在读取声音")
            } else {
                Menu {
                    Button("重命名", systemImage: "pencil") { newName = clip.title; renameClip = clip; renamePresented = true }
                    ShareLink(item: library.fileURL(for: clip)) { Label("导出原音频", systemImage: "square.and.arrow.up") }
                    Button("删除", systemImage: "trash", role: .destructive) { deleteClip = clip; deletePresented = true }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 40, height: 56).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(clip.title)的更多操作")
                .accessibilityIdentifier("clip.menu")
            }
        }
        .padding(.trailing, 15)
        .background {
            if selected { SilverSurface(radius: 13, selected: true) }
        }
        .overlay(alignment: .bottom) {
            if !selected {
                Rectangle().fill(PodStyle.hairline).frame(height: 0.5)
                    .padding(.horizontal, 26).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, -12)
    }

    private var importButton: some View {
        Menu {
            Button("从相册中选择视频", systemImage: "photo.on.rectangle") { photosPresented = true }
                .accessibilityIdentifier("import.photos")
            Button("从文件选择视频", systemImage: "folder") { filesPresented = true }
                .accessibilityIdentifier("import.files")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 17, weight: .regular))
                Text("导入").font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(width: 88, height: 38)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.19), Color(white: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(importing).opacity(importing ? 0.45 : 1)
        .accessibilityIdentifier("import.button")
        .accessibilityLabel("导入视频")
    }

    private var importProgress: some View {
        HStack(spacing: 12) {
            ProgressView().tint(PodStyle.accent)
            Text(importStatus).font(.system(size: 13, weight: .medium))
            Spacer()
            Button("取消") { importTask?.cancel() }
                .font(.system(size: 13)).frame(minHeight: 44)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
        .background { SilverSurface(radius: 15) }
        .accessibilityIdentifier("import.progress")
    }

    private var miniPlayer: some View {
        HStack(spacing: 12) {
            Button { playerPresented = true } label: {
                HStack(spacing: 12) {
                    PodIcon(size: 56)
                    VStack(alignment: .leading, spacing: 11) {
                        Text(library.clips.first(where: { $0.id == player.currentClip?.id })?.title ?? player.currentClip?.title ?? "")
                            .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        GeometryReader { geometry in
                            Capsule().fill(.black.opacity(0.12))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(PodStyle.accent)
                                        .frame(width: geometry.size.width * min(1, max(0, player.currentTime / max(0.1, player.duration))))
                                }
                        }
                        .frame(height: 2).accessibilityHidden(true)
                    }
                    .padding(.vertical, 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PodPressStyle()).accessibilityIdentifier("player.expand")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .medium))
                    .offset(x: player.isPlaying ? 0 : 1)
                    .frame(width: 52, height: 52)
                    .background {
                        Circle().fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay { Circle().strokeBorder(.black.opacity(0.23), lineWidth: 0.8) }
                            .overlay { Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1).padding(1.5) }
                    }
            }
            .buttonStyle(PodPressStyle())
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            .accessibilityIdentifier("mini.play")
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background { SilverSurface(radius: 14) }
    }

    private func beginImport(_ operation: @escaping @MainActor () async -> Void) {
        guard !importing else { return }
        analysisTask?.cancel()
        analyzingClipID = nil
        importing = true
        importStatus = "正在读取视频…"
        importTask = Task { @MainActor in
            let backgroundID = UIApplication.shared.beginBackgroundTask(withName: "提取录屏音频") { importTask?.cancel() }
            defer {
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VocalPod-Imports", isDirectory: true)
                try? FileManager.default.removeItem(at: directory)
                importing = false
                importTask = nil
            }
            await operation()
        }
    }

    private func openClip(_ clip: AudioClip) {
        guard !importing, !reorderGestureActive, draggedClipID == nil, ContinuousClock.now >= rowTapAllowedAfter else { return }
        analysisTask?.cancel()
        analyzingClipID = clip.id
        analysisTask = Task { @MainActor in
            defer { if analyzingClipID == clip.id { analyzingClipID = nil } }
            do {
                let analyzed = try await library.analyzeSilence(for: clip)
                try Task.checkCancellation()
                player.play(analyzed, url: library.fileURL(for: analyzed))
                playerPresented = true
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }

    private func removeOwnedInboxCopy(_ url: URL) {
        let inbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true).standardizedFileURL
        if url.standardizedFileURL.path.hasPrefix(inbox.path + "/") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func extract(from url: URL, title: String) async {
        do {
            try Task.checkCancellation()
            importStatus = "正在提取声音…"
            let clip = try await library.importVideo(at: url, suggestedName: title)
            try Task.checkCancellation()
            player.play(clip, url: library.fileURL(for: clip))
            playerPresented = true
        } catch is CancellationError {} catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }
}

private struct ImportedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VocalPod-Imports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            do {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: received.file, to: destination)
                try Task.checkCancellation()
                return ImportedMovie(url: destination)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }
}

private enum ImportUIError: LocalizedError {
    case unavailable
    var errorDescription: String? { "无法读取这段视频。若视频在 iCloud 中，请连接网络下载后再试。" }
}

private struct LibraryRowFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
