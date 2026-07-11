import AVFoundation
import UIKit

/// Stage 1: 背面カメラのライブプレビュー＋本物フラッシュ連写バースト。
///
/// 設計方針（実機A/B検証を経た確定事項・デザインメモ§8）:
/// - 発光は必ず物理フラッシュ（flashMode=.on）。実光がシーンに当たる＝HAKKOの堀。後処理やトーチでは
///   照射範囲・falloff・背景の落ちを捏造できない。トーチ手動ストロボはlock競合で撮影が壊れる(-11830)ため破棄。
/// - 速さは追わない。フラッシュの実サイクル（測光＋発光＋処理）に合わせ、撮影完了を待ってから次を撃つ直列。
///   コマ間の測光/充電待ちは"チャージ"の体感として肯定する（疾走感でなく一発感・仕様書§2 待ち=リズム）。
/// - 触覚(.hapticTransient)は willCapturePhoto（＝実発光の瞬間）で鳴らす。測光にどれだけかかっても触覚は
///   必ずフラッシュと同時に来る＝「音より先に光る」を根本解決。
/// 撮った画像はメモリ上の配列に保持するのみ（加工/保存は Stage 2 以降）。
final class CameraController: NSObject, ObservableObject {
    // MARK: - チューニング定数（宋其が調整）

    /// 連写バーストの最大枚数。本物フラッシュのサイクルに合わせ小さめ（初期4〜5）。
    static let maxBurst = 5

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.sokihayashi.HAKKO.sessionQueue")
    private let photoOutput = AVCapturePhotoOutput()
    /// 触覚エンジンはsessionQueueを共有して全アクセスを直列化する（CoreHapticsハンドラとのデータレース回避）。
    private lazy var haptics = HapticEngine(queue: sessionQueue)
    private var isConfigured = false

    /// 撮影済み画像（メモリ保持のみ）。UIへはsessionQueue上の内部配列のスナップショットを反映する。
    @Published private(set) var capturedImages: [UIImage] = []

    // 連写状態（sessionQueue上でのみ触る）
    private var isBursting = false
    private var burstCount = 0
    private var shotInFlight = false
    /// バースト世代。開始のたびにインクリメントし、遅れて着弾した前バーストの完了を弾く。
    private var burstGeneration = 0
    /// 現在飛行中の1枚を発火したときの世代。
    private var inFlightGeneration = 0
    /// sessionQueue上でのみ触る実体。mainへはこれをスナップショットして流す（main.async順序非保証を回避）。
    private var images: [UIImage] = []

    // デバッグ計測: 撮影発火→露出確定(測光/充電) と 露出確定→処理完了(撮影/保存) の内訳。
    private var inFlightFireTime: TimeInterval = 0
    private var inFlightWillCaptureTime: TimeInterval = 0

    // MARK: - ライフサイクル

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
            guard let self else { return }
            self.isBursting = false
            guard self.session.isRunning else { return }
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

