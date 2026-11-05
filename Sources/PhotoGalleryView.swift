import PhotosUI
import SwiftUI

struct ChildPhotoAvatar: View {
    let store: AppStore
    var body: some View {
        let gallery = store.photoGallery
        let galleryRevision = gallery.revision
        let photos = (try? gallery.photos(babyID: store.baby?.id ?? UUID())) ?? []
        let avatar = BabyPhoto.avatar(in: photos, pinnedID: store.baby?.pinnedPhotoID)
        Group {
            if let avatar, let data = gallery.data(for: avatar, thumbnail: true), let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill().accessibilityIdentifier("photo.avatar.image")
            } else {
                Image("BrandMark").resizable().scaledToFill().accessibilityIdentifier("photo.avatar.brand")
            }
        }
        .frame(width: AppDesign.Metrics.brandMarkSize, height: AppDesign.Metrics.brandMarkSize)
        .clipShape(RoundedRectangle(cornerRadius: AppDesign.Metrics.brandMarkCornerRadius))
        .id(galleryRevision)
        .accessibilityValue(avatar?.id.uuidString ?? "brand")
    }
}

/// The native source dialog belongs to the camera button, including in the home header.
struct PhotoAddButton: View {
    let store: AppStore
    @Binding var isPresenting: Bool
    var onDismiss: () -> Void = {}
    var handlesServiceErrors = false
    @State private var sourceDialog = false
    @State private var picker = false
    @State private var camera = false
    @State private var items: [PhotosPickerItem] = []
    @State private var localError: String?
    @State private var captureBabyID: UUID?
    @State private var pendingError: String?
    @State private var cameraCoverActive = false
    @State private var importBabyID: UUID?
    @State private var isImporting = false

    var body: some View {
        Button { sourceDialog = true; isPresenting = true } label: {
            Group {
                if isImporting {
                    ProgressView().accessibilityLabel("Загружаем фотографии")
                } else {
                    Image(systemName: "camera")
                }
            }
            .frame(minWidth: AppDesign.Metrics.minimumTouch, minHeight: AppDesign.Metrics.minimumTouch)
        }
        .accessibilityLabel("Добавить фотографию")
        .accessibilityIdentifier("photo.add")
        .disabled(isImporting)
        .confirmationDialog("Добавить фотографию", isPresented: $sourceDialog, titleVisibility: .visible) {
            Button("Сфотографировать") {
                captureBabyID = store.baby?.id
                cameraCoverActive = true
                camera = true
            }
            .accessibilityIdentifier("photo.source.camera")
            Button("Выбрать из Фото") { importBabyID = store.baby?.id; picker = true }
                .accessibilityIdentifier("photo.source.library")
            Button("Отмена", role: .cancel) { isPresenting = false }
        }
        .photosPicker(isPresented: $picker, selection: $items, maxSelectionCount: 30,
                      matching: .images, preferredItemEncoding: .current)
        .fullScreenCover(isPresented: $camera, onDismiss: {
            cameraCoverActive = false
            isPresenting = false
            if let pendingError {
                localError = pendingError
            }
            pendingError = nil
            onDismiss()
        }) {
            let capturedBabyID = captureBabyID
            PhotoCaptureView { data in
                camera = false
                guard let id = capturedBabyID else { return }
                Task {
                    await store.photoGallery.capture(data: data, babyID: id)
                    reportServiceError()
                }
            } onError: { message in
                camera = false
                pendingError = message
            } onCancel: { camera = false }
                .ignoresSafeArea()
        }
        .onChange(of: items) { _, selected in
            guard !selected.isEmpty, let id = importBabyID else { return }
            isImporting = true
            Task {
                defer { isImporting = false }
                var transferError: String?
                for item in selected {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            transferError = "Не удалось загрузить фотографию. Выберите её снова."
                            continue
                        }
                        await store.photoGallery.importPhoto(
                            data: data,
                            assetIdentifier: item.itemIdentifier,
                            babyID: id
                        )
                    } catch { transferError = "Не удалось загрузить фотографию. Выберите её снова." }
                }
                if let transferError {
                    localError = transferError
                }
                reportServiceError()
                items = []
                isPresenting = false
                onDismiss()
            }
        }
        .onChange(of: sourceDialog) { _, visible in
            if !visible, !picker, !camera {
                isPresenting = false; onDismiss()
            }
        }
        .onChange(of: picker) { _, visible in
            if !visible, items.isEmpty {
                isPresenting = false; onDismiss()
            }
        }
        .onChange(of: isPresenting) { _, visible in
            if !visible {
                sourceDialog = false; picker = false; camera = false
            }
        }
        .alert("Не удалось добавить фотографию", isPresented: Binding(
            get: { localError != nil }, set: {
                if !$0 {
                    localError = nil
                }
            }
        )) { Button("Понятно", role: .cancel) { localError = nil } }
        message: { Text(localError ?? "") }
    }

    private func reportServiceError() {
        guard handlesServiceErrors, let error = store.photoGallery.errorMessage else { return }
        if cameraCoverActive {
            pendingError = error
        } else {
            localError = error
        }
        store.photoGallery.errorMessage = nil
    }
}

