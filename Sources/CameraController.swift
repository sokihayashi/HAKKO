import AVFoundation

/// Stage 0: 背面カメラのライブプレビューのみを担うキャプチャセッション管理。
/// 撮影(AVCapturePhotoOutput)は Stage 1 で追加する。
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.sokihayashi.HAKKO.sessionQueue")
    private var isConfigured = false

    /// カメラ権限を確認し、許可されていればセッションを構成して開始する。
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    print("[HAKKO] camera access denied")
                    return
                }
                self?.configureAndRun()
            }
        default:
            print("[HAKKO] camera not authorized (status=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("[HAKKO] failed to configure back camera input")
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        session.commitConfiguration()
    }
}
