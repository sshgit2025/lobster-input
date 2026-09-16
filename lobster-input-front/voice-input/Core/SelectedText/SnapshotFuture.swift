/// SnapshotFuture.swift
/// 封装"一次性选区快照异步读取"的 actor 状态机。
///
/// 设计目标（对应 Swift 并发原语）：
///   - 开启后台协程读取 snapshot          → Task.detached(priority: .userInitiated)
///   - 将结果赋值给状态变量               → actor isolated stored property
///   - 任务开始 / 结束状态标记            → enum State { pending / resolved }
///   - stop 时同步检查是否已完成          → resolvedValue（nonisolated，无需 await）
///   - 未完成则"阻塞队列"等待            → CheckedContinuation（挂起，零 CPU 轮询）
///   - 取消时立即唤醒所有等待者           → cancel() resolve nil + readTask.cancel()
///
/// 用法：
///   let future = SnapshotFuture()
///   future.start()                        // 立即发起后台读取，不阻塞调用方
///   let snap = await future.result()      // 已完成立即返回；未完成则挂起等待
///   let snap = future.resolvedValue       // 同步查询，不阻塞（nil 表示未完成或已取消）
///   future.cancel()                       // 取消并唤醒所有等待者，result() 返回 nil
import Foundation
import os.log

nonisolated private func snapshotFutureLogger() -> Logger {
    Logger(subsystem: "ssh2026.voice-input", category: "SnapshotFuture")
}

actor SnapshotFuture {

    // MARK: - 状态定义

    private enum State {
        /// 后台任务仍在执行，挂起中的等待者列表
        case pending([CheckedContinuation<SelectionSnapshot?, Never>])
        /// 已完成（包含被取消，此时 value 为 nil）
        case resolved(SelectionSnapshot?)
    }

    private var state: State = .pending([])

    /// 后台读取 Task 引用，用于取消
    private var readTask: Task<Void, Never>?

    // MARK: - 发起读取

    /// 立即在后台发起 snapshot 读取，不阻塞调用方。
    /// nonisolated：可从 @MainActor 同步上下文直接调用。
    /// 内部通过 actor 方法 _start() 保存 Task 引用，再在后台线程执行同步阻塞的 snapshot()。
    nonisolated func start() {
        Task { await self._start() }
    }

    private func _start() {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            snapshotFutureLogger().debug("SnapshotFuture: background read started")
            // snapshot() 包含 AX 和 Cmd+C 兜底，统一放到 context capture worker，
            // 避免默认 MainActor 隔离把 2s 剪贴板轮询带回 UI 线程。
            let snap = await ContextCaptureWorker.run {
                SelectedTextReader.snapshot()
            }
            snapshotFutureLogger().debug("SnapshotFuture: background read done, hasResult=\(snap != nil)")
            await self?.resolve(snap)
        }
        readTask = task
    }

    // MARK: - 取消

    /// 取消后台读取，并立即让所有挂起的 result() 调用返回 nil。
    /// nonisolated：可从 @MainActor 同步上下文直接调用。幂等，重复调用无副作用。
    nonisolated func cancel() {
        Task { await self._cancel() }
    }

    private func _cancel() {
        readTask?.cancel()
        readTask = nil
        resolve(nil)
    }

    // MARK: - 消费结果

    /// 异步等待读取结果。
    /// - 若已完成（包括被取消）：立即返回，无挂起。
    /// - 若仍在读取中：挂起当前协程，后台完成时自动唤醒（CheckedContinuation，零 CPU 轮询）。
    func result() async -> SelectionSnapshot? {
        switch state {
        case .resolved(let snap):
            return snap
        case .pending(var continuations):
            return await withCheckedContinuation { cont in
                continuations.append(cont)
                state = .pending(continuations)
            }
        }
    }

    /// 同步查询当前结果，不挂起、不阻塞。
    /// 返回 nil 表示"尚未完成"或"已取消"，调用方自行决定是否继续 await result()。
    /// 注意：此属性为 nonisolated，可在非 async 上下文（包括 @MainActor 同步代码）中访问。
    nonisolated var resolvedValue: SelectionSnapshot? {
        get async {
            await _resolvedValue
        }
    }

    // MARK: - Private

    private var _resolvedValue: SelectionSnapshot? {
        if case .resolved(let snap) = state { return snap }
        return nil
    }

    private func resolve(_ snap: SelectionSnapshot?) {
        // 幂等保护：已 resolved 则不重复触发
        guard case .pending(let continuations) = state else { return }
        state = .resolved(snap)
        // 唤醒所有挂起的等待者
        for cont in continuations {
            cont.resume(returning: snap)
        }
        snapshotFutureLogger().debug("SnapshotFuture: resolved, woke \(continuations.count) waiters, hasSnap=\(snap != nil)")
    }
}
