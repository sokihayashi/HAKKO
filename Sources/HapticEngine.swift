import CoreHaptics

/// Stage 1: 連写の"食感"を作る触覚エンジン。
///
/// 仕様書 §3 の絶対ルール:
/// - 連写は `.hapticTransient` の高速連打で作る。
/// - `.hapticContinuous`（持続振動）は連写に使わない（このクラスでは一切生成しない）。
///   持続振動を使ってよいのは起動シーケンスのみ（Stage 4）。
final class HapticEngine {
    /// 連写1発ごとの触覚パラメータ。宋其が実機で追い込めるよう定数で切り出す（仕様書 §3 / 段階プロンプト集）。
    /// intensity: 強さ（0.0–1.0）、sharpness: 鋭さ（0.0=鈍い/1.0=硬く鋭い）。
    /// "ガシャ"の食感は高めのsharpnessで出す。
    static var burstIntensity: Float = 0.9
    static var burstSharpness: Float = 0.8

    /// チャージ完了などの単発合図用（Stage 3で使用）。今は連写と同じ既定値。
    static var singleIntensity: Float = 1.0
    static var singleSharpness: Float = 0.7

    private var engine: CHHapticEngine?
    private let supportsHaptics: Bool
    /// 全プロパティアクセスを直列化するキュー。CameraControllerのsessionQueueを共有し、
    /// 触覚発火に余計なdispatchを挟まない（最速発火）。CoreHapticsのハンドラも必ずこのキューへ載せる。
    private let queue: DispatchQueue
    /// エンジンが稼働中か（stoppedHandler/resetHandlerで更新）。毎回start()を呼ぶ遅延を避けるためのフラグ。
    private var isRunning = false

    // 事前生成した連写用プレイヤー。makePlayerを撮影のたびに呼ぶ遅延を消し、触覚を最速で発火する。
    private var burstPlayer: CHHapticPatternPlayer?
    private var burstPlayerIntensity: Float = .nan  // 生成時のパラメータ。変わったら作り直す。
    private var burstPlayerSharpness: Float = .nan

    /// queue: 呼び出し側(CameraController)のsessionQueueを渡す。全アクセスをこのキューに直列化する。
    init(queue: DispatchQueue) {
        self.queue = queue
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else {
            print("[HAKKO] haptics unsupported — silent fallback")
            return
        }
        do {
            let engine = try CHHapticEngine()
            // 連写中にアイドル自動停止されると次弾が無音化するため、自動シャットダウンを切る。
            engine.isAutoShutdownEnabled = false
            // 割り込み等でリセットされたら自動復帰＋プレイヤー作り直し。ハンドラはCoreHaptics内部スレッドから
            // 呼ばれるため、状態変更は必ずqueueへ載せてplayBurstTickとのデータレースを防ぐ。
            engine.resetHandler = { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    self.burstPlayer = nil // リセットでプレイヤーは無効化される
                    do { try self.engine?.start(); self.isRunning = true } catch { self.isRunning = false }
                }
            }
            // バックグラウンド化・割り込み等で停止した場合。状態変更をqueueへ直列化。
            engine.stoppedHandler = { [weak self] reason in
                print("[HAKKO] haptic engine stopped: \(reason.rawValue)")
                self?.queue.async {
                    guard let self else { return }
                    self.isRunning = false
                    self.burstPlayer = nil
                }
            }
            try engine.start()
            self.engine = engine
            self.isRunning = true
        } catch {
            print("[HAKKO] failed to start haptic engine: \(error)")
        }
    }

    /// バースト初弾の触覚が遅れないよう、連写開始前にプレイヤーを先に生成しておく（queue上で呼ぶ）。
    /// 初弾のmakePlayer遅延で「触覚より光が先」になる逆転を潰す。
    func prewarmBurstPlayer() {
        guard engine != nil else { return }
        ensureRunning()
        ensureBurstPlayer()
    }

    /// 連写1枚ぶんの離散パルス。撮影発火に同期して1発ずつ呼ぶ（queue上で呼ぶ前提）。
    /// 事前生成プレイヤーを使い回し、makePlayerの遅延なしで最速発火する（触覚を同期の基準にするため）。
    func playBurstTick() {
        guard let engine else { return } // 非対応機 or 起動失敗時は無音
        ensureRunning()
        ensureBurstPlayer()
        do {
            try burstPlayer?.start(atTime: CHHapticTimeImmediate)
        } catch {
            // 1発の欠落は連写の食感に響くため、エンジン復帰＋プレイヤー再生成で1回だけリトライ。
            print("[HAKKO] burst haptic start failed, retrying: \(error)")
            burstPlayer = nil
            isRunning = false
            ensureRunning()
            ensureBurstPlayer()
            try? burstPlayer?.start(atTime: CHHapticTimeImmediate)
        }
    }

    /// burstPlayerが未生成 or パラメータ変更済みなら作り直す（queue上で呼ぶ）。
    private func ensureBurstPlayer() {
        if burstPlayer == nil
            || burstPlayerIntensity != Self.burstIntensity
            || burstPlayerSharpness != Self.burstSharpness {
            burstPlayer = makeTransientPlayer(intensity: Self.burstIntensity, sharpness: Self.burstSharpness)
            burstPlayerIntensity = Self.burstIntensity
            burstPlayerSharpness = Self.burstSharpness
        }
    }

    /// 単発の合図（Stage 3のチャージ完了などで使用）。都度生成でよい（頻度が低い）。
    func playSingle() {
        guard let engine else { return }
        ensureRunning()
        guard let player = makeTransientPlayer(intensity: Self.singleIntensity, sharpness: Self.singleSharpness) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    // MARK: - 充電演出プレースホルダ（コマ間の測光/充電待ちを埋める）
    // 本格的な写ルンです系昇圧音（低→高スイープ）はStage3で AVAudioEngine 合成する。
    // ここでは器だけ。仕様書§3: .hapticContinuous は連写に使わないため、充電"間"でも触覚は載せず音のみの想定。

    /// コマ間の充電演出を開始（queue上で呼ぶ）。現状はプレースホルダ（ログのみ）。
    func startChargePlaceholder() {
        // TODO(Stage3): 昇圧スイープ音の再生開始。
    }

    /// 充電演出を停止（queue上で呼ぶ）。実発光の瞬間 or 撮影完了で呼ぶ。
    func stopChargePlaceholder() {
        // TODO(Stage3): 昇圧スイープ音の停止。
    }

    /// エンジンが止まっていれば復帰（稼働中は何もしない＝毎回start()する遅延を避ける）。
    private func ensureRunning() {
        guard let engine, !isRunning else { return }
        do { try engine.start(); isRunning = true } catch { print("[HAKKO] haptic re-start failed: \(error)") }
    }

    /// `.hapticTransient` 単発のプレイヤーを生成。
    private func makeTransientPlayer(intensity: Float, sharpness: Float) -> CHHapticPatternPlayer? {
        guard let engine else { return nil }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0
        )
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            return try engine.makePlayer(with: pattern)
        } catch {
            print("[HAKKO] failed to make transient player: \(error)")
            return nil
        }
    }
}
