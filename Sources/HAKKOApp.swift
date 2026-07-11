import SwiftUI
import CoreHaptics

@main
struct HAKKOApp: App {
    init() {
        // Stage 0: Core Haptics 対応判定を起動時にログ出力（仕様書 §3）
        let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        print("[HAKKO] supportsHaptics = \(supportsHaptics)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