struct PhotoGalleryView: View {
    let store: AppStore
    var isPresentedModally = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var photos: [BabyPhoto] = []
    @State private var loadError: String?
    @State private var selected: BabyPhoto?
    @State private var adding = false
    @State private var recoveryPhoto: BabyPhoto?
    @State private var recoveryItem: PhotosPickerItem?
    @State private var recoveryPicker = false

    private var dates: [Date] {
        Array(Set(photos.map { Calendar.current.startOfDay(for: $0.capturedAt) })).sorted(by: >)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
                if store.photoGallery.isBusy {
                    ProgressView("Сохраняем фотографии…").accessibilityIdentifier("photo.loading")
                }
                if let loadError {
                    ContentUnavailableView {
                        Label("Не удалось открыть фотографии", systemImage: "exclamationmark.triangle")
                    } description: { Text(loadError) } actions: {
                        Button("Попробовать снова") { reload() }.accessibilityIdentifier("photo.retry")
                    }
                } else if photos.isEmpty {
                    ContentUnavailableView("Первые фотографии малыша", systemImage: "photo.on.rectangle",
                                           description: Text("Сфотографируйте малыша или выберите снимки из Фото."))
                        .accessibilityIdentifier("photo.empty")
                } else {
                    ForEach(dates, id: \.self) { date in
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
                            Text(date, format: .dateTime.day().month(.wide).year()).font(.headline)
                                .accessibilityIdentifier("photo.date.group")
                            LazyVGrid(
                                columns: dynamicTypeSize
                                    .isAccessibilitySize ? [GridItem(.flexible())] :
                                    [GridItem(.adaptive(minimum: 100))],
                                spacing: AppDesign.Spacing.group
                            ) {
                                ForEach(photos
                                    .filter { Calendar.current.isDate($0.capturedAt, inSameDayAs: date) })
                                { photo in
                                    Button { selected = photo } label: {
                                        PhotoImage(gallery: store.photoGallery, photo: photo, thumbnail: true)
                                            .frame(height: 120).frame(maxWidth: .infinity).clipped()
                                            .overlay(alignment: .bottomTrailing) {
                                                if photo.isFavorite {
                                                    Image(systemName: "heart.fill").padding(6)
                                                        .background(.regularMaterial, in: Circle()).padding(4)
                                                }
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        "Фотография, \(photo.capturedAt.formatted(date: .long, time: .shortened))"
                                    )
                                    .accessibilityIdentifier("photo.grid.\(photo.id)")
                                }
                            }
                        }
                    }
                }
                if store.photoGallery.pendingCount > 0 {
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
                        Text("Не завершено сохранение: \(store.photoGallery.pendingCount)").font(.headline)
                        ForEach(store.photoGallery.pendingPhotos.filter { $0.babyID == store.baby?.id }) { photo in
                            VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                                Text(photo.capturedAt, format: .dateTime.day().month().hour().minute())
                                if store.photoGallery.needsReconciliation(photo) {
                                    Text(
                                        "Сохранение в Фото прервалось. Выберите уже сохранённый снимок, чтобы завершить добавление без новой копии."
                                    )
                                    .font(.subheadline).foregroundStyle(.secondary)
                                    Button("Проверить в Фото") {
                                        recoveryPhoto = photo; recoveryPicker = true
                                    }.accessibilityIdentifier("photo.pending.reconcile")
                                }
                            }
                        }
                        Button("Повторить сохранение в Фото") { Task { await store.photoGallery.retryPending() } }
                            .accessibilityIdentifier("photo.pending.retry")
                    }
                }
            }.padding(AppDesign.Spacing.contentInset)
        }
        .background(AppDesign.Palette.groupedBackground)
        .navigationTitle("Фотографии малыша")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isPresentedModally {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }.accessibilityIdentifier("photo.gallery.close")
                }
            }
            ToolbarItem(placement: .topBarTrailing) { PhotoAddButton(store: store, isPresenting: $adding) }
        }
        .photosPicker(isPresented: $recoveryPicker, selection: $recoveryItem, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: recoveryItem) { _, item in
            guard let item, let photo = recoveryPhoto else { return }
            guard let identifier = item.itemIdentifier else {
                store.photoGallery.errorMessage = "Не удалось определить снимок в Фото. Выберите его снова."
                return
            }
            Task {
                await store.photoGallery.reconcilePending(photo.id, existingAssetIdentifier: identifier)
                recoveryPhoto = nil; recoveryItem = nil
            }
        }
        .onAppear { reload() }
        .onChange(of: store.photoGallery.revision) { reload() }
        .onChange(of: store.selectedID) { selected = nil; adding = false; dismiss() }
        .fullScreenCover(item: $selected) { photo in
            PhotoViewer(store: store, initialID: photo.id)
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(
            get: { store.photoGallery.errorMessage != nil },
            set: {
                if !$0 {
                    store.photoGallery.errorMessage = nil
                }
            }
        )) {
            Button("Понятно", role: .cancel) { store.photoGallery.errorMessage = nil }
        } message: { Text(store.photoGallery.errorMessage ?? "") }
    }

    private func reload() {
        guard let id = store.baby?.id else { photos = []; return }
        do {
            photos = try store.photoGallery.photos(babyID: id)
            loadError = nil
        } catch { loadError = "Попробуйте открыть галерею снова." }
    }
}