        // デザインメモ §4: 物理カメラを明示指定（広角単体）。仮想デバイスの自動融合・自動レンズ切替を避け、
        // CCD素材として制御しやすい単眼の画にする。
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("[HAKKO] failed to configure back camera input")
            session.commitConfiguration()
            return
        }
        session.addInput(input)

        guard session.canAddOutput(photoOutput) else {
            print("[HAKKO] failed to add photo output")
            session.commitConfiguration()
            return
        }
        session.addOutput(photoOutput)

        // デザインメモ §4: 仮想デバイス融合を避ける（広角単眼なので実質no-opだが撮影設定側で明示）。
        photoOutput.maxPhotoQualityPrioritization = .speed

        session.commitConfiguration()
    }

    // MARK: - 連写バースト（本物フラッシュ・仕様書 §2・§3・§4）

    /// シャッター長押し開始で連写バーストを開始。
    func startBurst() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.isBursting else { return }
            self.burstGeneration &+= 1        // 世代を進める（遅れて着弾する前バースト完了を弾く）
            self.isBursting = true
            self.burstCount = 0
            self.shotInFlight = false
            self.images.removeAll()
            self.publishImages()
            self.haptics.prewarmBurstPlayer() // 触覚をwillCaptureで即発火できるよう先に用意
            self.fireNextShotIfNeeded()
        }
    }

    /// 指を離す/撃ち切りで連写を止める。
    func stopBurst() {
        sessionQueue.async { [weak self] in
            self?.isBursting = false
        }
    }

    /// 内部配列のスナップショットをmainの@Publishedへ反映（sessionQueue上で呼ぶ）。
    private func publishImages() {
        let snapshot = images
        DispatchQueue.main.async { [weak self] in
            self?.capturedImages = snapshot
        }
    }

    /// 次の1枚を撮る。撮影完了を待ってから次を撃つ直列（フラッシュの実サイクルが律速＝速さは追わない）。
    /// sessionQueue上で呼ぶ。「1枚飛行中は次を出さない」で二重発火を防ぐ。
    private func fireNextShotIfNeeded() {
        guard isBursting else { return }
        if burstCount >= Self.maxBurst {
            isBursting = false // 撃ち切り（→この後Stage3の発光チャージへ繋げる）
            return
        }
        guard !shotInFlight else { return }

        burstCount += 1
        shotInFlight = true
        inFlightGeneration = burstGeneration

        let settings = AVCapturePhotoSettings()
        // 本物のフラッシュ（実光がシーンに当たる＝HAKKOの堀）。サポートするときのみ。
        if photoOutput.supportedFlashModes.contains(.on) {
            settings.flashMode = .on
        }
        settings.photoQualityPrioritization = .speed
        if photoOutput.isVirtualDeviceFusionSupported {
            settings.isAutoVirtualDeviceFusionEnabled = false
        }

        // 昇圧音プレースホルダ: コマ間の測光/充電待ちを"チャージ"として演出（本格合成はStage3）。
        // ※.hapticContinuousは連写禁止（仕様書§3）。ここでは音の器だけ用意し、実音はStage3で。
        haptics.startChargePlaceholder()

        inFlightFireTime = ProcessInfo.processInfo.systemUptime
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    /// 露出が確定し実際にフラッシュが焚かれる瞬間。ここで触覚を鳴らす＝発光と触覚を厳密同期。
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.inFlightWillCaptureTime = ProcessInfo.processInfo.systemUptime
            self.haptics.stopChargePlaceholder()      // 充電演出を止め
            self.haptics.playBurstTick()              // 実発光の瞬間に "ゴッ"（触覚）
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        let flashFired = photo.resolvedSettings.isFlashEnabled

        // 画像データの生成（重い処理）はコールバックスレッドで。状態更新はsessionQueueに直列化する。
        var image: UIImage?
        if let error {
            print("[HAKKO] capture error: \(error)")
        } else if let data = photo.fileDataRepresentation(), let decoded = UIImage(data: data) {
            image = decoded
        } else {
            print("[HAKKO] failed to build UIImage from photo")
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            let done = ProcessInfo.processInfo.systemUptime
            let meterMs = (self.inFlightWillCaptureTime - self.inFlightFireTime) * 1000
            let captureMs = (done - self.inFlightWillCaptureTime) * 1000
            let totalMs = (done - self.inFlightFireTime) * 1000
            print(String(format: "[HAKKO][measure] flashFired=%@ meter=%.0fms capture=%.0fms total=%.0fms",
                         flashFired ? "YES" : "no", meterMs, captureMs, totalMs))

            let generation = self.inFlightGeneration
            self.shotInFlight = false
            self.haptics.stopChargePlaceholder() // 念のため（エラー時にwillCaptureが来ないケース）
            // 遅れて着弾した前バーストの1枚は、世代が変わっていれば取り込まない（混入防止）。
            if generation == self.burstGeneration, let image {
                self.images.append(image)
                self.publishImages()
            }
            self.fireNextShotIfNeeded()
        }
    }
}
