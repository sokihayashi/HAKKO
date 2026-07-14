import UIKit
import Accelerate

/// 撮影1コマ＋ピント判定用メタ情報（デザインメモ§8.9続き・lensPosition定量チューニング用）。
/// 画像は外部送信しない（完全ローカル/仕様書§1）。sharpnessは端末内で計算する。
struct CapturedShot: Identifiable {
    let id = UUID()
    let image: UIImage
    /// 中央領域のラプラシアン分散（ピントの合い具合。大きいほどシャープ）。計算失敗時は nil。
    let sharpness: Double?
    /// 撮影時のISO感度（EXIF由来。取れなければ nil）。
    let iso: Int?
    /// 実効シャッター速度の分母（1/xのx。取れなければ nil）。例: 500 なら 1/500s。
    let shutterDenominator: Int?
    /// 適用中のlensPosition（customLockedのみ有効。autoZSLでは nil）。
    let lensPosition: Float?
}

/// ピント評価: ラプラシアン分散（Variance of Laplacian）。
/// 画像のエッジ量を測る定番手法。ピントが合う＝輪郭くっきり＝2次微分のばらつき大＝分散が高い。
/// 中央領域だけを見る（パンフォーカスの主要被写体は中央想定・周辺のボケに引きずられない）。
/// 完全ローカル（vImage/Accelerate）・追加ライブラリなし。
enum Sharpness {
    /// 中央領域を切り出してラプラシアン分散を返す。失敗時 nil。
    /// - centerFraction: 中央の切り出し割合（0.5＝中央50%）。
    /// - downscaleWidth: 計算用の縮小幅（速度のため。ピント判定は低解像で十分）。
    static func varianceOfLaplacian(_ image: UIImage,
                                    centerFraction: CGFloat = 0.5,
                                    downscaleWidth: CGFloat = 256) -> Double? {
        guard let cg = image.cgImage else { return nil }

        // 中央領域を切り出し（パンフォーカスの主役＝中央を評価）。
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let cw = w * centerFraction, ch = h * centerFraction
        let crop = CGRect(x: (w - cw) / 2, y: (h - ch) / 2, width: cw, height: ch)
        guard let cropped = cg.cropping(to: crop) else { return nil }

        // グレースケール8bitへ縮小描画（計算量削減＋色ノイズをピント指標から除外）。
        let scale = downscaleWidth / cw
        let dw = max(8, Int(cw * scale)), dh = max(8, Int(ch * scale))
        let gray = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: dw, height: dh, bitsPerComponent: 8,
                                  bytesPerRow: dw, space: gray,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: dw, height: dh))
        guard let buf = ctx.data else { return nil }

        let count = dw * dh
        var src = [Float](repeating: 0, count: count)
        let bytes = buf.bindMemory(to: UInt8.self, capacity: count)
        vDSP_vfltu8(bytes, 1, &src, 1, vDSP_Length(count))

        // 3x3 ラプラシアンカーネル（4近傍）。エッジ強度を出す。
        var laplacian = [Float](repeating: 0, count: count)
        var kernel: [Float] = [ 0, -1,  0,
                               -1,  4, -1,
                                0, -1,  0]
        vDSP_imgfir(src, vDSP_Length(dh), vDSP_Length(dw), &kernel, &laplacian, 3, 3)

        // 分散 = E[x^2] - E[x]^2。
        var mean: Float = 0
        vDSP_meanv(laplacian, 1, &mean, vDSP_Length(count))
        var meanSquare: Float = 0
        vDSP_measqv(laplacian, 1, &meanSquare, vDSP_Length(count))
        let variance = Double(meanSquare - mean * mean)
        return variance.isFinite ? variance : nil
    }
}
