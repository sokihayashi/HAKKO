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
    /// 速SS固定＋ISO補正＋AF/WB固定（setExposureModeCustom）。AE再測光スパイクを消し、ブレも止める。ZSLは無効化。
    case customLocked

    var label: String {
        switch self {
        case .autoZSL: return "EXP: auto+ZSL"
        case .customLocked: return "EXP: fast-SS locked"
        }
    }
}

/// AF中の"ピントが動く"演出のA/B（デバッグ・実機で見比べて1本化する）。customLockedのフォーカス"間"に効く。
enum FocusFeel: CaseIterable {
    /// 山型: 被せ層のボケ量を 0→強→0 で動かす（ぶけて→スッと晴れる）。UI演出のみ・実映像は触らない。
    case bumpBlur
    /// オーバーシュート: 被せ層のボケを 強→行き過ぎ→合焦 で動かす（フォーカスサーチ風）。UI演出のみ。
    case overshootBlur
    /// レンズ実駆動: 実際にAFを手前→目標へ動かし実映像をボカす（最も本物）。被せ層は使わない。
    case realLensSweep

    var label: String {
        switch self {
        case .bumpBlur: return "AF: bump"
        case .overshootBlur: return "AF: overshoot"
        case .realLensSweep: return "AF: real-lens"
        }
    }
}

final class CameraController: NSObject, ObservableObject {
    // MARK: - チューニング定数（宋其が調整）

    /// 連写バーストの最大枚数。動画化の素材数を兼ねつつ、torch発熱スロットルを避け8。
    static let maxBurst = 8
    /// torchの明るさ（0.0–1.0）。発光の強さ。実機で詰める。
    static let torchLevel: Float = 1.0

    /// customLockedの目標シャッター速度（秒）。被写体を"凍らせる"ため速く固定する。
    /// ※HAKKOはtorch=連続光なので、動きを止める仕事は100%シャッター速度が担う（キセノンと違い発光では止まらない）。
    ///   1/120は"動かない前提"のSSで、動く被写体・動かしながら撮るとブレて"凍ったストロボ感"が出ない → 1/500へ。
    /// 短いほどブレは止まるが暗くなり、そのぶんISOで補正＝ノイズが増える（CCD狙いなのでノイズは歓迎/§14）。
    /// ※トーチは暗いので速すぎると最大ISOでも暗くなる（ISO saturatedログで検出）。速さ⇄明るさの最終値は実機で宋其が詰める。
    ///   実機では 1/250〜1/1000 を振って凍りと明るさの両立点を探す。
    static let targetShutter: TimeInterval = 1.0 / 500.0

    /// customLockedのレンズ位置（0.0=最至近 / 1.0=無限遠）。遠め固定でパンフォーカス＝ほぼ全体にピン。
    /// F値はiPhone固定（絞れない）ので、被写界深度は「遠めに置いて手前〜無限遠を許容内に入れる」で作る。
    /// CCDコンパクトの深い被写界深度（§2）に合わせる。実機で詰める。
    /// ※0.85(無限遠寄り)は近〜中距離の被写体でピンが甘く見えた(実機確認)→0.5(中距離)へ。
    ///   lensPositionは実距離と非線形(機種依存)。近すぎ/遠すぎで手前が外れるので中間から詰める。
    static let lensPosition: Float = 0.5

    /// torch点灯直後にAEがtorch光へ馴染むのを待つ秒数（W-2対策・sessionQueue上でasyncAfter）。
    /// torch前(暗い)のAE値でcustom固定すると1枚目が露出オーバー→点灯後この時間だけ継続オートで測らせてから固定する。
    /// 長いほど確実だが起動が鈍る。実機で1枚目の露出/明るさ揃いを見て詰める。
    static let aeSettleDelay: TimeInterval = 0.12

    /// AF演出(bump/overshoot)の被せ層ボケ最大opacity（0〜1）。強いほど濃く曇る。実機で詰める。
    static let focusBlurMax: Double = 0.55
    /// realLensSweepでレンズを最初に飛ばす位置（手前=近距離側に振ってからlensPositionへ戻す＝サーチ感）。
    /// これがlensPositionと差があるほど実映像のボケが大きい。0.0=最至近。実機で詰める。
    static let focusSweepStart: Float = 0.0

