@preconcurrency import AVFoundation
import SwiftUI

/// Captures the encoded camera resource, including its metadata, without a UIImage round trip.
struct PhotoCaptureView: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onError: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context _: Context) -> CameraController {
        CameraController(onCapture: onCapture, onError: onError, onCancel: onCancel)
    }

    func updateUIViewController(_: CameraController, context _: Context) {}

    static func dismantleUIViewController(_ controller: CameraController, coordinator _: ()) {
        controller.deactivate()
    }

    final class CameraController: UIViewController, AVCapturePhotoCaptureDelegate {
        private let driver = CameraSessionDriver()
        private var prepareTask: Task<Void, Never>?
        private var isActive = true
        private var preview: AVCaptureVideoPreviewLayer?
        private let onCapture: (Data) -> Void
        private let onError: (String) -> Void
        private let onCancel: () -> Void
        private let shutter = UIButton(type: .system)

        init(onCapture: @escaping (Data) -> Void, onError: @escaping (String) -> Void,
             onCancel: @escaping () -> Void)
        {
            self.onCapture = onCapture
            self.onError = onError
            self.onCancel = onCancel
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            shutter.setTitle("Сфотографировать", for: .normal)
            shutter.accessibilityIdentifier = "photo.camera.shutter"
            shutter.addTarget(self, action: #selector(capture), for: .touchUpInside)
            shutter.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(shutter)
            let cancel = UIButton(type: .system)
            cancel.setTitle("Отмена", for: .normal)
            cancel.addTarget(self, action: #selector(cancelCapture), for: .touchUpInside)
            cancel.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(cancel)
            NSLayoutConstraint.activate([
                shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
                shutter.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
                cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                   ProcessInfo.processInfo.arguments.contains("--photo-camera-fixture")
                {
                    return
                }
            #endif
            prepareTask = Task { await prepare() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            deactivate()
        }

        func deactivate() {
            isActive = false
            prepareTask?.cancel()
            prepareTask = nil
            driver.stop()
        }

        private func prepare() async {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard isActive, !Task.isCancelled else { return }
            guard allowed else {
                deactivate()
                onError("Разрешите доступ к камере в Настройках, чтобы сфотографировать малыша.")
                return
            }
            driver.start { [weak self] succeeded in
                Task { @MainActor in
                    guard let self, self.isActive else { return }
                    guard succeeded else {
                        self.deactivate()
                        self.onError("Камера недоступна. Попробуйте снова или выберите фотографию из Фото.")
                        return
                    }
                    let layer = AVCaptureVideoPreviewLayer(session: self.driver.session)
                    layer.videoGravity = .resizeAspectFill
                    self.view.layer.insertSublayer(layer, at: 0)
                    self.preview = layer
                    self.view.setNeedsLayout()
                }
            }
        }

        @objc private func capture() {
            guard isActive else { return }
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                   ProcessInfo.processInfo.arguments.contains("--photo-camera-fixture")
                {
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
                    let data = renderer.pngData { context in
                        UIColor.systemOrange.setFill()
                        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
                    }
                    deactivate()
                    onCapture(data)
                    return
                }
            #endif
            guard driver.session.isRunning else { return }
            shutter.isEnabled = false
            let settings = AVCapturePhotoSettings()
            driver.output.capturePhoto(with: settings, delegate: self)
        }

        @objc private func cancelCapture() {
            deactivate()
            onCancel()
        }

        nonisolated func photoOutput(_: AVCapturePhotoOutput,
                                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?)
        {
            let data = error == nil ? photo.fileDataRepresentation() : nil
            Task { @MainActor in
                guard self.isActive else { return }
                self.deactivate()
                if let data {
                    self.onCapture(data)
                } else {
                    self.onError("Не удалось снять фотографию. Попробуйте снова.")
                }
            }
        }
    }
}

/// All configuration and running transitions share one queue. Invalidation is immediate,
/// so a permission response or queued start cannot revive a dismissed camera.
private final class CameraSessionDriver: @unchecked Sendable {
    let session = AVCaptureSession()
    let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "Malysh.PhotoCamera", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true

    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard isActive else { return }
            do {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                else { throw NSError(domain: "PhotoCamera", code: 1) }
                let input = try AVCaptureDeviceInput(device: device)
                session.beginConfiguration()
                session.sessionPreset = .photo
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw NSError(domain: "PhotoCamera", code: 1)
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                guard isActive else { return }
                session.startRunning()
                completion(true)
            } catch { completion(false) }
        }
    }

    func stop() {
        lock.lock()
        active = false
        lock.unlock()
        queue.async { [self] in session.stopRunning() }
    }
}
