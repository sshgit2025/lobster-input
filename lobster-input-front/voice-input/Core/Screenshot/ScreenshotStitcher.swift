import Foundation
import CoreGraphics
import Accelerate

/// 滚动截长图拼接引擎 v2(绝对位置画布 + FFT 全滞后内容配准 + 滚动事件先验)。
///
/// 旧版(Vision 平移配准 + 底部基准 + 只增不减)在快滚/回滚下重影糊片, 已整体替换。
/// 本版本经过独立 demo 环境上千帧自动化验证(匀速/极速/惯性甩滚/回滚/走停/抖动,
/// 内容级标尺验伤全绿)后移植, 与 win 端 ScreenshotStitcher.cs 算法完全一致:
/// - 绝对位置画布: 跟踪当前帧顶部在画布中的位置 pos, 向下追加/向上前插, 中间绝不重写
///   (重影的根源是把错位帧混进已有内容; 只增不改让误差只能表现为不可见的长度伸缩)。
/// - 帧间偏移: 行剖面(K 段列均值)平滑求导后做 FFT 全滞后归一化互相关,
///   支持任意方向任意速度; 候选峰过"画布重叠一致性"校验杀假峰/周期别名。
/// - 滚动事件先验: 采帧间累计的滚轮 delta, 在线学习"单位→像素"比例(允许负号);
///   纯色/渐变(无纹理)或匹配不可信时按先验外推 —— 这两类内容上外推误差视觉不可见。
/// - 画布再锚定: 匹配帧与画布在预测位置附近小窗对齐, 消累计漂移; 外推期间不确定度
///   增长, 锚定窗自适应放大。
/// - Retina/大帧: 剖面在行方向按 ds 降采样(≈≤1100 剖面行), 匹配在剖面空间,
///   写入在原生像素(位置×ds), 精度损失 ≤ds px(不可见), 计算量恒定。
final class ScreenshotStitcher {

    enum AddResult {
        case first
        case appended(Int)      // 画布增长的像素行数(0=位置更新但无新内容)
        case duplicate          // 未动/已覆盖区域内
        case noMatch            // 无法建立联系且无先验(极少)
        case full
        case invalid
    }

    // MARK: 参数(剖面空间, 与 demo 一致)
    private let profileBands = 64            // K: 行剖面横向分段数
    private let edgeFrac = 0.06              // 左右各排除比例(滚动条/边框)
    private let minOverlapBase = 48          // 匹配最小重叠(剖面行)
    private let textureEps = 1.5             // 平滑导数剖面std低于此=无纹理
    private let nccAccept = 0.80
    private let nccAmbigDelta = 0.04
    private let peakSep = 6
    private let anchorWindowBase = 20
    private let velEMA = 0.5
    private let maxPixelHeight = 50_000
    private let maxProfileRows = 1100        // 剖面行数上限(决定 ds)

    // MARK: 状态
    private(set) var pixelWidth = 0          // 画布宽(原生像素)
    private(set) var frameCount = 0
    private var frameH = 0                   // 帧高(原生像素)
    private var ds = 1                       // 剖面降采样因子
    private var profH = 0                    // 剖面行数 = frameH/ds

    private var canvas: [UInt8] = []         // RGBA, 行优先
    private var canvasProf: [Float] = []     // (rows/ds, K)
    private var canvasProfRows = 0
    private var topPx = 0                    // 已写区间 [topPx, bottomPx) — 画布像素坐标
    private var bottomPx = 0
    private var pos = 0.0                    // 当前帧顶部位置(剖面行坐标, 原点=首帧顶部)
    private var topProf = 0                  // 已写区间(剖面行坐标)
    private var bottomProf = 0

    private var prevProf: [Float] = []
    private var velocity = 0.0
    private var ratio: Double?               // hint 单位→剖面行(可为负)
    private var ratioSamples: [Double] = []
    private var uncertainty = 4.0
    // hint 积分绝对预测: 周期区别名选择不链式依赖上一帧, 单帧错选不累积
    private var lockPos: Double?             // 最近一次唯一峰/锚定锁定时的绝对位置
    private var hintIntegral = 0.0
    private var hintMiss = 0

