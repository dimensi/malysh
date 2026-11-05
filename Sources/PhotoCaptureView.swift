@preconcurrency import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Uses the system camera, including its capture, retake and confirmation controls.
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

    final class CameraController: UIViewController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onError: (String) -> Void
        private let onCancel: () -> Void
        private var preparation: Task<Void, Never>?
        private var isActive = true
        private var started = false

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

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !started else { return }
            started = true
            view.backgroundColor = .systemBackground
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                   ProcessInfo.processInfo.arguments.contains("--photo-camera-fixture")
                {
                    showFixture()
                    return
                }
            #endif
            preparation = Task { await presentCamera() }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Presenting the native camera also hides this host. Only invalidate when
            // the host itself is being dismissed, not when its camera is presented.
            if isBeingDismissed || presentingViewController?.isBeingDismissed == true {
                deactivate()
            }
        }

        func deactivate() {
            isActive = false
            preparation?.cancel()
            preparation = nil
        }

        private func presentCamera() async {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard isActive, !Task.isCancelled else { return }
            guard allowed else {
                fail("Разрешите доступ к камере в Настройках, чтобы сфотографировать малыша.")
                return
            }
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                fail("Камера недоступна. Выберите фотографию из Фото.")
                return
            }
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.mediaTypes = [UTType.image.identifier]
            picker.cameraCaptureMode = .photo
            picker.allowsEditing = false
            picker.delegate = self
            picker.modalPresentationStyle = .fullScreen
            present(picker, animated: true)
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            guard isActive else { return }
            deactivate()
            onCancel()
        }

        func imagePickerController(_: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any])
        {
            guard isActive else { return }
            // When supplied, this is the camera file itself: no re-encoding.
            if let url = info[.imageURL] as? URL, let data = try? Data(contentsOf: url) {
                finish(data)
                return
            }
            // The system camera may only supply originalImage. Encode its full pixel buffer
            // once, at maximum quality, retaining the camera metadata and EXIF orientation.
            guard let image = info[.originalImage] as? UIImage, let pixels = image.cgImage else {
                fail("Не удалось получить фотографию. Попробуйте снова.")
                return
            }
            var metadata = info[.mediaMetadata] as? [String: Any] ?? [:]
            metadata[kCGImagePropertyOrientation as String] = image.imageOrientation.exifOrientation
            metadata[kCGImageDestinationLossyCompressionQuality as String] = 1.0
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else {
                fail("Не удалось сохранить фотографию. Попробуйте снова.")
                return
            }
            CGImageDestinationAddImage(destination, pixels, metadata as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                fail("Не удалось сохранить фотографию. Попробуйте снова.")
                return
            }
            finish(data as Data)
        }

        private func finish(_ data: Data) {
            guard isActive else { return }
            deactivate()
            onCapture(data)
        }

        private func fail(_ message: String) {
            guard isActive else { return }
            deactivate()
            onError(message)
        }

        #if DEBUG
            private func showFixture() {
                let shutter = UIButton(type: .system)
                shutter.setTitle("Сфотографировать", for: .normal)
                shutter.accessibilityIdentifier = "photo.camera.shutter"
                shutter.addTarget(self, action: #selector(captureFixture), for: .touchUpInside)
                shutter.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(shutter)
                NSLayoutConstraint.activate([
                    shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    shutter.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    shutter.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
                ])
            }

            @objc private func captureFixture() {
                guard isActive else { return }
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
                let data = renderer.pngData { context in
                    UIColor.systemOrange.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
                }
                finish(data)
            }
        #endif
    }
}

private extension UIImage.Orientation {
    var exifOrientation: Int {
        switch self {
        case .up: 1
        case .upMirrored: 2
        case .down: 3
        case .downMirrored: 4
        case .leftMirrored: 5
        case .right: 6
        case .rightMirrored: 7
        case .left: 8
        @unknown default: 1
        }
    }
}
