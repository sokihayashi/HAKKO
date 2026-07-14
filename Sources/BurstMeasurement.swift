import Foundation

/// バースト撮影のタイミング計測（デバッグA/B用）。sessionQueue上でのみ触る前提。
/// 撮影発火→露出確定(meter) と 露出確定→処理完了(capture) の内訳を出す。
/// ※A/B（継続オートAE vs custom固定）でmeterスパイクが消えるか比較する用途。決着後はこのファイルごと削除できる。
struct BurstMeasurement {
    private var fireTime: TimeInterval = 0
    /// willCapture未着(エラー枚)を検出可能に（計測交差防止）。0なら未着。
    private var willCaptureTime: TimeInterval = 0

    /// 1枚の撮影を発火した瞬間を記録（willCaptureTimeはリセット）。
    mutating func markFire(now: TimeInterval) {
        fireTime = now
        willCaptureTime = 0
    }

    /// 露出確定（willCapturePhoto）の瞬間を記録。
    mutating func markWillCapture(now: TimeInterval) {
        willCaptureTime = now
    }

    /// 処理完了時にログを出す。willCapture未着なら total のみ、着いていれば meter/capture 内訳も。
    func log(now: TimeInterval, modeLabel: String) {
        let totalMs = (now - fireTime) * 1000
        if willCaptureTime > 0 {
            let meterMs = (willCaptureTime - fireTime) * 1000
            let captureMs = (now - willCaptureTime) * 1000
            print(String(format: "[HAKKO][measure] mode=%@ meter=%.0fms capture=%.0fms total=%.0fms",
                         modeLabel, meterMs, captureMs, totalMs))
        } else {
            print(String(format: "[HAKKO][measure] mode=%@ (no willCapture) total=%.0fms",
                         modeLabel, totalMs))
        }
    }
}