    var pixelHeight: Int { max(0, bottomPx - topPx) }
    var hasContent: Bool { pixelWidth > 0 && pixelHeight > 0 }
    var atLimit: Bool { pixelHeight >= maxPixelHeight }

    // 诊断
    private(set) var statMatched = 0
    private(set) var statExtrapolated = 0
    private(set) var statAnchored = 0

    func reset() {
        canvas.removeAll(keepingCapacity: false)
        canvasProf.removeAll(keepingCapacity: false)
        prevProf.removeAll(keepingCapacity: false)
        ratioSamples.removeAll()
        pixelWidth = 0; frameCount = 0; frameH = 0; ds = 1; profH = 0
        canvasProfRows = 0; topPx = 0; bottomPx = 0; pos = 0
        topProf = 0; bottomProf = 0
        velocity = 0; ratio = nil; uncertainty = 4.0
        lockPos = nil; hintIntegral = 0.0; hintMiss = 0
        statMatched = 0; statExtrapolated = 0; statAnchored = 0
    }

    /// 兼容旧调用点(无滚动事件量)。
    func add(_ image: CGImage) -> AddResult { add(image, hintUnits: nil) }

    // MARK: - 加入一帧
    /// hintUnits: 自上一帧以来累计的滚轮事件量(单位任意, 引擎在线学习比例; nil=未知)
    func add(_ image: CGImage, hintUnits: Double?) -> AddResult {
        guard let buf = Self.extractRGBA(image) else { return .invalid }
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return .invalid }

        if pixelWidth == 0 {
            pixelWidth = w; frameH = h
            ds = max(1, Int(ceil(Double(h) / Double(maxProfileRows))))
            profH = h / ds
            guard profH >= 12 else { return .invalid }
            let prof = rowProfile(buf, w: w, h: h)
            canvas = buf
            canvasProf = prof
            canvasProfRows = profH
            topPx = 0; bottomPx = profH * ds
            topProf = 0; bottomProf = profH
            pos = 0
            prevProf = prof
            frameCount = 1
            return .first
        }
        guard w == pixelWidth, h == frameH else { return .invalid }
        if pixelHeight >= maxPixelHeight { return .full }

        frameCount += 1
        let prof = rowProfile(buf, w: w, h: h)

        // 静止帧短路: **有纹理的**画面与上一帧几乎相同 = 页面真没动(到底/被钳制/停顿),
        // 无论 hint 说什么都不外推不追加(内容证据最高优先级)。
        // 无纹理(纯色)时画面相同≠没动 —— 必须放行走 hint 外推, 否则纯色区滚动全丢。
        var dMean: Float = 0, dMax: Float = 0
        for i in 0..<min(prof.count, prevProf.count) {
            let d = abs(prof[i] - prevProf[i])
            dMean += d; dMax = max(dMax, d)
        }
        dMean /= Float(max(1, prof.count))
        if dMean < 0.8 && dMax < 6.0 {
            let dB = Self.smoothDiff(prof, rows: profH, k: profileBands)
            if Self.stddev(dB) >= Float(textureEps) {
                return .duplicate
            }
        }
        defer { prevProf = prof }

        let (predRaw, predFromHint) = predict(hintUnits)
        // hint 积分绝对预测(偶发事件丢失用速度补积分, 连续丢失≥3帧才失锁)
        if hintUnits == nil {
            hintMiss += 1
            if hintMiss >= 3 { lockPos = nil }
            else if lockPos != nil { hintIntegral += velocity }
        } else {
            hintMiss = 0
            if let r = ratio, lockPos != nil { hintIntegral += hintUnits! * r }
        }
        var predSelect = predRaw
        if let lp = lockPos, ratio != nil {
            predSelect = (lp + hintIntegral) - pos
        }
        var (dy, mode, meta) = estimateDy(profA: prevProf, profB: prof, pred: predRaw, predSelect: predSelect)

