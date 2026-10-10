import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 灰度发布（微信式：按设备稳定分桶，先小比例再全量）

/// 灰度策略模型（update/index.json）
struct AppUpdateIndex: Codable, Sendable {
    var stableVersion: String
    var stableIpa: String
    var gray: GrayEntry?

    struct GrayEntry: Codable, Sendable {
        var enabled: Bool
        /// 灰度比例 0-100（设备分桶命中概率）
        var percent: Int
        var version: String
        var ipa: String
        var notes: String?
    }
}

/// 解析结果
struct AppUpdateResolved: Sendable {
    let version: String
    let ipa: URL?
    let notes: String?
    let isGray: Bool
}

/// 模块灰度策略（modules/index.json 条目内可选 gray 字段）
struct ModuleGrayPolicy: Codable, Sendable {
    var percent: Int
}

/// 灰度判定工具：设备稳定分桶（identifierForVendor 哈希，跨会话稳定）
enum UpdatePolicy {

    /// 更新索引地址（仓库里；灰度版只出现在这里，不进 GitHub Release）
    static let indexURL = "https://raw.githubusercontent.com/nmn999999999/LumenAI/main/update/index.json"

    /// 设备分桶号（0-99，稳定）
    static func deviceBucket() -> Int {
        let deviceID: String
        #if canImport(UIKit)
        deviceID = UIDevice.current.identifierForVendor?.uuidString ?? "localai-default-device"
        #else
        deviceID = "localai-default-device"
        #endif
        // FNV-1a 稳定哈希
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in deviceID.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % 100)
    }

    /// 设备是否命中灰度（开关强制加入，或分桶命中）
    static func inGray(percent: Int, optIn: Bool) -> Bool {
        if percent <= 0 { return false }
        if optIn { return true }
        return deviceBucket() < min(percent, 100)
    }

    /// 解析对当前设备生效的 App 更新
    static func resolveAppUpdate(_ index: AppUpdateIndex, optInGray: Bool) -> AppUpdateResolved {
        if let gray = index.gray, gray.enabled, !gray.version.isEmpty,
           inGray(percent: gray.percent, optIn: optInGray) {
            return AppUpdateResolved(
                version: gray.version,
                ipa: URL(string: gray.ipa),
                notes: gray.notes,
                isGray: true
            )
        }
        return AppUpdateResolved(
            version: index.stableVersion,
            ipa: URL(string: index.stableIpa),
            notes: nil,
            isGray: false
        )
    }
}
