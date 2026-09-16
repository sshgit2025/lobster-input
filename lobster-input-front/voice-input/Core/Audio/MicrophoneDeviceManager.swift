import Foundation
import AudioToolbox
import Combine

struct MicrophoneDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let deviceID: AudioDeviceID
    let inputChannelCount: Int
    let isDefault: Bool
}

@MainActor
final class MicrophoneDeviceManager: ObservableObject {
    static let shared = MicrophoneDeviceManager()

    @Published private(set) var devices: [MicrophoneDevice] = []
    @Published private(set) var selectedDeviceUID: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshFailureReason: String?

    private let selectedDeviceKey = "selected_microphone_device_uid"
    private let deviceService = AudioInputDeviceService.shared
    private var snapshot = AudioInputDeviceSnapshot.empty

    private init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: selectedDeviceKey)
        deviceService.onSnapshotChanged = { [weak self] snapshot in
            self?.apply(snapshot)
        }
        apply(deviceService.currentSnapshot(requestRefreshIfStale: "manager init"))
        deviceService.updateSelectedDeviceUID(selectedDeviceUID, reason: "manager init selected uid")
    }

    var selectedDeviceName: String {
        guard let selectedDeviceUID else { return defaultSelectionTitle }
        return devices.first { $0.id == selectedDeviceUID }?.name ?? defaultSelectionTitle
    }

    var defaultSelectionTitle: String {
        L10n.microphoneAutoDetect(snapshot.defaultInputDeviceName)
    }

    func refreshDevices() {
        deviceService.requestRefresh(reason: "manual refresh")
        apply(deviceService.currentSnapshot())
    }

    func selectDefault(rebuildRecorder: Bool = true) {
        selectedDeviceUID = nil
        UserDefaults.standard.removeObject(forKey: selectedDeviceKey)
        deviceService.updateSelectedDeviceUID(nil, reason: "select default microphone")
        if rebuildRecorder {
            rebuildRecorderForDeviceChange(reason: "select default microphone")
        }
    }

    func selectDevice(uid: String) {
        selectedDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: selectedDeviceKey)
        deviceService.updateSelectedDeviceUID(uid, reason: "select microphone uid=\(uid)")
        rebuildRecorderForDeviceChange(reason: "select microphone uid=\(uid)")
    }

    func recordingInputDeviceResolution(reason: String) -> AudioInputDeviceResolution {
        deviceService.currentResolution(requestRefreshIfStale: reason)
    }

    private func apply(_ snapshot: AudioInputDeviceSnapshot) {
        self.snapshot = snapshot
        devices = snapshot.devices
        isRefreshing = snapshot.isRefreshing
        refreshFailureReason = snapshot.refreshFailureReason
        if selectedDeviceUID == nil, snapshot.selectedDeviceUID != nil {
            selectedDeviceUID = snapshot.selectedDeviceUID
        }
        // 不再因「当前快照里找不到所选设备」而自动清除用户的持久化选择。
        // 旧逻辑会被两类瞬时空快照误触发：(1) 冷启动时设备尚未异步枚举完成（快照 devices 为空），
        // (2) 睡眠唤醒 / USB 重枚举导致设备短暂消失。两者都会把用户选的非默认麦克风永久抹掉、
        // 且设备回来后不恢复。现保留持久化 UID：录音时若所选设备不在则由解析逻辑回退系统默认，
        // 设备重新出现后自动恢复为用户选择。只有用户显式选择「默认」(selectDefault) 才清除持久化。
    }

    private func rebuildRecorderForDeviceChange(reason: String) {
        if RealtimeRecognitionStore.isEnabled {
            RealtimeAudioStreamer.shared.markInputDeviceTransitionStarted(reason: reason)
        } else {
            AudioRecorder.shared.markInputDeviceTransitionStarted(reason: reason)
        }
        Task { await AudioRecorder.shared.rebuildForInputDeviceChange() }
    }
}