        // 滚动事件先验合理性门限: 与事件先验严重相悖的"匹配"多半是假峰, 宁可外推。
        // 例外: 唯一峰+高置信+画布一致 = 内容铁证 → 内容优先于事件
        // (页面到底/被钳制时事件量与实际滚动脱节, 此时 hint 才是说谎的一方)
        let strongContent = meta.unique && meta.conf >= 0.92 && meta.consistent
        if mode == .match && predFromHint && !strongContent {
            let gate = max(0.35 * Double(profH), 0.6 * abs(predRaw) + 40)
            if abs(dy - predRaw) > gate { dy = predRaw; mode = .extrapolate }
        }

        if mode == .hold {
            return .duplicate
        }

        var newPos = pos + dy
        if mode == .match {
            statMatched += 1
            if let anchored = anchorToCanvas(prof: prof, posGuess: newPos) {
                newPos = anchored
                uncertainty = 4.0
                if hintUnits != nil { lockPos = newPos; hintIntegral = 0 }   // 锚定=强绝对证据
            } else if meta.ambiguous {
                // 周期别名选择且无画布佐证 → 不确定度按周期档上调, 锚定窗自适应放大
                uncertainty = min(uncertainty + 15.0, 250.0)
            } else {
                uncertainty = min(uncertainty + 2.0, 250.0)
            }
            if meta.unique && meta.conf >= 0.9 {
                lockPos = newPos; hintIntegral = 0
            }
            // 在线学习 hint 比例(允许负号, 只限幅度)
            if let u = hintUnits, abs(u) > 1e-6, abs(dy) > 4 {
                let r = dy / u
                if abs(r) > 0.01, abs(r) < 5000 {
                    ratioSamples.append(r)
                    if ratioSamples.count > 60 { ratioSamples.removeFirst() }
                    ratio = Self.median(ratioSamples)
                }
            }
        } else {
            statExtrapolated += 1
            uncertainty = min(uncertainty + 0.18 * abs(dy) + 2.0, 250.0)
            // 低纹理区绝对电平锚定(渐变的行亮度是天然绝对位置标尺; 纯色自动不生效)
            if let refined = levelAnchor(prof: prof, posGuess: newPos) {
                newPos = refined
                uncertainty = max(20.0, uncertainty * 0.5)
            }
        }

        // 结构性防空洞: 新帧必须与已写区间保持重叠
        let minOv = Double(minOverlap())
        newPos = min(newPos, Double(bottomProf) - minOv)
        newPos = max(newPos, Double(topProf) - Double(profH) + minOv)

