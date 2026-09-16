/// AXTimeouts.swift
/// 集中管理 Accessibility API 的 IPC 超时参数。
///
/// 设计原则：
///   - AX IPC 超时（SetMessagingTimeout）是"最长等待"上限，
///     目标 App 正常响应时不消耗任何时间，调大/调小不影响快速路径性能。
import Foundation

nonisolated enum AXTimeouts {

    /// 选区读取（SelectedTextReader）等常规元素查询的 IPC 超时
    static let elementQuery: Float = 1.0

    /// 焦点快探（FocusProbe）/ 观察者挂载的 IPC 超时：
    /// 快探必须快速失败，超时即转入盲填确认分支，不值得等待慢响应
    static let probeQuery: Float = 0.15
}