    /// 露出モード（デバッグA/B）。UIから循環切替。
    @Published var exposureMode: ExposureMode = .autoZSL

    let session = AVCaptureSession()
    // 以下、デバイス制御は CameraController+Device.swift（同一モジュールのextension）から触るため internal。
    // モジュール外へは公開されない（外部はSwiftのモジュール境界で遮断）。
    let sessionQueue = DispatchQueue(label: "com.sokihayashi.HAKKO.sessionQueue")
    let photoOutput = AVCapturePhotoOutput()
    /// 触覚エンジンはsessionQueueを共有して全アクセスを直列化する（CoreHapticsハンドラとのデータレース回避）。
    private lazy var haptics = HapticEngine(queue: sessionQueue)
    private var isConfigured = false
    /// torch/ロック操作のため撮影デバイスを保持（sessionQueue上で触る）。
    var videoDevice: AVCaptureDevice?
    /// バースト用のデバイス設定(torch/ロック)を適用したか。teardown成功時のみ下ろす（後始末取りこぼし防止）。
    var burstSetupApplied = false
    /// バースト開始時にexposureModeを固定（途中でモードが変わっても現バーストは一貫）。
    var activeExposureMode: ExposureMode = .autoZSL

    /// 撮影済みショット（画像＋ピント判定メタ・メモリ保持のみ）。UIへはsessionQueue上の内部配列のスナップショットを反映する。
    @Published private(set) var capturedShots: [CapturedShot] = []

    /// AF中の被せ層ボケ量（0=クリア / 1=最大ボケ・UI用・main更新）。bump/overshootで時間駆動する。
    /// ContentViewがこれをプレビュー上の"すりガラス"層のopacityに反映＝AF中のボケを可視化（実際にAF処理中なので嘘でない）。
    /// realLensSweepは実映像をボカすので被せ層は使わず、この値は0のまま。
    @Published private(set) var focusBlur: Double = 0

    /// AF演出モード（デバッグA/B）。UIから循環切替。
    @Published var focusFeel: FocusFeel = .bumpBlur

    /// bump/overshootの被せ層ボケを刻むタイマー（main上でのみ触る）。
    private var focusBlurTimer: Timer?

    /// AFロックの目標レンズ位置（=段①で読んだオートの現位置）。realLensSweepが段②で戻す先。sessionQueue上。
    var focusLockTarget: Float = 0.5

    /// バースト押下時刻（timingログ用・押下→初撮影の総経過を出す）。sessionQueue上。
    private var burstPressTime: TimeInterval = 0

    // 連写状態（sessionQueue上でのみ触る）
    var isBursting = false
    private var burstCount = 0
    private var shotInFlight = false
    /// バースト世代。開始のたびにインクリメントし、遅れて着弾した前バーストの完了を弾く。
    var burstGeneration = 0
    /// 現在飛行中の1枚を発火したときの世代。
    private var inFlightGeneration = 0
    /// sessionQueue上でのみ触る実体。mainへはこれをスナップショットして流す（main.async順序非保証を回避）。
    private var shots: [CapturedShot] = []

    /// デバッグ計測（撮影発火→露出確定→処理完了の内訳）。A/B決着後はBurstMeasurementごと削除可。
    private var measurement = BurstMeasurement()

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
            self.endFocusVisual()          // フォーカス中に停止したらボケを残さない
            self.shotInFlight = false      // session停止で飛行中delegateが来ない可能性に備え自己完結
            // デバイスは同一インスタンスを保持し再start時も再構成されない（isConfiguredガード）。
            // よってstopRunningではcustom露出/WB/AFロック/ZSL無効は自動で戻らない → 停止"前"に明示復元する。
            // （teardownはbeginConfigurationを伴うが、stopRunningの前なら構成変更は交差しない）
            if self.burstSetupApplied {
                self.teardownBurstDeviceSetup()
            } else {
                self.turnTorchOffOnly() // 設定未適用ならtorch消灯だけで足りる
            }
            guard self.session.isRunning else { return }
            self.session.stopRunning()
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

    // MARK: - 連写バースト（torch常時点灯・自動連射・仕様書 §2・§3・§4）

    /// 露出モードを循環切替（デバッグA/B）。UI(main)から呼ぶ。
    func cycleExposureMode() {
        let all = ExposureMode.allCases
        guard let idx = all.firstIndex(of: exposureMode) else { return }
        exposureMode = all[(idx + 1) % all.count]
    }