        let appended = write(buf: buf, prof: prof, newPos: newPos)
        let actual = newPos - pos
        velocity = (1 - velEMA) * velocity + velEMA * actual
        pos = newPos
        if appended == 0 && abs(actual) < 0.5 { return .duplicate }
        return .appended(appended)
    }

    // MARK: - 输出
    func makeImage() -> CGImage? {
        let hgt = pixelHeight
        guard pixelWidth > 0, hgt > 0, canvas.count >= pixelWidth * 4 * hgt else { return nil }
        let data = Data(canvas)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: pixelWidth, height: hgt, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func makeThumbnail(maxW: Int, maxH: Int) -> CGImage? {
        let ph = pixelHeight
        guard pixelWidth > 0, ph > 0 else { return nil }
        let scale = min(Double(maxW) / Double(pixelWidth), Double(maxH) / Double(ph), 1.0)
        let tw = max(1, Int(Double(pixelWidth) * scale))
        let th = max(1, Int(Double(ph) * scale))
        var out = [UInt8](repeating: 255, count: tw * th * 4)
        for ty in 0..<th {
            let sy = min(ph - 1, ty * ph / th)
            let srcRow = sy * pixelWidth * 4
            let dstRow = ty * tw * 4
            for tx in 0..<tw {
                let sx = min(pixelWidth - 1, tx * pixelWidth / tw)
                let si = srcRow + sx * 4, di = dstRow + tx * 4
                out[di] = canvas[si]; out[di + 1] = canvas[si + 1]; out[di + 2] = canvas[si + 2]
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: tw, height: th, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tw * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - 内部: 预测/估计

    private func minOverlap() -> Int { min(minOverlapBase, max(8, profH / 3)) }

    private func predict(_ hintUnits: Double?) -> (Double, Bool) {
        if let u = hintUnits, let r = ratio { return (u * r, true) }
        if let u = hintUnits, abs(u) < 1e-6 { return (0, true) }
        return (velocity, false)
    }

    private enum Mode { case match, extrapolate, hold }
    private struct PeakMeta { var unique = false; var ambiguous = false; var conf = 0.0; var consistent = false }

    private func estimateDy(profA: [Float], profB: [Float], pred: Double,
                            predSelect: Double) -> (Double, Mode, PeakMeta) {
        let dA = Self.smoothDiff(profA, rows: profH, k: profileBands)
        let dB = Self.smoothDiff(profB, rows: profH, k: profileBands)
        let dRows = profH - 5
        guard dRows > minOverlap() else {
            return abs(pred) > 0.5 ? (pred, .extrapolate, PeakMeta()) : (0, .hold, PeakMeta())
        }
        let texA = Self.stddev(dA), texB = Self.stddev(dB)
        if texA < Float(textureEps) || texB < Float(textureEps) {
            return abs(pred) > 0.5 ? (pred, .extrapolate, PeakMeta()) : (0, .hold, PeakMeta())
        }

        let (lags, ncc) = Self.nccAllLags(a: dA, b: dB, rows: dRows, k: profileBands,
                                          minOverlap: minOverlap())
        guard let bestIdx = ncc.indices.max(by: { ncc[$0] < ncc[$1] }) else {
            return abs(pred) > 0.5 ? (pred, .extrapolate, PeakMeta()) : (0, .hold, PeakMeta())
        }
        let bestV = ncc[bestIdx]
        if bestV < nccAccept {
            return abs(pred) > 0.5 ? (pred, .extrapolate, PeakMeta()) : (0, .hold, PeakMeta())
        }

        // 候选峰: 局部极大且接近最佳值; NCC 打平时优先靠近先验的峰
        let thr = bestV - nccAmbigDelta
        var candIdx: [Int] = []
        for i in ncc.indices where ncc[i] >= thr {
            let leftOK = i == 0 || ncc[i] >= ncc[i - 1]
            let rightOK = i == ncc.count - 1 || ncc[i] >= ncc[i + 1]
            if leftOK && rightOK { candIdx.append(i) }
        }
        candIdx.sort { a, b in
            let ra = (ncc[a] * 1000).rounded(), rb = (ncc[b] * 1000).rounded()
            if ra != rb { return ra > rb }
            return abs(Double(lags[a]) - predSelect) < abs(Double(lags[b]) - predSelect)
        }
        var peaks: [Int] = []
        for i in candIdx {
            if peaks.allSatisfy({ abs(lags[i] - lags[$0]) >= peakSep }) { peaks.append(i) }
            if peaks.count >= 8 { break }
        }
        guard !peaks.isEmpty else {
            return abs(pred) > 0.5 ? (pred, .extrapolate, PeakMeta()) : (0, .hold, PeakMeta())
        }

        // 画布重叠一致性校验(杀小重叠巧合假峰与周期别名)
        var scored: [(idx: Int, cons: Double, dist: Double)] = []
        for i in peaks {
            let c = canvasConsistency(dy: Double(lags[i]), prof: profB)
            scored.append((i, c, abs(Double(lags[i]) - predSelect)))
        }
        let computable = scored.filter { $0.cons > -1.5 }
        var good: [(idx: Int, cons: Double, dist: Double)]
        if !computable.isEmpty {
            let cbest = computable.map(\.cons).max()!
            if cbest >= 0.5 {
                good = computable.filter { $0.cons > cbest - 0.015 }
            } else if computable.allSatisfy({ $0.cons < 0.3 }) {
                // 画布可比但所有候选都不吻合 → 全是假峰, 外推
                return abs(pred) > 0.5 ? (pred, .extrapolate, PeakMeta()) : (0, .hold, PeakMeta())
            } else {
                good = scored
            }
        } else {
            good = scored
        }
        good.sort { $0.dist < $1.dist }
        let chosenIdx = good[0].idx
        let consistent = scored.contains { $0.idx == chosenIdx && $0.cons >= 0.5 }
        // 歧义(一致性真打平的多峰)且积分锁在线(predSelect 可信)时,
        // 所选峰必须贴近 hint 积分预测, 超界宁可外推 ——
        // 把周期别名漂移锁死在一个周期以内(卡片行/条纹整周期跳切的根治)
        if good.count > 1 && lockPos != nil
            && abs(Double(lags[chosenIdx]) - predSelect) > max(60, 0.35 * abs(predSelect) + 40) {
            return abs(pred) > 0.5 ? (pred, .extrapolate, PeakMeta()) : (0, .hold, PeakMeta())
        }
        let meta = PeakMeta(unique: peaks.count == 1, ambiguous: good.count > 1,
                            conf: Double(ncc[chosenIdx]), consistent: consistent)
        return (Double(lags[chosenIdx]), .match, meta)
    }

    /// 低纹理区绝对电平锚定: 未归一化行均值 L2 在画布上找唯一最小值。
    /// 渐变有唯一解; 纯色所有位置等距(无清晰最小值) → nil 保持外推。
    private func levelAnchor(prof: [Float], posGuess: Double) -> Double? {
        let gi = Int(posGuess.rounded())
        let win = Int(uncertainty) + 30
        let minOv = minOverlap()
        let lo = max(topProf, gi - win)
        let hi = min(bottomProf - minOv, gi + win)
        guard lo <= hi else { return nil }
        let k = profileBands
        var fmean = [Float](repeating: 0, count: profH)
        for r in 0..<profH {
            var s: Float = 0
            for c in 0..<k { s += prof[r * k + c] }
            fmean[r] = s / Float(k)
        }
        let canvasRows = bottomProf - topProf
        var cmean = [Float](repeating: 0, count: canvasRows)
        for r in 0..<canvasRows {
            var s: Float = 0
            for c in 0..<k { s += canvasProf[r * k + c] }
            cmean[r] = s / Float(k)
        }
        var scores: [(s: Double, p: Int)] = []
        var p = lo
        while p <= hi {
            let c1 = min(p + profH, bottomProf)
            let n = c1 - p
            if n >= minOv {
                var acc = 0.0
                for r in 0..<n { acc += Double(abs(cmean[p - topProf + r] - fmean[r])) }
                scores.append((acc / Double(n), p))
            }
            p += 2
        }
        guard scores.count >= 8 else { return nil }
        scores.sort { $0.s < $1.s }
        var bestS = scores[0].s
        var bestP = scores[0].p
        let med = scores[scores.count / 2].s
        if med < 1e-6 || bestS > 0.55 * med { return nil }
        for (sv, pv) in scores.dropFirst() where abs(pv - bestP) > 6 && sv < bestS * 1.5 {
            return nil
        }
        for pv in [bestP - 1, bestP + 1] where pv >= lo && pv <= hi {
            let c1 = min(pv + profH, bottomProf)
            let n = c1 - pv
            if n >= minOv {
                var acc = 0.0
                for r in 0..<n { acc += Double(abs(cmean[pv - topProf + r] - fmean[r])) }
                let sv = acc / Double(n)
                if sv < bestS { bestS = sv; bestP = pv }
            }
        }
        return Double(bestP)
    }

    /// 帧位于 posGuess 时与画布重叠区的对齐修正(导数剖面, 峰唯一才采用)。
    private func anchorToCanvas(prof: [Float], posGuess: Double) -> Double? {
        let gi = Int(posGuess.rounded())
        let win = max(anchorWindowBase, Int(uncertainty))
        let minOv = minOverlap()
        let lo = max(topProf, gi - win)
        let hi = min(bottomProf - minOv, gi + win)
        guard lo <= hi else { return nil }
        let dprof = Self.smoothDiff(prof, rows: profH, k: profileBands)
        var scores: [(v: Double, p: Int)] = []
        scores.reserveCapacity(hi - lo + 1)
        for p in lo...hi {
            let c1 = min(p + profH, bottomProf)
            let n = c1 - p - 5
            if n < minOv { continue }
            // 画布段导数(限长 600 行控制成本)
            let usable = min(n, 600)
            let segRows = usable + 5
            let segStart = (p - topProf) * profileBands
            let seg = Array(canvasProf[segStart ..< segStart + segRows * profileBands])
            let a = Self.smoothDiff(seg, rows: segRows, k: profileBands)
            let b = Array(dprof[0 ..< usable * profileBands])
            guard let v = Self.ncc(a, b) else { continue }
            scores.append((v, p))
        }
        guard !scores.isEmpty else { return nil }
        scores.sort { $0.v > $1.v }
        let (bestV, bestP) = scores[0]
        if bestV < nccAccept { return nil }
        for (v, p) in scores.dropFirst() where abs(p - bestP) > 3 && v > bestV - nccAmbigDelta {
            return nil   // 多峰(周期)模糊, 不锚定
        }
        statAnchored += 1
        return Double(bestP)
    }

    /// 帧若位于 pos+dy, 与画布重叠区导数剖面 NCC(±4 微搜索)。-2 = 不可判。
    private func canvasConsistency(dy: Double, prof: [Float]) -> Double {
        let base = Int((pos + dy).rounded())
        let minOv = minOverlap()
        var best = -2.0
        for p in (base - 4)...(base + 4) {
            let c0 = max(p, topProf)
            let c1 = min(p + profH, bottomProf)
            let n = c1 - c0
            if n < minOv + 5 { continue }
            let usable = min(n, 600)
            let canvasStart = (c0 - topProf) * profileBands
            let segRows = usable
            let a = Self.smoothDiff(Array(canvasProf[canvasStart ..< canvasStart + segRows * profileBands]),
                                    rows: segRows, k: profileBands)
            let frameStart = (c0 - p) * profileBands
            let b = Self.smoothDiff(Array(prof[frameStart ..< frameStart + segRows * profileBands]),
                                    rows: segRows, k: profileBands)
            if Self.stddev(a) < Float(textureEps) || Self.stddev(b) < Float(textureEps) { continue }
            if let v = Self.ncc(a, b) { best = max(best, v) }
        }
        return best
    }

    // MARK: - 内部: 写入画布

    /// 把帧写入画布(只增不改写)。返回增长的像素行数。
    private func write(buf: [UInt8], prof: [Float], newPos: Double) -> Int {
        let pProf = Int(newPos.rounded())
        var grown = 0
        let rowBytes = pixelWidth * 4

        let effH = profH * ds                              // 像素行数与剖面行数严格对应
        // 底部追加
        if pProf + profH > bottomProf {
            let startProf = bottomProf - pProf                 // 帧内起始剖面行
            let startPx = startProf * ds
            let addPx = effH - startPx
            if addPx > 0 {
                canvas.append(contentsOf: buf[(startPx * rowBytes) ..< (effH * rowBytes)])
                canvasProf.append(contentsOf: prof[(startProf * profileBands)...])
                bottomPx += addPx
                bottomProf += profH - startProf
                canvasProfRows += profH - startProf
                grown += addPx
            }
        }
        // 顶部前插
        if pProf < topProf {
            let cutProf = topProf - pProf
            let cutPx = cutProf * ds
            canvas.insert(contentsOf: buf[0 ..< cutPx * rowBytes], at: 0)
            canvasProf.insert(contentsOf: prof[0 ..< cutProf * profileBands], at: 0)
            topPx -= cutPx
            topProf -= cutProf
            canvasProfRows += cutProf
            grown += cutPx
        }
        return grown
    }

    // MARK: - 内部: 剖面/数学

    /// RGBA 帧 → (profH, K) 行剖面(灰度, 中央区域, 行方向 ds 降采样)。
    private func rowProfile(_ buf: [UInt8], w: Int, h: Int) -> [Float] {
        let k = profileBands
        let x0 = Int(Double(w) * edgeFrac)
        let x1 = w - x0
        let bandW = max(1, (x1 - x0) / k)
        var prof = [Float](repeating: 0, count: profH * k)
        buf.withUnsafeBufferPointer { pb in
            let p = pb.baseAddress!
            for pr in 0..<profH {
                var acc = [Float](repeating: 0, count: k)
                for sub in 0..<ds {
                    let y = pr * ds + sub
                    let rowBase = y * w * 4
                    for band in 0..<k {
                        let bx0 = x0 + band * bandW
                        let bx1 = min(bx0 + bandW, x1)
                        var s: Float = 0
                        var x = bx0
                        while x < bx1 {
                            let i = rowBase + x * 4
                            s += Float(Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]))
                            x += 1
                        }
                        acc[band] += s / (3 * Float(bx1 - bx0))
                    }
                }
                for band in 0..<k { prof[pr * k + band] = acc[band] / Float(ds) }
            }
        }
        return prof
    }

    /// 纵向平滑([1,2,3,2,1]/9)后中心差分 → (rows-5, K)
    static func smoothDiff(_ prof: [Float], rows: Int, k: Int) -> [Float] {
        let outRows = rows - 5
        guard outRows > 0 else { return [] }
        var sm = [Float](repeating: 0, count: (rows - 4) * k)
        prof.withUnsafeBufferPointer { pb in
            let p = pb.baseAddress!
            for r in 0..<(rows - 4) {
                let r0 = r * k, r1 = (r + 1) * k, r2 = (r + 2) * k, r3 = (r + 3) * k, r4 = (r + 4) * k
                for c in 0..<k {
                    sm[r * k + c] = (p[r0 + c] + 2 * p[r1 + c] + 3 * p[r2 + c] + 2 * p[r3 + c] + p[r4 + c]) / 9
                }
            }
        }
        var out = [Float](repeating: 0, count: outRows * k)
        for r in 0..<outRows {
            for c in 0..<k { out[r * k + c] = sm[(r + 1) * k + c] - sm[r * k + c] }
        }
        return out
    }

    static func stddev(_ v: [Float]) -> Float {
        guard !v.isEmpty else { return 0 }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(v, 1, nil, 1, &mean, &sd, vDSP_Length(v.count))
        return sd
    }

    /// 展平 NCC(两段等长向量)。nil = 无纹理不可判。
    static func ncc(_ a: [Float], _ b: [Float]) -> Double? {
        let n = min(a.count, b.count)
        guard n > 8 else { return nil }
        var meanA: Float = 0, meanB: Float = 0
        vDSP_meanv(a, 1, &meanA, vDSP_Length(n))
        vDSP_meanv(b, 1, &meanB, vDSP_Length(n))
        var negA = -meanA, negB = -meanB
        var ca = [Float](repeating: 0, count: n), cb = [Float](repeating: 0, count: n)
        vDSP_vsadd(a, 1, &negA, &ca, 1, vDSP_Length(n))
        vDSP_vsadd(b, 1, &negB, &cb, 1, vDSP_Length(n))
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(ca, 1, cb, 1, &dot, vDSP_Length(n))
        vDSP_svesq(ca, 1, &na, vDSP_Length(n))
        vDSP_svesq(cb, 1, &nb, vDSP_Length(n))
        let den = sqrt(Double(na) * Double(nb))
        guard den > 1e-9 else { return nil }
        return Double(dot) / den
    }

    /// FFT 全滞后 NCC: B 相对 A 向下偏移 dy 的 NCC, dy∈[-(rows-mo), rows-mo]。
    /// 返回 (lags, ncc)。互相关经 FFT, 均值/方差经前缀和, 与 demo 一致。
    static func nccAllLags(a: [Float], b: [Float], rows: Int, k: Int,
                           minOverlap: Int) -> ([Int], [Double]) {
        let maxDy = rows - minOverlap
        var lags = [Int](); lags.reserveCapacity(2 * maxDy + 1)
        for d in -maxDy...maxDy { lags.append(d) }

        // FFT 大小
        var n = 1
        while n < 2 * rows { n <<= 1 }
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return (lags, [Double](repeating: -2, count: lags.count))
        }
        defer { vDSP_destroy_fftsetup(setup) }

        // 累加各列的互相关谱: SUM_k FA_k · conj(FB_k), 一次逆变换得 cc[dy]
        var accRe = [Float](repeating: 0, count: n)
        var accIm = [Float](repeating: 0, count: n)
        var colRe = [Float](repeating: 0, count: n)
        var colIm = [Float](repeating: 0, count: n)
        var colBRe = [Float](repeating: 0, count: n)
        var colBIm = [Float](repeating: 0, count: n)

        for c in 0..<k {
            for i in 0..<n { colRe[i] = i < rows ? a[i * k + c] : 0; colIm[i] = 0 }
            for i in 0..<n { colBRe[i] = i < rows ? b[i * k + c] : 0; colBIm[i] = 0 }
            colRe.withUnsafeMutableBufferPointer { re in
                colIm.withUnsafeMutableBufferPointer { im in
                    var sa = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_fft_zip(setup, &sa, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            colBRe.withUnsafeMutableBufferPointer { re in
                colBIm.withUnsafeMutableBufferPointer { im in
                    var sb = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                    vDSP_fft_zip(setup, &sb, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }
            // acc += FA · conj(FB)
            for i in 0..<n {
                let ar = colRe[i], ai = colIm[i]
                let br = colBRe[i], bi = -colBIm[i]
                accRe[i] += ar * br - ai * bi
                accIm[i] += ar * bi + ai * br
            }
        }
        accRe.withUnsafeMutableBufferPointer { re in
            accIm.withUnsafeMutableBufferPointer { im in
                var s = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zip(setup, &s, 1, log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        let invN = 1.0 / Double(n)

        // 前缀和(行内先对 K 求和)
        var rowSumA = [Double](repeating: 0, count: rows)
        var rowSqA = [Double](repeating: 0, count: rows)
        var rowSumB = [Double](repeating: 0, count: rows)
        var rowSqB = [Double](repeating: 0, count: rows)
        for r in 0..<rows {
            var sa = 0.0, qa = 0.0, sb = 0.0, qb = 0.0
            for c in 0..<k {
                let va = Double(a[r * k + c]), vb = Double(b[r * k + c])
                sa += va; qa += va * va; sb += vb; qb += vb * vb
            }
            rowSumA[r] = sa; rowSqA[r] = qa; rowSumB[r] = sb; rowSqB[r] = qb
        }
        var ca = [Double](repeating: 0, count: rows + 1)
        var caa = [Double](repeating: 0, count: rows + 1)
        var cb = [Double](repeating: 0, count: rows + 1)
        var cbb = [Double](repeating: 0, count: rows + 1)
        for r in 0..<rows {
            ca[r + 1] = ca[r] + rowSumA[r]; caa[r + 1] = caa[r] + rowSqA[r]
            cb[r + 1] = cb[r] + rowSumB[r]; cbb[r + 1] = cbb[r] + rowSqB[r]
        }

        var ncc = [Double](repeating: -2, count: lags.count)
        for (idx, dy) in lags.enumerated() {
            let ov = rows - abs(dy)
            let cnt = Double(ov * k)
            var sA: Double, qA: Double, sB: Double, qB: Double
            if dy >= 0 {
                sA = ca[rows] - ca[dy];  qA = caa[rows] - caa[dy]
                sB = cb[rows - dy];      qB = cbb[rows - dy]
            } else {
                sA = ca[rows + dy];      qA = caa[rows + dy]
                sB = cb[rows] - cb[-dy]; qB = cbb[rows] - cbb[-dy]
            }
            let ccIdx = ((dy % n) + n) % n
            let cc = Double(accRe[ccIdx]) * invN
            let num = cc - sA * sB / cnt
            let va = qA - sA * sA / cnt
            let vb = qB - sB * sB / cnt
            let den = (va * vb).squareRoot()
            if den.isFinite, den > cnt * 0.05 {
                ncc[idx] = num / max(den, 1e-9)
            }
        }
        return (lags, ncc)
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    static func extractRGBA(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buffer : nil
    }
}
