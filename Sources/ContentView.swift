import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            VStack {
                // Stage 1: 連写が効いているか実機で目視するための枚数表示（暫定UI）。
                Text("\(camera.capturedImages.count) / \(CameraController.maxBurst)")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.4), in: Capsule())
                    .padding(.top, 12)

                // デバッグA/B: 露出モード（タップで循環切替）。meterスパイクが消えるか比較。
                Button(action: { camera.cycleExposureMode() }) {
                    Text(camera.exposureMode.label)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)

                Spacer()
                // 1回押したら maxBurst まで自動連射（指離しでは止めない）。
                ShutterButton { camera.startBurst() }
                    .padding(.bottom, 40)
            }
        }
        .background(Color.black)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
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