    /// AF演出モードを循環切替（デバッグA/B・bump/overshoot/real-lens）。UI(main)から呼ぶ。
    func cycleFocusFeel() {
        let all = FocusFeel.allCases
        guard let idx = all.firstIndex(of: focusFeel) else { return }
        focusFeel = all[(idx + 1) % all.count]
    }

    /// シャッターを押したら maxBurst まで自動連射（指離しでは止めない）。UI(main)からexposureModeを読む。
    func startBurst() {
        let mode = exposureMode
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.isBursting else { return }
            self.burstPressTime = ProcessInfo.processInfo.systemUptime // timing: 押下起点
            self.burstGeneration &+= 1        // 世代を進める（遅れて着弾する前バースト完了を弾く）
            self.isBursting = true
            self.burstCount = 0
            self.shotInFlight = false
            self.activeExposureMode = mode     // 現バーストのモードを固定
            self.shots.removeAll()
            self.publishShots()
            self.haptics.prewarmBurstPlayer() // 触覚をwillCaptureで即発火できるよう先に用意
            // customLockedはAF固定＋AE安定待ち(aeSettleDelay)の"間"がある。その間をフォーカス演出(微弱パルス=
            // レンズ駆動の感覚)で埋め、押下→1枚目のラグを「無反応」でなく「ピント合わせ中」に変える（デザインメモ§12）。
            // autoZSLは即発火で待ちが無いのでフォーカス演出は鳴らさない。
            // customLockedはAF固定＋AE安定待ち(aeSettleDelay)の"間"がある。その間を「ピント合わせ中」に翻訳する。
            // 触覚(レンズ駆動パルス)は全AF演出で共通。視覚はfocusFeelで分岐（bump/overshoot=被せ層 / real=実映像）。
            if mode == .customLocked {
                self.haptics.playFocusRamp()
                self.startFocusVisual() // bump/overshootは被せ層を時間駆動。realは実映像なので被せ層は動かさない。
            }
            // torch点灯 +（customLockedなら）露出/AF固定を投げ、"確定"してから1枚目を撮る。
            // これで各バースト1枚目のAF再収束/露出未確定の跨ねを消し、全枚を同一露出＝明るさ均一にする（W-2も解消）。
            let generation = self.burstGeneration
            self.applyBurstDeviceSetup { [weak self] in
                guard let self else { return }
                self.endFocusVisual() // 露出確定＝合焦したのでボケをクリア（この直後に1枚目発光）
                // 確定を待つ間に次のバーストが来た/停止した場合は、この古い確定では撮らない。
                guard self.isBursting, self.burstGeneration == generation else { return }
                self.fireNextShotIfNeeded()
            }
        }
    }

    /// バーストを終了状態にしてデバイス設定を後始末する（撃ち切り/stopの経路から・冪等）。
    private func endBurst() {
        isBursting = false
        endFocusVisual() // フォーカス中に撃ち切り/停止したらボケを残さない
        if burstSetupApplied {
            teardownBurstDeviceSetup()
        }
    }

    /// 内部配列のスナップショットをmainの@Publishedへ反映（sessionQueue上で呼ぶ）。
    private func publishShots() {
        let snapshot = shots
        DispatchQueue.main.async { [weak self] in
            self?.capturedShots = snapshot
        }
    }

    /// フォーカス視覚演出を開始（sessionQueue上から呼ぶ→main駆動）。
    /// bump/overshootは被せ層ボケ量(focusBlur)をaeSettleDelayの間キーフレーム駆動。realは実映像がボケるので被せ層は動かさない。
    private func startFocusVisual() {
        let feel = focusFeel
        guard feel != .realLensSweep else { return } // 実レンズ駆動はapplyBurstDeviceSetup側で実映像をボカす
        DispatchQueue.main.async { [weak self] in
            self?.driveFocusBlur(feel: feel)
        }
    }

    /// フォーカス視覚演出を終了（合焦・停止時）。ボケを0へ。main駆動。
    private func endFocusVisual() {
        DispatchQueue.main.async { [weak self] in
            self?.focusBlurTimer?.invalidate()
            self?.focusBlurTimer = nil
            self?.focusBlur = 0
        }
    }

    /// 被せ層ボケ量を時間で動かす（main上・Timerで刻む）。bump=0→強→0、overshoot=強→抜け→戻る。
    private func driveFocusBlur(feel: FocusFeel) {
        focusBlurTimer?.invalidate()
        let total = CameraController.aeSettleDelay
        let step: TimeInterval = 0.016 // ≈60fps
        let start = ProcessInfo.processInfo.systemUptime
        let maxBlur = CameraController.focusBlurMax
        focusBlurTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1.0, (ProcessInfo.processInfo.systemUptime - start) / total) // 0→1の進捗
            switch feel {
            case .bumpBlur:
                // 山型: sin(π·t) で 0→1→0。合焦点に向かってスッと晴れる。
                self.focusBlur = maxBlur * sin(Double.pi * t)
            case .overshootBlur:
                // 強→行き過ぎ(一瞬抜ける)→少し戻る→合焦。フォーカスサーチ風の揺り戻し。
                let searched = 1.0 - t                        // 強→0のベース
                let wobble = 0.35 * sin(Double.pi * 3 * t)    // 途中で揺らす
                self.focusBlur = max(0, maxBlur * (searched + wobble * (1 - t)))
            case .realLensSweep:
                break
            }
            if t >= 1.0 { self.focusBlur = 0; timer.invalidate(); self.focusBlurTimer = nil }
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
        if burstCount == 1 {
            // timing: 押下→初撮影の総経過。ここまでにtorch点灯/レンズ駆動/露出確定が入る＝ガタつきの内訳を上のログと突合。
            print(String(format: "[HAKKO][timing] first shot fired @+%.0fms after press",
                         (ProcessInfo.processInfo.systemUptime - burstPressTime) * 1000))
        }

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

        measurement.markFire(now: ProcessInfo.processInfo.systemUptime)
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraController: AVCapturePhotoCaptureDelegate {
    /// 露出が確定し実際に撮影される瞬間。ここで触覚を鳴らす＝発光と触覚を同期。
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.measurement.markWillCapture(now: ProcessInfo.processInfo.systemUptime)
            // 世代が変わった前バーストの残弾では触覚を鳴らさない（誤発火・二重発火の防止）。
            guard self.isBursting, self.inFlightGeneration == self.burstGeneration else { return }
            self.haptics.stopChargePlaceholder()      // 充電演出を止め
            self.haptics.playBurstTick()              // 撮影の瞬間に "ガシャッ"（触覚）
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        // 画像データの生成＋ピント判定（重い処理）はコールバックスレッドで。状態更新はsessionQueueに直列化する。
        // lensPositionは撮影時に固定した値（customLockedのみ・autoでは追従するので記録しない）。
        let appliedLens: Float? = activeExposureMode == .customLocked ? Self.lensPosition : nil
        var shot: CapturedShot?
        if let error {
            print("[HAKKO] capture error: \(error)")
        } else if let data = photo.fileDataRepresentation(), let decoded = UIImage(data: data) {
            // EXIFからISO/実効SSを拾う（ピント判定のメタ表示用）。取れなければ nil。
            let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first
            let expSec = exif?[kCGImagePropertyExifExposureTime as String] as? Double
            let shutterDen = (expSec.map { $0 > 0 ? Int((1.0 / $0).rounded()) : nil }) ?? nil
            // 中央領域のラプラシアン分散＝ピントスコア（完全ローカル計算）。
            let sharp = Sharpness.varianceOfLaplacian(decoded)
            shot = CapturedShot(image: decoded, sharpness: sharp, iso: iso,
                                shutterDenominator: shutterDen, lensPosition: appliedLens)
        } else {
            print("[HAKKO] failed to build UIImage from photo")
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.measurement.log(now: ProcessInfo.processInfo.systemUptime,
                                 modeLabel: self.activeExposureMode.label)

            let generation = self.inFlightGeneration
            self.shotInFlight = false
            self.haptics.stopChargePlaceholder() // 念のため（エラー時にwillCaptureが来ないケース）
            // 遅れて着弾した前バーストの1枚は、世代が変わっていれば取り込まない（混入防止）。
            if generation == self.burstGeneration, let shot {
                self.shots.append(shot)
                self.publishShots()
            }
            self.fireNextShotIfNeeded()
        }
    }
}
