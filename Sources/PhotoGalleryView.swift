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
    }

    static func accessibilityValue(for store: AppStore) -> String {
        let gallery = store.photoGallery
        _ = gallery.revision
        guard let baby = store.baby else { return "Фотографий пока нет" }
        let photos = (try? gallery.photos(babyID: baby.id)) ?? []
        guard let photo = BabyPhoto.avatar(in: photos, pinnedID: baby.pinnedPhotoID) else {
            return "Фотографий пока нет"
        }
        return "Главное фото от \(photo.capturedAt.formatted(date: .long, time: .shortened))"
    }
}

/// The native source dialog belongs to the camera button, including in the home header.
struct PhotoAddButton: View {
    let store: AppStore
    @Binding var isPresenting: Bool
    var onDismiss: () -> Void = {}
    var handlesServiceErrors = false
    var showsTitle = false
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
    @State private var choosingDate = false
    @State private var chosenImportDate: Date?
    @State private var dateContinuation: CheckedContinuation<Date?, Never>?
    @State private var importSession: UUID?
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        Button { sourceDialog = true; isPresenting = true } label: {
            if showsTitle {
                Group {
                    if isImporting {
                        ProgressView("Загружаем фотографии")
                    } else {
                        Label("Добавить фотографию", systemImage: "camera")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
                .padding(.vertical, AppDesign.Spacing.related)
                .foregroundStyle(AppDesign.Palette.primaryText)
                .background(AppDesign.Palette.sleep, in: RoundedRectangle(cornerRadius: AppDesign.Radius.card))
                .contentShape(RoundedRectangle(cornerRadius: AppDesign.Radius.card))
            } else if isImporting {
                ProgressView().accessibilityLabel("Загружаем фотографии")
                    .frame(minWidth: AppDesign.Metrics.minimumTouch, minHeight: AppDesign.Metrics.minimumTouch)
            } else {
                Image(systemName: "camera")
                    .frame(minWidth: AppDesign.Metrics.minimumTouch, minHeight: AppDesign.Metrics.minimumTouch)
            }
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
            Button("Выбрать из Фото") {
                importBabyID = store.baby?.id
                #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                       ProcessInfo.processInfo.arguments.contains("--photo-import-date-fixture")
                    {
                        importDateFixture()
                    } else {
                        picker = true
                    }
                #else
                    picker = true
                #endif
            }
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
            let session = beginImport()
            importTask = Task {
                var transferError: String?
                for item in selected {
                    guard isCurrentImport(session) else { return }
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            transferError = "Не удалось загрузить фотографию. Выберите её снова."
                            continue
                        }
                        guard isCurrentImport(session) else { return }
                        await importResource(data, assetIdentifier: item.itemIdentifier, babyID: id, session: session)
                    } catch { transferError = "Не удалось загрузить фотографию. Выберите её снова." }
                }
                finishImport(session, error: transferError)
            }
        }
        .onChange(of: sourceDialog) { _, visible in
            if !visible, !picker, !camera, !isImporting {
                isPresenting = false; onDismiss()
            }
        }
        .onChange(of: picker) { _, visible in
            if !visible, items.isEmpty, !isImporting {
                isPresenting = false; onDismiss()
            }
        }
        .onChange(of: isPresenting) { _, visible in
            if !visible {
                let wasImporting = importSession != nil
                let waitsForDateDismissal = choosingDate
                sourceDialog = false; picker = false; camera = false
                cancelImport()
                if wasImporting, !waitsForDateDismissal {
                    onDismiss()
                }
            }
        }
        .onDisappear {
            let wasImportingWithoutDateSheet = importSession != nil && dateContinuation == nil
            cancelImport()
            if wasImportingWithoutDateSheet {
                isPresenting = false
                onDismiss()
            }
        }
        .sheet(isPresented: $choosingDate, onDismiss: {
            finishDateChoice()
            if importSession == nil {
                onDismiss()
            }
        }) {
            PhotoImportDateView { date in
                chosenImportDate = date
                choosingDate = false
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

    private func importResource(_ data: Data, assetIdentifier: String?, babyID: UUID, session: UUID) async {
        guard isCurrentImport(session) else { return }
        let metadataDate = await store.photoGallery.importDate(for: data, assetIdentifier: assetIdentifier)
        guard isCurrentImport(session) else { return }
        let date: Date? = if let metadataDate {
            metadataDate
        } else {
            await withCheckedContinuation { continuation in
                dateContinuation = continuation
                chosenImportDate = nil
                choosingDate = true
            }
        }
        guard isCurrentImport(session), let date else { return }
        await store.photoGallery.importPhoto(
            data: data, assetIdentifier: assetIdentifier, babyID: babyID, capturedAt: date
        )
    }

    private func beginImport() -> UUID {
        cancelImport()
        let session = UUID()
        importSession = session
        isImporting = true
        return session
    }

    private func isCurrentImport(_ session: UUID) -> Bool {
        importSession == session && !Task.isCancelled
    }

    private func cancelImport() {
        items = []
        importSession = nil
        importTask?.cancel()
        importTask = nil
        isImporting = false
        chosenImportDate = nil
        choosingDate = false
        finishDateChoice()
    }

    private func finishImport(_ session: UUID, error: String? = nil) {
        guard isCurrentImport(session) else { return }
        importSession = nil
        importTask = nil
        isImporting = false
        if let error {
            localError = error
        }
        reportServiceError()
        items = []
        isPresenting = false
        onDismiss()
    }

    private func finishDateChoice() {
        let continuation = dateContinuation
        let date = chosenImportDate
        dateContinuation = nil
        chosenImportDate = nil
        continuation?.resume(returning: date)
    }

    #if DEBUG
        private func importDateFixture() {
            guard let id = importBabyID else { return }
            let session = beginImport()
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
            let data = renderer.pngData { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
            }
            importTask = Task {
                let count = ProcessInfo.processInfo.arguments.contains("--photo-import-date-batch-fixture") ? 2 : 1
                for _ in 0 ..< count {
                    guard isCurrentImport(session) else { return }
                    await importResource(data, assetIdentifier: nil, babyID: id, session: session)
                }
                finishImport(session)
            }
        }
    #endif

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

private struct PhotoImportDateView: View {
    let onChoose: (Date?) -> Void
    @State private var date = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Дата съёмки", selection: $date, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("photo.import.date")
                    Button("Снято сегодня") { onChoose(Date()) }
                        .accessibilityIdentifier("photo.import.today")
                } footer: {
                    Text(
                        "В файле нет даты съёмки. Укажите её, чтобы фотография появилась в нужном дне, а возраст малыша был рассчитан верно."
                    )
                }
            }
            .navigationTitle("Указать дату съёмки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Пропустить") { onChoose(nil) }.accessibilityIdentifier("photo.import.skip")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Использовать дату") { onChoose(date) }.accessibilityIdentifier("photo.import.confirm")
                }
            }
        }
    }
}

