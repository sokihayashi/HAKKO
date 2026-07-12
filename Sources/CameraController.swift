import AVFoundation
import UIKit

/// Stage 1: 背面カメラのライブプレビュー＋torch常時点灯の高速連写バースト。
///
/// 発光方式の確定（実機A/B検証・デザインメモ§8）:
/// - torch(連続LED光)＋flashMode=.off。写真フラッシュ(.on)はプリフラッシュ測光が構造的に必須で600〜1700ms、
///   AEロックでも迂回不能。iPhoneのフラッシュもLED連続光で凍結効果は無くtorchと本質同じ。torch方式なら
///   プリ測光ゼロで meter=2〜5ms（実測）。torchは開始時に1回だけlockForConfigurationし撮影中は触らない＝-11830回避。
/// - 露出/WB/AFはロックしない。torch常時点灯下では継続オートのままで安定し、被写体変化にも追従（動画化前提）。
///   実機で.lockedはバースト境界の再収束スパイクを生むだけで跳ねは消えなかったため撤去。
/// - 触覚(.hapticTransient)は willCapturePhoto（＝実発光の瞬間）で鳴らして発光と同期。
///
/// 操作モデル: 1回押したら maxBurst まで自動連射（指離しで止めない＝連打/離し判定のバグ源を排除）。
/// 撮った画像はメモリ配列に保持（将来これを合体して動画GIF/mp4化する予定・加工/保存はStage2以降）。
/// 露出モードのA/B（meterスパイクの原因＝継続オートAEの再測光を消せるか実機で比較）。
/// リサーチ確定: torch常時点灯は明るさを変えAEを刺激→再測光の数百msスパイクを生む。
/// customLockedで露出を完全固定すればスパイクが消える（ただしZSLはcustom露出と排他で無効化）。
enum ExposureMode: CaseIterable {
    /// 継続オート＋ZSL有効（現状）。被写体変化に追従するがtorch由来のAE再測光スパイクが出る。
    case autoZSL
    /// 露出/ISO/WB/AFをバースト間も完全固定（setExposureModeCustom）。スパイクを消す。ZSLは無効化。
    case customLocked

    var label: String {
        switch self {
        case .autoZSL: return "EXP: auto+ZSL"
        case .customLocked: return "EXP: custom-locked"
        }
    }
}

final class CameraController: NSObject, ObservableObject {
    // MARK: - チューニング定数（宋其が調整）

    /// 連写バーストの最大枚数。動画化の素材数を兼ねつつ、torch発熱スロットルを避け8。
    static let maxBurst = 8
    /// torchの明るさ（0.0–1.0）。発光の強さ。実機で詰める。
    static let torchLevel: Float = 1.0

    /// 露出モード（デバッグA/B）。UIから循環切替。
    @Published var exposureMode: ExposureMode = .autoZSL

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.sokihayashi.HAKKO.sessionQueue")
    private let photoOutput = AVCapturePhotoOutput()
    /// 触覚エンジンはsessionQueueを共有して全アクセスを直列化する（CoreHapticsハンドラとのデータレース回避）。
    private lazy var haptics = HapticEngine(queue: sessionQueue)
    private var isConfigured = false
    /// torch/ロック操作のため撮影デバイスを保持（sessionQueue上で触る）。
    private var videoDevice: AVCaptureDevice?
    /// バースト用のデバイス設定(torch/ロック)を適用したか。teardown成功時のみ下ろす（後始末取りこぼし防止）。
    private var burstSetupApplied = false
    /// バースト開始時にexposureModeを固定（途中でモードが変わっても現バーストは一貫）。
    private var activeExposureMode: ExposureMode = .autoZSL

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

