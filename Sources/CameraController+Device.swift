import AVFoundation

/// CameraControllerのデバイス制御（torch/露出/AF/WBロック・ZSL）。sessionQueue上でのみ呼ぶ前提。
/// 発光=torch常時点灯、customLocked=速SS固定＋ISO補正＋パンフォーカス の実機A/B確定ロジック（デザインメモ§8.9）。
extension CameraController {
    /// torchだけ消す（stop経路用・session構成変更を伴わない軽い後始末）。sessionQueue上。
    func turnTorchOffOnly() {
        guard let device = videoDevice, device.hasTorch, device.torchMode != .off else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = .off
        } catch {
            print("[HAKKO] stop torch off failed: \(error)")
        }
    }

    /// ZSL/responsiveCapture/fastCapturePrioritizationの有効/無効を切り替える（session構成変更・iOS17+）。
    /// custom露出はZSLと排他なので、customLockedバースト時は無効化する。依存: responsiveはZSL必須、fastはresponsive必須。
    func applyZSL(enabled: Bool) {
        guard #available(iOS 17.0, *) else { return }
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = enabled }
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = enabled && photoOutput.isZeroShutterLagEnabled
        }
        if photoOutput.isFastCapturePrioritizationSupported {
            photoOutput.isFastCapturePrioritizationEnabled = enabled && photoOutput.isResponsiveCaptureEnabled
        }
    }

    /// バースト開始時のデバイス設定（sessionQueue上・撮影中は触らない＝-11830回避）。完了で `onReady` を呼ぶ。
    /// autoZSL: torch点灯のみ→即onReady。
    /// customLocked: torch点灯＋AF/WB固定→AE安定待ち→露出custom固定の"確定"（completionHandler）でonReady。
    ///   これで各バースト1枚目のAF再収束/露出未確定の跨ねを消し、全枚を同一露出＝明るさ均一にする（W-2解消）。
    /// ※setTorchModeOn直後のisTorchActiveチェックは点灯のハード非同期遅延で誤検出するため行わない（真の失敗はthrowで捕まる）。
    func applyBurstDeviceSetup(onReady: @escaping () -> Void) {
        guard let device = videoDevice, device.hasTorch, device.isTorchModeSupported(.on) else { onReady(); return }

        // autoZSL: torch点灯だけして即発火（待つ確定が無い）。
        guard activeExposureMode == .customLocked else {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() } // throw時もロック解除を保証
                try device.setTorchModeOn(level: Self.torchLevel)
                burstSetupApplied = true
            } catch {
                print("[HAKKO] burst device setup failed: \(error)")
            }
            onReady()
            return
        }

        // customLocked: ZSL(custom露出と排他)を無効化してから固定する。session構成変更はlockとは別経路。
        session.beginConfiguration()
        applyZSL(enabled: false)
        session.commitConfiguration()

        // 段①: torch点灯＋WB固定＋AFロック。露出はまだ継続オートのままtorch下の明るさをAEに測らせる（W-2対策）。
        // ピント: 固定値の決め打ちをやめ、プレビューのcontinuousAutoFocusが"今合わせている位置"を採用する。
        //   → 撮影のピントがプレビューの見え方と一致（固定0.5だと被写体距離とズレて全体が甘くなる問題の解）。
        let t0 = ProcessInfo.processInfo.systemUptime
        // ロック直前の現在レンズ位置（=オートが合わせた位置）。realLensSweepはここから手前へ一旦振り、段②で戻す。
        let autoLens = device.lensPosition
        focusLockTarget = autoLens // 段②で戻す先＝オートが合わせた現位置（realLensSweep用に保持）
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() } // setTorchOn/setFocusLockedのthrowでもロック解除を保証（段②で再lockするため必須）
            try device.setTorchModeOn(level: Self.torchLevel)
            print(String(format: "[HAKKO][timing] torch on @+%.0fms", (ProcessInfo.processInfo.systemUptime - t0) * 1000))
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
            if device.isFocusModeSupported(.locked) {
                if device.isLockingFocusWithCustomLensPositionSupported {
                    // realLensSweep: まず手前(focusSweepStart)へ振る＝実映像がボケる。段②でautoLensへ戻し合焦。
                    // 他モード: オートが合わせた現位置(autoLens)へ直接固定（実映像は動かさず被せ層でボケ演出）。
                    let startPos = focusFeel == .realLensSweep ? Self.focusSweepStart : autoLens
                    device.setFocusModeLocked(lensPosition: startPos, completionHandler: nil)
                    print(String(format: "[HAKKO][timing] lens set %.2f (auto=%.2f) @+%.0fms",
                                 startPos, autoLens, (ProcessInfo.processInfo.systemUptime - t0) * 1000))
                } else {
                    device.focusMode = .locked
                }
            }
            burstSetupApplied = true
        } catch {
            print("[HAKKO] burst device setup (stage1) failed: \(error)")
            // 段①で無効化したZSLを戻す（このバーストは露出固定に進まないので排他制約は無い）。
            session.beginConfiguration()
            applyZSL(enabled: true)
            session.commitConfiguration()
            onReady()
            return
        }

        // 段②: AEがtorch光へ馴染むのを待ってから、その値を基に露出custom固定。確定(completion)で発火。
        // ※将来カメラ切替(前面/背面)を足したら、待機中にvideoDeviceが差し替わり得るのでキャプチャしたdeviceが
        //   古くなる。現状はvideoDevice不変(isConfiguredで再構成しない)ので顕在化しない。切替実装時はここで再取得を。
        let generation = burstGeneration
        sessionQueue.asyncAfter(deadline: .now() + Self.aeSettleDelay) { [weak self] in
            guard let self else { return }
            guard self.isBursting, self.burstGeneration == generation else { return } // 待つ間に停止/再開したら破棄
            self.lockCustomExposure(device: device, onReady: onReady)
        }
    }

    /// torch下で安定したAE値を基に露出をcustom固定する（SSを速く＋暗さをISO補正）。完了で onReady。sessionQueue上。
    func lockCustomExposure(device: AVCaptureDevice, onReady: @escaping () -> Void) {
        guard device.isExposureModeSupported(.custom) else {
            print("[HAKKO] custom exposure not supported; falling back to auto")
            onReady()
            return
        }
        let fmt = device.activeFormat
        // 元のオート露出量 = SS × ISO。SSをtargetShutterに縮めた分、ISOを持ち上げて明るさを保つ。
        // torch下で馴染んだ後のcurDur/curISOを使う（段②で待った効果＝1枚目も正しい露出）。
        let curDur = CMTimeGetSeconds(device.exposureDuration)
        let curISO = device.iso
        let target = clampTime(CMTime(seconds: Self.targetShutter, preferredTimescale: 1_000_000),
                               fmt.minExposureDuration, fmt.maxExposureDuration)
        let targetSec = CMTimeGetSeconds(target)
        let ratio = (curDur > 0 && targetSec > 0) ? Float(curDur / targetSec) : 1.0
        let want = curISO * ratio
        let iso = min(max(want, fmt.minISO), fmt.maxISO)
        if want > fmt.maxISO {
            // ISO頭打ち＝これ以上明るくできず暗い写真になる（薄暗いシーンで頻発）。実機チューニングの材料。
            print(String(format: "[HAKKO] ISO saturated: want=%.0f max=%.0f underexposed=%.1fx",
                         want, fmt.maxISO, want / fmt.maxISO))
        }
        do {
            try device.lockForConfiguration()
            // realLensSweep: 段①で手前へ振ったレンズを、ここでオートが合わせた現位置(focusLockTarget)へ戻す
            //   ＝実映像が手前ボケ→（プレビューで合っていた位置に）合焦と動く。他モードは段①で固定済み。
            if focusFeel == .realLensSweep,
               device.isFocusModeSupported(.locked), device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: focusLockTarget, completionHandler: nil)
            }
            // completionHandlerは設定がセンサーに反映された"確定"時刻に呼ばれる。ここで1枚目を撮れば
            // 露出未確定の跨ねが出ず、以降の全枚も同一露出＝明るさ均一。
            let tExp = ProcessInfo.processInfo.systemUptime
            device.setExposureModeCustom(duration: target, iso: iso) { [weak self] _ in
                guard let self else { return }
                print(String(format: "[HAKKO][timing] exposure confirmed @+%.0fms after lock",
                             (ProcessInfo.processInfo.systemUptime - tExp) * 1000))
                self.sessionQueue.async { onReady() }
            }
            device.unlockForConfiguration()
        } catch {
            print("[HAKKO] custom exposure lock failed: \(error)")
            onReady()
        }
    }

    /// バースト終了時の後始末（sessionQueue上）。torch消灯＋(customLockedなら)露出/WB/AFを継続オートへ戻す。
    /// 成功時のみフラグを下ろす。custom無効化したZSLも再有効化。
    func teardownBurstDeviceSetup() {
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
    func clampTime(_ v: CMTime, _ lo: CMTime, _ hi: CMTime) -> CMTime {
        if CMTimeCompare(v, lo) < 0 { return lo }
        if CMTimeCompare(v, hi) > 0 { return hi }
        return v
    }
}