struct PhotoGalleryView: View {
    let store: AppStore
    var isPresentedModally = false
    @Binding var isPresenting: Bool
    var onDismiss: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var photos: [BabyPhoto] = []
    @State private var loadError: String?
    @State private var selected: BabyPhoto?
    @State private var adding = false
    @State private var recoveryPhoto: BabyPhoto?
    @State private var recoveryItem: PhotosPickerItem?
    @State private var recoveryPicker = false
    @State private var sharedFile: URL?
    @State private var sharing = false

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
                                    Button {
                                        isPresenting = true
                                        selected = photo
                                    } label: {
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
                                    .contextMenu {
                                        Button(
                                            photo.isFavorite ? "Убрать из избранного" : "В избранное",
                                            systemImage: "heart"
                                        ) {
                                            perform { try store.photoGallery.toggleFavorite(photo) }
                                        }
                                        Button("Сделать главным", systemImage: "person.crop.square") {
                                            perform {
                                                try store.photoGallery.pin(photo, babyID: photo.babyID)
                                                try store.reload()
                                            }
                                        }
                                        Button("Поделиться", systemImage: "square.and.arrow.up") { share(photo) }
                                        Button("Сохранить в Фото", systemImage: "square.and.arrow.down") {
                                            Task { await store.photoGallery.saveToPhotos(photo) }
                                        }.disabled(store.photoGallery.hasLocalAsset(photo))
                                        Button("Удалить из галереи", systemImage: "trash", role: .destructive) {
                                            perform { try store.photoGallery.delete(photo) }
                                        }
                                    }
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
                                        isPresenting = true
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
            ToolbarItem(placement: .topBarTrailing) {
                PhotoAddButton(store: store, isPresenting: $adding, onDismiss: presentationDidDismiss)
            }
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
        .onChange(of: adding) { _, presenting in
            if presenting {
                isPresenting = true
            }
        }
        .onChange(of: recoveryPicker) { _, presenting in
            if !presenting {
                presentationDidDismiss()
            }
        }
        .onChange(of: isPresenting) { _, presenting in
            if !presenting {
                recoveryPhoto = nil
                recoveryPicker = false
                adding = false
                sharing = false
                selected = nil
            }
        }
        .sheet(isPresented: $sharing, onDismiss: {
            cleanupShare()
            presentationDidDismiss()
        }) {
            if let sharedFile {
                PhotoShareSheet(url: sharedFile)
            }
        }
        .fullScreenCover(item: $selected, onDismiss: presentationDidDismiss) { photo in
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

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { store.photoGallery.errorMessage = error.localizedDescription }
    }

    private func presentationDidDismiss() {
        guard selected == nil, !sharing, !recoveryPicker, !adding else { return }
        isPresenting = false
        onDismiss()
    }

    private func cleanupShare() {
        if let sharedFile {
            try? FileManager.default.removeItem(at: sharedFile)
        }
        sharedFile = nil
    }

    private func share(_ photo: BabyPhoto) {
        guard let data = store.photoGallery.data(for: photo, thumbnail: false) else {
            store.photoGallery.errorMessage = "Не удалось подготовить фотографию. Попробуйте снова."
            return
        }
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
            isPresenting = true
            sharing = true
        } catch { store.photoGallery.errorMessage = "Не удалось подготовить фотографию. Попробуйте снова." }
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
