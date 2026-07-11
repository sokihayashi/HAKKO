import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraController()

    var body: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            VStack {
                Spacer()
                // Stage 0: シャッターボタン（見た目のみ・機能なし）
                ShutterButton(action: {})
                    .padding(.bottom, 40)
            }
        }
        .background(Color.black)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }
}

/// 丸いシャッターボタン。Stage 1 で連写バーストを紐づける。
private struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 78, height: 78)
                Circle()
                    .fill(Color.white)
                    .frame(width: 64, height: 64)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
