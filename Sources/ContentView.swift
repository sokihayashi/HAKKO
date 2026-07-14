import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()
    /// タップで拡大表示中の画（画のA/B判断用）。nilなら未表示。
    @State private var previewImage: UIImage?

    /// 現バーストで最もシャープなスコア（best表示用）。無ければ nil。
    private var bestSharpness: Double? {
        camera.capturedShots.compactMap(\.sharpness).max()
    }

    /// このショットがバースト内で最高スコアか（同点は最初の1枚のみtrue）。
    private func isBest(_ shot: CapturedShot) -> Bool {
        guard let best = bestSharpness, let s = shot.sharpness, s == best else { return false }
        return camera.capturedShots.first { $0.sharpness == best }?.id == shot.id
    }

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            // AF中のボケ演出: focusBlur(0〜1)に応じてプレビュー上に"すりガラス"層をopacity駆動で重ねる。
            // bump=0→強→0 / overshoot=強→抜け→合焦 でボケ量が動く（ピントが合っていく感）。real-lensは実映像が
            // ボケるのでこの層は0のまま。AVCaptureVideoPreviewLayerは.blur対象外なので被せ層でボケ越しを作る。
            if camera.focusBlur > 0.001 {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(camera.focusBlur)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            VStack {
                // Stage 1: 連写が効いているか実機で目視するための枚数表示（暫定UI）。
                Text("\(camera.capturedShots.count) / \(CameraController.maxBurst)")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.top, 12)

                // デバッグA/B: 露出モード＆AF演出（タップで循環切替）。実機で見比べて1本化する。
                HStack(spacing: 8) {
                    Button(action: { camera.cycleExposureMode() }) {
                        Text(camera.exposureMode.label)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    // AF演出A/B（bump/overshoot/real-lens）。customLockedのフォーカス"間"の見せ方を比較。
                    Button(action: { camera.cycleFocusFeel() }) {
                        Text(camera.focusFeel.label)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.4), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)

                Spacer()

                // 撮ったバーストのサムネ一覧（横スクロール）。タップで拡大＝画のA/B判断用。
                // 各サムネにシャープネススコア＋ISO/実SS/lensPositionをオーバーレイ（ピント定量チューニング/§8.9続き）。
                if !camera.capturedShots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(camera.capturedShots) { shot in
                                ShotThumbnail(shot: shot, isBest: isBest(shot))
                                    .onTapGesture { previewImage = shot.image }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: 116)
                    .padding(.bottom, 8)
                }

                // 1回押したら maxBurst まで自動連射（指離しでは止めない）。
                ShutterButton { camera.startBurst() }
                    .padding(.bottom, 40)
            }

            // 拡大表示（タップで閉じる）。画をしっかり見比べるための最小ビューア。
            if let previewImage {
                Color.black.opacity(0.92).ignoresSafeArea()
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .ignoresSafeArea()
                    .onTapGesture { self.previewImage = nil }
            }
        }
        .background(Color.black)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

/// サムネ1枚＋ピント判定メタ（sharpness/ISO/実SS/lens）。best（最高シャープ）は枠を光らせる。
/// ピントのlensPositionチューニング用のデバッグUI（§8.9続き・実機で数値を見ながら詰める）。
private struct ShotThumbnail: View {
    let shot: CapturedShot
    let isBest: Bool

    var body: some View {
        VStack(spacing: 3) {
            Image(uiImage: shot.image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isBest ? Color.green : Color.white.opacity(0.15),
                                lineWidth: isBest ? 2.5 : 1)
                )

            // sharpスコア（大きいほどピントが合っている）。bestは緑。
            Text(sharpText)
                .font(.system(size: 10, weight: isBest ? .bold : .regular, design: .monospaced))
                .foregroundColor(isBest ? .green : .white)
            // ISO / 実SS / lensPosition。
            Text(metaText)
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(4)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sharpText: String {
        guard let s = shot.sharpness else { return "sharp:--" }
        return "sharp:\(Int(s.rounded()))"
    }

    private var metaText: String {
        let iso = shot.iso.map { "ISO\($0)" } ?? "ISO?"
        let ss = shot.shutterDenominator.map { "1/\($0)" } ?? "1/?"
        let lens = shot.lensPosition.map { String(format: "L%.2f", $0) } ?? "auto"
        return "\(iso) \(ss) \(lens)"
    }
}

/// 丸いシャッターボタン。押すと連写バーストが発動し、maxBurstまで自動で撃ち切る。
private struct ShutterButton: View {
    let onTrigger: () -> Void

    @State private var isPressed = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white, lineWidth: 4)
                .frame(width: 78, height: 78)
            Circle()
                .fill(Color.white)
                .frame(width: 64, height: 64)
                .scaleEffect(isPressed ? 0.88 : 1.0)
                .animation(.easeOut(duration: 0.08), value: isPressed)
        }
        // 押下でトリガ（離しは連射に影響しない）。押下フィードバックのみジェスチャで取る。
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    onTrigger()
                }
                .onEnded { _ in isPressed = false }
        )
    }
}

#Preview {
    ContentView()
}