    // デバッグ計測: 撮影発火→露出確定 と 露出確定→処理完了 の内訳。
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
            // session停止で torch/custom露出/ZSL は物理的にリセットされる。stop経路では beginConfiguration を
            // 伴うteardown（ZSL再有効化）を走らせず、torch消灯だけ軽く行ってから停止する（構成変更の交差回避）。
            self.turnTorchOffOnly()
            self.isBursting = false
            self.shotInFlight = false      // session停止で飛行中delegateが来ない可能性に備え自己完結
            self.burstSetupApplied = false // session停止でデバイス状態はリセットされる。フラグも揃える。
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    /// torchだけ消す（stop経路用・session構成変更を伴わない軽い後始末）。sessionQueue上。
    private func turnTorchOffOnly() {
        guard let device = videoDevice, device.hasTorch, device.torchMode != .off else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = .off
        } catch {
            print("[HAKKO] stop torch off failed: \(error)")
        }
    }

    private func configureAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                guard self.configureSession() else {
                    print("[HAKKO] session configuration failed; not starting")
                    return
                }
                self.isConfigured = true
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    /// セッション構成。成否を返す（失敗時はisConfiguredを立てない）。
    private func configureSession() -> Bool {
        session.beginConfiguration()
        session.sessionPreset = .photo

        // デザインメモ §4: 物理カメラを明示指定（広角単体）。仮想デバイスの自動融合・自動レンズ切替を避ける。
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            print("[HAKKO] failed to configure back camera input")
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        videoDevice = device

        guard session.canAddOutput(photoOutput) else {
            print("[HAKKO] failed to add photo output")
            session.commitConfiguration()
            return false
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .speed

        // ZSL/responsive/fastは初期有効（autoZSLモード想定）。customLockedバースト時はcustom露出と排他なので無効化する。
        applyZSL(enabled: true)

        print("[HAKKO] supportedFlashModes on=\(photoOutput.supportedFlashModes.contains(.on)) hasTorch=\(device.hasTorch)")

        session.commitConfiguration()
        return true
    }

    /// ZSL/responsiveCapture/fastCapturePrioritizationの有効/無効を切り替える（session構成変更・iOS17+）。
    /// custom露出はZSLと排他なので、customLockedバースト時は無効化する。依存: responsiveはZSL必須、fastはresponsive必須。
    private func applyZSL(enabled: Bool) {
        guard #available(iOS 17.0, *) else { return }
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = enabled }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = enabled && photoOutput.isZeroShutterLagEnabled
        }
        if photoOutput.isFastCapturePrioritizationSupported {
            photoOutput.isFastCapturePrioritizationEnabled = enabled && photoOutput.isResponsiveCaptureEnabled
        }
    }

    // MARK: - 連写バースト（torch常時点灯・自動連射・仕様書 §2・§3・§4）

    /// 露出モードを循環切替（デバッグA/B）。UI(main)から呼ぶ。
    func cycleExposureMode() {
        let all = ExposureMode.allCases
        guard let idx = all.firstIndex(of: exposureMode) else { return }
        exposureMode = all[(idx + 1) % all.count]
    }

    /// シャッターを押したら maxBurst まで自動連射（指離しでは止めない）。UI(main)からexposureModeを読む。
    func startBurst() {
        let mode = exposureMode
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.isBursting else { return }
            self.burstGeneration &+= 1        // 世代を進める（遅れて着弾する前バースト完了を弾く）
            self.isBursting = true
            self.burstCount = 0
            self.shotInFlight = false
            self.activeExposureMode = mode     // 現バーストのモードを固定
            self.images.removeAll()
            self.publishImages()
            self.haptics.prewarmBurstPlayer() // 触覚をwillCaptureで即発火できるよう先に用意
            self.applyBurstDeviceSetup()      // torch点灯 + (customLockedなら)露出固定（開始時1回・撮影中は触らない）
            self.fireNextShotIfNeeded()
        }
    }

    /// バーストを終了状態にしてデバイス設定を後始末する（撃ち切り/stopの経路から・冪等）。
    private func endBurst() {
        isBursting = false
        if burstSetupApplied {
            teardownBurstDeviceSetup()
        }
    }

    /// バースト開始時のデバイス設定（sessionQueue上で1回だけ・撮影中は触らない＝-11830回避）。
    /// torch点灯は両モード共通。customLockedのみ露出/ISO/WB/AFを固定してAE再測光のmeterスパイクを消す。
    /// ※setTorchModeOn直後のisTorchActiveチェックは点灯のハード非同期遅延で誤検出するため行わない
    ///   （リサーチ確定・真の失敗はthrowで捕まる）。
    private func applyBurstDeviceSetup() {
        guard let device = videoDevice, device.hasTorch, device.isTorchModeSupported(.on) else { return }

        // customLockedはZSL(custom露出と排他)を無効化してから固定する。session構成変更はlockとは別経路。
        if activeExposureMode == .customLocked {
            session.beginConfiguration()
            applyZSL(enabled: false)
            session.commitConfiguration()
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            try device.setTorchModeOn(level: Self.torchLevel)

            if activeExposureMode == .customLocked {
                // WB/AFを先に固定（露出のcompletion待ちの間も変動させない）。
                if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
                if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                // 露出を現在値でcustom固定。activeFormatの範囲にクランプ（範囲外は-11800/例外の主因）。
                if device.isExposureModeSupported(.custom) {
                    let fmt = device.activeFormat
                    let dur = clampTime(device.exposureDuration, fmt.minExposureDuration, fmt.maxExposureDuration)
                    let iso = min(max(device.iso, fmt.minISO), fmt.maxISO)
                    device.setExposureModeCustom(duration: dur, iso: iso, completionHandler: nil)
                } else {
                    print("[HAKKO] custom exposure not supported; falling back to auto")
                }
            }
            burstSetupApplied = true
        } catch {
            print("[HAKKO] burst device setup failed: \(error)")
        }
    }

    /// バースト終了時の後始末（sessionQueue上）。torch消灯＋(customLockedなら)露出/WB/AFを継続オートへ戻す。
    /// 成功時のみフラグを下ろす。custom無効化したZSLも再有効化。
    private func teardownBurstDeviceSetup() {
        guard let device = videoDevice else { burstSetupApplied = false; return }
        let wasCustom = activeExposureMode == .customLocked
        var restored = false
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.hasTorch, device.torchMode != .off { device.torchMode = .off }
            if wasCustom {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
            restored = true
            burstSetupApplied = false
        } catch {
            print("[HAKKO] burst device teardown failed: \(error)") // フラグは下ろさず次回再試行
        }
        // ZSL再有効化はexposure復帰が成功した場合のみ。失敗時はcustom露出が残っており、ZSLと排他違反になる。
        if wasCustom && restored {
            session.beginConfiguration()
            applyZSL(enabled: true)
            session.commitConfiguration()
        }
    }

    /// CMTimeを[lo, hi]にクランプ（露出時間をactiveFormatの範囲に収める）。
    private func clampTime(_ v: CMTime, _ lo: CMTime, _ hi: CMTime) -> CMTime {
        if CMTimeCompare(v, lo) < 0 { return lo }
        if CMTimeCompare(v, hi) > 0 { return hi }
        return v
    }

    /// 内部配列のスナップショットをmainの@Publishedへ反映（sessionQueue上で呼ぶ）。
    private func publishImages() {
        let snapshot = images
        DispatchQueue.main.async { [weak self] in
            self?.capturedImages = snapshot
        }
    }

    /// 次の1枚を撮る。撮影完了を待ってから次を撃つ直列。sessionQueue上で呼ぶ。maxBurstで自動的に撃ち切る。
    private func fireNextShotIfNeeded() {
        guard isBursting else { return }
        if burstCount >= Self.maxBurst {
            endBurst() // 撃ち切り＋デバイス後始末（→この後Stage3の発光チャージへ繋げる）
            return
        }
        guard !shotInFlight else { return }

        burstCount += 1
        shotInFlight = true
        inFlightGeneration = burstGeneration

        let settings = AVCapturePhotoSettings()
        // torch常時点灯なのでフラッシュはオフ（プリ測光ゼロ）。
        if photoOutput.supportedFlashModes.contains(.off) {
            settings.flashMode = .off
        }
        settings.photoQualityPrioritization = .speed
        if photoOutput.isVirtualDeviceFusionSupported {
            settings.isAutoVirtualDeviceFusionEnabled = false
        }

        // 昇圧音プレースホルダ: コマ間の待ちを"チャージ"として演出（本格合成はStage3）。
        haptics.startChargePlaceholder()

        inFlightFireTime = ProcessInfo.processInfo.systemUptime
        inFlightWillCaptureTime = 0 // willCapture未着(エラー枚)を検出可能に（計測交差防止）
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    /// 露出が確定し実際に撮影される瞬間。ここで触覚を鳴らす＝発光と触覚を同期。
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.inFlightWillCaptureTime = ProcessInfo.processInfo.systemUptime
            // 世代が変わった前バーストの残弾では触覚を鳴らさない（誤発火・二重発火の防止）。
            guard self.isBursting, self.inFlightGeneration == self.burstGeneration else { return }
            self.haptics.stopChargePlaceholder()      // 充電演出を止め
            self.haptics.playBurstTick()              // 撮影の瞬間に "ガシャッ"（触覚）
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
            let totalMs = (done - self.inFlightFireTime) * 1000
            if self.inFlightWillCaptureTime > 0 {
                let meterMs = (self.inFlightWillCaptureTime - self.inFlightFireTime) * 1000
                let captureMs = (done - self.inFlightWillCaptureTime) * 1000
                print(String(format: "[HAKKO][measure] mode=%@ meter=%.0fms capture=%.0fms total=%.0fms",
                             self.activeExposureMode.label, meterMs, captureMs, totalMs))
            } else {
                print(String(format: "[HAKKO][measure] mode=%@ (no willCapture) total=%.0fms",
                             self.activeExposureMode.label, totalMs))
            }

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
