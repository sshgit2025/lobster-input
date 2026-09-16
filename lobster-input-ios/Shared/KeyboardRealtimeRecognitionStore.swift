import Foundation

enum KeyboardRealtimeRecognitionStore {
    private static let key = "ime_realtime_recognition_enabled"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: APIConfig.appGroupID) ?? .standard
    }

    static var isEnabled: Bool {
        get { defaults.bool(forKey: key) }
        set {
            defaults.set(newValue, forKey: key)
            defaults.synchronize()
        }
    }
}
