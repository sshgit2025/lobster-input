/// DeviceIdentity.swift
/// 设备唯一标识与硬件指纹工具，用于注册时防止批量虚拟机绑定。
/// 所有方法为纯静态函数，无状态，可在任意上下文调用。
import Foundation
import IOKit
import CryptoKit

enum DeviceIdentity {

    /// 设备唯一标识，用于注册限制计数。
    /// 后端要求 device_id 为 SHA-256 的 64 位小写十六进制字符串。
    static func deviceID() -> String {
        let rawID: String
        let platformExpert = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        defer { IOObjectRelease(platformExpert) }
        if platformExpert != 0,
           let uuid = IORegistryEntryCreateCFProperty(
               platformExpert,
               "IOPlatformUUID" as CFString,
               kCFAllocatorDefault, 0
           )?.takeRetainedValue() as? String {
            rawID = uuid
        } else {
            rawID = UUID().uuidString
        }
        return sha256Hex(rawID)
    }

    /// 硬件指纹：组合多个硬件属性后 SHA-256 哈希。
    /// 组合项：IOPlatformUUID + CPU 物理核心数 + 物理内存大小 + 主硬盘序列号。
    /// 任一项无法单独伪造 → 大幅提高虚拟机/工具批量伪造难度。
    static func hardwareFingerprint() -> String {
        let components: [String] = [
            deviceID(),
            "\(ProcessInfo.processInfo.processorCount)",
            "\(ProcessInfo.processInfo.physicalMemory)",
            diskSerialNumber(),
        ]
        let raw = components.joined(separator: "|")
        return sha256Hex(raw)
    }

    /// 从 IOKit 读取主硬盘序列号
    private static func diskSerialNumber() -> String {
        let matching = IOServiceMatching("IOBlockStorageDevice") as! NSMutableDictionary
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return "unknown_disk"
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            var cfProps: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &cfProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = cfProps?.takeRetainedValue() as? [String: Any],
                  let deviceChars = props["Device Characteristics"] as? [String: Any],
                  let serial = deviceChars["Serial Number"] as? String,
                  !serial.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            return serial.trimmingCharacters(in: .whitespaces)
        }
        return "unknown_disk"
    }

    private static func sha256Hex(_ value: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
