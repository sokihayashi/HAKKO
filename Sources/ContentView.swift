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

                Spacer()
                ShutterButton(
                    onPressStart: { camera.startBurst() },
                    onPressEnd: { camera.stopBurst() }
                )
                .padding(.bottom, 40)
            }
        }
        .background(Color.black)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

/// 丸いシャッターボタン。長押しで連写バースト（押下で開始・離すで停止）。
private struct ShutterButton: View {
    let onPressStart: () -> Void
    let onPressEnd: () -> Void

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
        // minimumDistance: 0 で「触れた瞬間＝押下開始」を取る。指を離すと onEnded。
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isPressed else { return }
                    isPressed = true
                    onPressStart()
                }
                .onEnded { _ in
                    isPressed = false
                    onPressEnd()
                }
        )
    }
}

#Preview {
    ContentView()
}
