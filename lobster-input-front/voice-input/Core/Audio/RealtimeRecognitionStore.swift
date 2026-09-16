import Foundation

enum RealtimeRecognitionStore {
    private static let key = "realtime_recognition_enabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            Task { @MainActor in
                DebugTrace.log("RealtimeRecognitionStore.isEnabled changed -> \(newValue)")
                if newValue {
                    await AudioRecorder.shared.releaseWarmEngineForRealtimeStart()
                    await RealtimeAudioStreamer.shared.prewarmIfNeeded()
                } else {
                    await RealtimeAudioStreamer.shared.shutdownWarmEngine()
                    await AudioRecorder.shared.prewarmIfNeeded()
                }
            }
        }
    }
}