private struct PhotoImage: View {
    let gallery: PhotoGalleryStore
    let photo: BabyPhoto
    let thumbnail: Bool
    var body: some View {
        if let data = gallery.data(for: photo, thumbnail: thumbnail), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().aspectRatio(contentMode: thumbnail ? .fill : .fit)
        } else {
            ContentUnavailableView("Снимок недоступен", systemImage: "photo")
        }
    }
}

private struct PhotoViewer: View {
    let store: AppStore
    let initialID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var sharedFile: URL?
    @State private var errorMessage: String?
    private var photos: [BabyPhoto] {
        _ = store.photoGallery.revision
        return (try? store.photoGallery.photos(babyID: store.baby?.id ?? UUID())) ?? []
    }

    private var current: BabyPhoto? {
        photos.first { $0.id == (selection ?? initialID) }
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(photos) { photo in
                    PhotoImage(gallery: store.photoGallery, photo: photo, thumbnail: false)
                        .tag(Optional(photo.id))
                        .accessibilityIdentifier("photo.full.\(photo.id)")
                }
            }
            .tabViewStyle(.page)
            .onAppear { selection = initialID }
            .navigationTitle(current?.capturedAt.formatted(date: .abbreviated, time: .shortened) ?? "Фотография")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                if let photo = current, let age = store.baby?.ageLabel(now: photo.capturedAt) {
                    Text(age).font(.subheadline).padding().frame(maxWidth: .infinity).background(.regularMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }.accessibilityIdentifier("photo.viewer.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let photo = current {
                        Menu {
                            Button(photo.isFavorite ? "Убрать из избранного" : "В избранное", systemImage: "heart") {
                                perform { try store.photoGallery.toggleFavorite(photo) }
                            }.accessibilityIdentifier("photo.favorite")
                            Button("Сделать главным", systemImage: "person.crop.square") {
                                if let id = store.baby?.id {
                                    perform { try store.photoGallery.pin(
                                        photo,
                                        babyID: id
                                    ); try store.reload() }
                                }
                            }.accessibilityIdentifier("photo.pin")
                            Button("Поделиться", systemImage: "square.and.arrow.up") { share(photo) }
                                .accessibilityIdentifier("photo.share")
                            Button("Сохранить в Фото", systemImage: "square.and.arrow.down") {
                                Task { await store.photoGallery.saveToPhotos(photo) }
                            }.disabled(store.photoGallery.hasLocalAsset(photo)).accessibilityIdentifier("photo.save")
                            Button("Удалить из галереи", systemImage: "trash", role: .destructive) {
                                perform { try store.photoGallery.delete(photo) }
                                if photos.isEmpty {
                                    dismiss()
                                } else {
                                    selection = photos.first?.id
                                }
                            }.accessibilityIdentifier("photo.delete")
                        } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                            .accessibilityLabel("Действия с фотографией").accessibilityIdentifier("photo.actions")
                    }
                }
            }
            .sheet(
                isPresented: Binding(get: { sharedFile != nil }, set: {
                    if !$0 {
                        cleanupShare()
                    }
                }),
                onDismiss: cleanupShare
            ) {
                if let sharedFile {
                    PhotoShareSheet(url: sharedFile)
                }
            }
            .alert("Не удалось выполнить действие", isPresented: Binding(
                get: { errorMessage != nil || store.photoGallery.errorMessage != nil },
                set: {
                    if !$0 {
                        errorMessage = nil; store.photoGallery.errorMessage = nil
                    }
                }
            )) { Button("Понятно", role: .cancel) { errorMessage = nil; store.photoGallery.errorMessage = nil } }
            message: { Text(errorMessage ?? store.photoGallery.errorMessage ?? "") }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func cleanupShare() {
        if let sharedFile {
            try? FileManager.default.removeItem(at: sharedFile)
        }
        sharedFile = nil
    }

    private func share(_ photo: BabyPhoto) {
        guard let data = store.photoGallery.data(for: photo, thumbnail: false) else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "PhotoShares",
                isDirectory: true
            )
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suffix = data.starts(with: [0xFF, 0xD8]) ? "jpg" : "heic"
            let url = directory.appendingPathComponent("\(photo.id).\(suffix)")
            try data.write(to: url, options: .atomic)
            sharedFile = url
        } catch { errorMessage = "Не удалось подготовить фотографию. Попробуйте снова." }
    }
}

private struct PhotoShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}
