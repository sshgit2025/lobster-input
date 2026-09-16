using System;
using System.Collections.Generic;
using System.Linq;

namespace LobsterInput.Services.Screenshot;

/// <summary>
/// 滚动截长图拼接引擎 v2（纯 C#，与 macOS 端新算法一致）。
///
/// 核心设计（旧版"底部基准+模板搜索+只增不减"在快滚/回滚下重影糊片，已整体替换）：
/// - 绝对位置画布：跟踪当前帧顶部在画布中的位置 pos，向下滚在底部追加、向上滚越过画布顶部
///   则在顶部前插，中间区域绝不重写——重影的根源是把错位帧混进已有内容，只增不改让误差
///   只能表现为视觉不可见的长度伸缩。
/// - 帧间偏移：行剖面（K 段列均值）纵向平滑求导后做 FFT 全滞后归一化互相关（NCC），
///   一次算出所有整数偏移，支持任意方向任意速度；候选峰再过"画布重叠一致性"校验，
///   杀掉小重叠稀疏特征假峰与周期图案别名峰。
/// - 滚动事件先验：采帧间累计的滚轮 delta（单位任意），在线学习"单位→像素"比例（允许负号）；
///   纯色/渐变（无纹理）或匹配不可信时按先验外推——这两类内容上外推误差视觉不可见。
///   与先验严重相悖的"匹配"直接不信（假峰门限）。
/// - 画布再锚定：匹配帧与画布在预测位置附近小窗对齐消累计漂移；外推期间不确定度增长，
///   锚定窗自适应放大。
/// - 大帧（高 DPI）：剖面按 ds 行降采样（≈≤1100 剖面行），匹配在剖面空间，写入在原生像素。
///
/// 像素格式：Pbgra32（BGRA，top-down，stride = width*4），与 WPF BitmapSource.CopyPixels 一致。
/// 采集端要求：滚动会话期间定时连续采帧（≈15fps），并把两次采帧之间累计的滚轮 delta 经
/// hintUnits 传入（见 ScrollingCaptureWindow）。
/// </summary>
public sealed class ScreenshotStitcher
{
    public enum AddResult { First, Appended, Duplicate, NoMatch, Full, Invalid }

    // 参数（剖面空间，与 mac 端一致）
    private const int ProfileBands = 64;       // K: 行剖面横向分段数
    private const double EdgeFrac = 0.06;      // 左右各排除比例（滚动条/边框）
    private const int MinOverlapBase = 48;     // 匹配最小重叠（剖面行）
    private const double TextureEps = 1.5;     // 平滑导数剖面 std 低于此=无纹理
    private const double NccAccept = 0.80;
    private const double NccAmbigDelta = 0.04;
    private const int PeakSep = 6;
    private const int AnchorWindowBase = 20;
    private const double VelEma = 0.5;
    private const int MaxPixelHeight = 50000;
    private const int MaxProfileRows = 1100;   // 剖面行数上限（决定 ds）

    public int PixelWidth { get; private set; }
    public int PixelHeight => Math.Max(0, _bottomPx - _topPx);
    public int FrameCount { get; private set; }
    public int LastAddedRows { get; private set; }
    public bool HasContent => PixelWidth > 0 && PixelHeight > 0;

    private int _frameH;                 // 帧高（原生像素）
    private int _ds = 1;                 // 剖面降采样因子
    private int _profH;                  // 剖面行数

    private readonly List<byte> _canvas = new();       // BGRA 行优先，仅追加
    private readonly List<byte> _canvasTop = new();    // 顶部前插区（行序倒置存放，导出时还原）
    private readonly List<float> _prof = new();        // 画布剖面（含前插区），与像素同序
    private readonly List<float> _profTop = new();
    private int _topPx, _bottomPx;       // 已写像素区间（画布坐标）
    private int _topProf, _bottomProf;   // 已写剖面区间
    private double _pos;                 // 当前帧顶部位置（剖面行坐标）

    private float[] _prevProf = Array.Empty<float>();
    private double _velocity;
    private double? _ratio;              // hint 单位 → 剖面行（可为负）
    private readonly List<double> _ratioSamples = new();
    private double _uncertainty = 4.0;
    // hint 积分绝对预测: 周期区别名选择不链式依赖上一帧, 单帧错选不累积
    private double? _lockPos;
    private double _hintIntegral;
    private int _hintMiss;

    public void Reset()
    {
        _canvas.Clear(); _canvasTop.Clear(); _prof.Clear(); _profTop.Clear();
        _ratioSamples.Clear();
        PixelWidth = 0; FrameCount = 0; LastAddedRows = 0;
        _frameH = 0; _ds = 1; _profH = 0;
        _topPx = 0; _bottomPx = 0; _topProf = 0; _bottomProf = 0;
        _pos = 0; _prevProf = Array.Empty<float>();
        _velocity = 0; _ratio = null; _uncertainty = 4.0;
        _lockPos = null; _hintIntegral = 0; _hintMiss = 0;
    }

    /// <summary>加入一帧（BGRA top-down）。hintUnits = 自上一帧以来累计的滚轮量（任意单位，可空）。</summary>
    public AddResult Add(byte[] buf, int w, int h, double? hintUnits = null)
    {
        LastAddedRows = 0;
        if (buf.Length < w * h * 4 || w <= 8 || h <= 8) return AddResult.Invalid;

        if (PixelWidth == 0)
        {
            PixelWidth = w; _frameH = h;
            _ds = Math.Max(1, (h + MaxProfileRows - 1) / MaxProfileRows);
            _profH = h / _ds;
            if (_profH < 12) return AddResult.Invalid;
            var prof0 = RowProfile(buf, w);
            int effH0 = _profH * _ds;
            _canvas.AddRange(new ArraySegment<byte>(buf, 0, w * effH0 * 4));
            _prof.AddRange(prof0);
            _topPx = 0; _bottomPx = effH0; _topProf = 0; _bottomProf = _profH;
            _pos = 0; _prevProf = prof0;
            FrameCount = 1;
            return AddResult.First;
        }
        if (w != PixelWidth || h != _frameH) return AddResult.Invalid;
        if (PixelHeight >= MaxPixelHeight) return AddResult.Full;

        FrameCount++;
        var prof = RowProfile(buf, w);

        // 静止帧短路：**有纹理的**画面与上一帧几乎相同 = 页面真没动（到底/被钳制/停顿），
        // 无论 hint 说什么都不外推不追加（内容证据最高优先级）。
        // 无纹理（纯色）时画面相同≠没动 —— 必须放行走 hint 外推，否则纯色区滚动全丢。
        if (_prevProf.Length == prof.Length)
        {
            double dMean = 0, dMax = 0;
            for (int i = 0; i < prof.Length; i++)
            {
                double d = Math.Abs(prof[i] - _prevProf[i]);
                dMean += d; if (d > dMax) dMax = d;
            }
            dMean /= prof.Length;
            if (dMean < 0.8 && dMax < 6.0 && StdDev(SmoothDiff(prof, _profH)) >= TextureEps)
                return AddResult.Duplicate;
        }

        var (predRaw, predFromHint) = Predict(hintUnits);
        // hint 积分绝对预测（偶发事件丢失用速度补积分，连续丢失≥3帧才失锁）
        if (!hintUnits.HasValue)
        {
            _hintMiss++;
            if (_hintMiss >= 3) _lockPos = null;
            else if (_lockPos.HasValue) _hintIntegral += _velocity;
        }
        else
        {
            _hintMiss = 0;
            if (_ratio.HasValue && _lockPos.HasValue) _hintIntegral += hintUnits.Value * _ratio.Value;
        }
        double predSelect = predRaw;
        if (_lockPos.HasValue && _ratio.HasValue) predSelect = (_lockPos.Value + _hintIntegral) - _pos;
        var (dy, mode, meta) = EstimateDy(_prevProf, prof, predRaw, predSelect);

        // 滚动事件先验合理性门限：与事件先验严重相悖的"匹配"多半是假峰，宁可外推。
        // 例外：唯一峰+高置信+画布一致 = 内容铁证 → 内容优先于事件
        // （页面到底/被钳制时事件量与实际滚动脱节，此时 hint 才是说谎的一方）
        bool strongContent = meta.Unique && meta.Conf >= 0.92 && meta.Consistent;
        if (mode == Mode.Match && predFromHint && !strongContent)
        {
            double gate = Math.Max(0.35 * _profH, 0.6 * Math.Abs(predRaw) + 40);
            if (Math.Abs(dy - predRaw) > gate) { dy = predRaw; mode = Mode.Extrapolate; }
        }

        if (mode == Mode.Hold) { _prevProf = prof; return AddResult.Duplicate; }

        double newPos = _pos + dy;
        if (mode == Mode.Match)
        {
            double? anchored = AnchorToCanvas(prof, newPos);
            if (anchored.HasValue)
            {
                newPos = anchored.Value; _uncertainty = 4.0;
                if (hintUnits.HasValue) { _lockPos = newPos; _hintIntegral = 0; }   // 锚定=强绝对证据
            }
            else if (meta.Ambiguous)
            {
                // 周期别名选择且无画布佐证 → 不确定度按周期档上调, 锚定窗自适应放大
                _uncertainty = Math.Min(_uncertainty + 15.0, 250.0);
            }
            else _uncertainty = Math.Min(_uncertainty + 2.0, 250.0);
            if (meta.Unique && meta.Conf >= 0.9) { _lockPos = newPos; _hintIntegral = 0; }

            if (hintUnits.HasValue && Math.Abs(hintUnits.Value) > 1e-6 && Math.Abs(dy) > 4)
            {
                double r = dy / hintUnits.Value;   // 允许负比例（方向设置随用户），只限幅度
                if (Math.Abs(r) > 0.01 && Math.Abs(r) < 5000)
                {
                    _ratioSamples.Add(r);
                    if (_ratioSamples.Count > 60) _ratioSamples.RemoveAt(0);
                    _ratio = Median(_ratioSamples);
                }
            }
        }
        else
        {
            _uncertainty = Math.Min(_uncertainty + 0.18 * Math.Abs(dy) + 2.0, 250.0);
            // 低纹理区绝对电平锚定（渐变的行亮度是天然绝对位置标尺；纯色自动不生效）
            double? refined = LevelAnchor(prof, newPos);
            if (refined.HasValue)
            {
                newPos = refined.Value;
                _uncertainty = Math.Max(20.0, _uncertainty * 0.5);
            }
        }

        // 结构性防空洞：新帧必须与已写区间保持重叠
        int minOv = MinOverlap();
        newPos = Math.Min(newPos, _bottomProf - (double)minOv);
        newPos = Math.Max(newPos, _topProf - (double)_profH + minOv);

        int grown = Write(buf, prof, newPos);
        double actual = newPos - _pos;
        _velocity = (1 - VelEma) * _velocity + VelEma * actual;
        _pos = newPos;
        _prevProf = prof;
        LastAddedRows = grown;
        return grown == 0 && Math.Abs(actual) < 0.5 ? AddResult.Duplicate : AddResult.Appended;
    }

    /// <summary>导出累积长图（BGRA top-down，stride = PixelWidth*4）。</summary>
    public byte[] GetImageBytes()
    {
        int rowBytes = PixelWidth * 4;
        var outBuf = new byte[(long)PixelHeight * rowBytes];
        // 顶部前插区行序倒置: _canvasTop 按"离首帧顶部越来越远"的顺序追加，导出时反转行序
        int topRows = _canvasTop.Count / rowBytes;
        for (int r = 0; r < topRows; r++)
        {
            _canvasTop.CopyTo((topRows - 1 - r) * rowBytes, outBuf, r * rowBytes, rowBytes);
        }
        _canvas.CopyTo(0, outBuf, topRows * rowBytes, _canvas.Count);
        return outBuf;
    }

    /// <summary>后台抽样生成小缩略图像素（最近邻），返回 (bytes, tw, th)。</summary>
    public (byte[] bytes, int width, int height)? MakeThumbnail(int maxW, int maxH)
    {
        int ph = PixelHeight;
        if (PixelWidth <= 0 || ph <= 0) return null;
        double scale = Math.Min(Math.Min((double)maxW / PixelWidth, (double)maxH / ph), 1.0);
        int tw = Math.Max(1, (int)(PixelWidth * scale));
        int th = Math.Max(1, (int)(ph * scale));
        int rowBytes = PixelWidth * 4;
        int topRows = _canvasTop.Count / rowBytes;
        var outBuf = new byte[tw * th * 4];
        for (int ty = 0; ty < th; ty++)
        {
            int sy = Math.Min(ph - 1, (int)((double)ty / th * ph));
            for (int tx = 0; tx < tw; tx++)
            {
                int sx = Math.Min(PixelWidth - 1, (int)((double)tx / tw * PixelWidth));
                int di = (ty * tw + tx) * 4;
                int si;
                List<byte> src;
                if (sy < topRows) { src = _canvasTop; si = ((topRows - 1 - sy) * PixelWidth + sx) * 4; }
                else { src = _canvas; si = ((sy - topRows) * PixelWidth + sx) * 4; }
                outBuf[di] = src[si]; outBuf[di + 1] = src[si + 1]; outBuf[di + 2] = src[si + 2]; outBuf[di + 3] = 255;
            }
        }
        return (outBuf, tw, th);
    }

    // ---------------- 内部 ----------------

    private enum Mode { Match, Extrapolate, Hold }
    private struct PeakMeta { public bool Unique; public bool Ambiguous; public double Conf; public bool Consistent; }

    private int MinOverlap() => Math.Min(MinOverlapBase, Math.Max(8, _profH / 3));

    private (double pred, bool fromHint) Predict(double? hintUnits)
    {
        if (hintUnits.HasValue && _ratio.HasValue) return (hintUnits.Value * _ratio.Value, true);
        if (hintUnits.HasValue && Math.Abs(hintUnits.Value) < 1e-6) return (0, true);
        return (_velocity, false);
    }

    private (double dy, Mode mode, PeakMeta meta) EstimateDy(float[] profA, float[] profB, double pred, double predSelect)
    {
        var dA = SmoothDiff(profA, _profH);
        var dB = SmoothDiff(profB, _profH);
        int dRows = _profH - 5;
        int minOv = MinOverlap();
        if (dRows <= minOv) return Fallback(pred);
        if (StdDev(dA) < TextureEps || StdDev(dB) < TextureEps) return Fallback(pred);

        var (lags, ncc) = NccAllLags(dA, dB, dRows, minOv);
        int bestIdx = 0; double bestV = double.MinValue;
        for (int i = 0; i < ncc.Length; i++) if (ncc[i] > bestV) { bestV = ncc[i]; bestIdx = i; }
        if (bestV < NccAccept) return Fallback(pred);

        // 候选峰：局部极大且接近最佳值；NCC 打平时优先靠近先验的峰
        double thr = bestV - NccAmbigDelta;
        var cand = new List<int>();
        for (int i = 0; i < ncc.Length; i++)
        {
            if (ncc[i] < thr) continue;
            bool leftOk = i == 0 || ncc[i] >= ncc[i - 1];
            bool rightOk = i == ncc.Length - 1 || ncc[i] >= ncc[i + 1];
            if (leftOk && rightOk) cand.Add(i);
        }
        cand.Sort((x, y) =>
        {
            double rx = Math.Round(ncc[x] * 1000), ry = Math.Round(ncc[y] * 1000);
            if (rx != ry) return ry.CompareTo(rx);
            return Math.Abs(lags[x] - predSelect).CompareTo(Math.Abs(lags[y] - predSelect));
        });
        var peaks = new List<int>();
        foreach (int i in cand)
        {
            if (peaks.All(j => Math.Abs(lags[i] - lags[j]) >= PeakSep)) peaks.Add(i);
            if (peaks.Count >= 8) break;
        }
        if (peaks.Count == 0) return Fallback(pred);

        // 画布重叠一致性校验（杀小重叠巧合假峰与周期别名）
        var scored = peaks.Select(i => (idx: i, cons: CanvasConsistency(lags[i], profB),
                                        dist: Math.Abs(lags[i] - predSelect))).ToList();
        var computable = scored.Where(s => s.cons > -1.5).ToList();
        List<(int idx, double cons, double dist)> good;
        if (computable.Count > 0)
        {
            double cbest = computable.Max(s => s.cons);
            if (cbest >= 0.5) good = computable.Where(s => s.cons > cbest - 0.015).ToList();
            else if (computable.All(s => s.cons < 0.3)) return Fallback(pred);   // 全是假峰
            else good = scored;
        }
        else good = scored;   // 画布重叠无纹理（纯色区），只能靠先验
        good.Sort((a, b) => a.dist.CompareTo(b.dist));
        int chosenIdx = good[0].idx;
        bool consistent = scored.Any(sc => sc.idx == chosenIdx && sc.cons >= 0.5);
        // 歧义（一致性真打平的多峰）且积分锁在线（predSelect 可信）时，
        // 所选峰必须贴近 hint 积分预测，超界宁可外推 ——
        // 把周期别名漂移锁死在一个周期以内（卡片行/条纹整周期跳切的根治）
        if (good.Count > 1 && _lockPos.HasValue
            && Math.Abs(lags[chosenIdx] - predSelect) > Math.Max(60, 0.35 * Math.Abs(predSelect) + 40))
            return Fallback(pred);
        var meta = new PeakMeta { Unique = peaks.Count == 1, Ambiguous = good.Count > 1,
                                  Conf = ncc[chosenIdx], Consistent = consistent };
        return (lags[chosenIdx], Mode.Match, meta);

        (double, Mode, PeakMeta) Fallback(double p) =>
            Math.Abs(p) > 0.5 ? (p, Mode.Extrapolate, new PeakMeta()) : (0.0, Mode.Hold, new PeakMeta());
    }

    /// <summary>低纹理区绝对电平锚定：未归一化行均值 L2 在画布上找唯一最小值。
    /// 渐变有唯一解；纯色所有位置等距（无清晰最小值）→ null 保持外推。</summary>
    private double? LevelAnchor(float[] prof, double posGuess)
    {
        int gi = (int)Math.Round(posGuess);
        int win = (int)_uncertainty + 30;
        int minOv = MinOverlap();
        int lo = Math.Max(_topProf, gi - win);
        int hi = Math.Min(_bottomProf - minOv, gi + win);
        if (lo > hi) return null;
        int k = ProfileBands;
        var fmean = new float[_profH];
        for (int r = 0; r < _profH; r++)
        {
            float sum = 0;
            for (int c = 0; c < k; c++) sum += prof[r * k + c];
            fmean[r] = sum / k;
        }
        int canvasRows = _bottomProf - _topProf;
        var cmean = new float[canvasRows];
        for (int r = 0; r < canvasRows; r++)
        {
            var seg = ProfSegment(_topProf + r, 1);
            float sum = 0;
            for (int c = 0; c < k; c++) sum += seg[c];
            cmean[r] = sum / k;
        }
        var scores = new List<(double s, int p)>();
        for (int p2 = lo; p2 <= hi; p2 += 2)
        {
            int c1 = Math.Min(p2 + _profH, _bottomProf);
            int n = c1 - p2;
            if (n < minOv) continue;
            double acc = 0;
            for (int r = 0; r < n; r++) acc += Math.Abs(cmean[p2 - _topProf + r] - fmean[r]);
            scores.Add((acc / n, p2));
        }
        if (scores.Count < 8) return null;
        scores.Sort((a, b) => a.s.CompareTo(b.s));
        double bestS = scores[0].s; int bestP = scores[0].p;
        double med = scores[scores.Count / 2].s;
        if (med < 1e-6 || bestS > 0.55 * med) return null;
        foreach (var (sv, pv) in scores.Skip(1))
            if (Math.Abs(pv - bestP) > 6 && sv < bestS * 1.5) return null;
        foreach (int pv in new[] { bestP - 1, bestP + 1 })
        {
            if (pv < lo || pv > hi) continue;
            int c1 = Math.Min(pv + _profH, _bottomProf);
            int n = c1 - pv;
            if (n < minOv) continue;
            double acc = 0;
            for (int r = 0; r < n; r++) acc += Math.Abs(cmean[pv - _topProf + r] - fmean[r]);
            double sv = acc / n;
            if (sv < bestS) { bestS = sv; bestP = pv; }
        }
        return bestP;
    }

    /// <summary>帧位于 posGuess 时与画布重叠区的对齐修正（导数剖面，峰唯一才采用）。</summary>
    private double? AnchorToCanvas(float[] prof, double posGuess)
    {
        int gi = (int)Math.Round(posGuess);
        int win = Math.Max(AnchorWindowBase, (int)_uncertainty);
        int minOv = MinOverlap();
        int lo = Math.Max(_topProf, gi - win);
        int hi = Math.Min(_bottomProf - minOv, gi + win);
        if (lo > hi) return null;
        var dprof = SmoothDiff(prof, _profH);
        var scores = new List<(double v, int p)>();
        for (int p = lo; p <= hi; p++)
        {
            int c1 = Math.Min(p + _profH, _bottomProf);
            int n = c1 - p - 5;
            if (n < minOv) continue;
            int usable = Math.Min(n, 600);
            var a = SmoothDiff(ProfSegment(p, usable + 5), usable + 5);
            double? v = Ncc(a, dprof, usable * ProfileBands);
            if (v.HasValue) scores.Add((v.Value, p));
        }
        if (scores.Count == 0) return null;
        scores.Sort((x, y) => y.v.CompareTo(x.v));
        var (bestV, bestP) = scores[0];
        if (bestV < NccAccept) return null;
        foreach (var (v, p) in scores.Skip(1))
            if (Math.Abs(p - bestP) > 3 && v > bestV - NccAmbigDelta) return null;   // 多峰（周期）模糊
        return bestP;
    }

    /// <summary>帧若位于 pos+dy，与画布重叠区导数剖面 NCC（±4 微搜索）。-2 = 不可判。</summary>
    private double CanvasConsistency(double dy, float[] prof)
    {
        int baseP = (int)Math.Round(_pos + dy);
        int minOv = MinOverlap();
        double best = -2.0;
        for (int p = baseP - 4; p <= baseP + 4; p++)
        {
            int c0 = Math.Max(p, _topProf);
            int c1 = Math.Min(p + _profH, _bottomProf);
            int n = c1 - c0;
            if (n < minOv + 5) continue;
            int usable = Math.Min(n, 600);
            var a = SmoothDiff(ProfSegment(c0, usable), usable);
            var frameSeg = new float[usable * ProfileBands];
            Array.Copy(prof, (c0 - p) * ProfileBands, frameSeg, 0, usable * ProfileBands);
            var b = SmoothDiff(frameSeg, usable);
            if (StdDev(a) < TextureEps || StdDev(b) < TextureEps) continue;
            double? v = Ncc(a, b, Math.Min(a.Length, b.Length));
            if (v.HasValue) best = Math.Max(best, v.Value);
        }
        return best;
    }

    /// <summary>取画布剖面第 [startProf, startProf+rows) 行（画布剖面坐标，含前插区）。</summary>
    private float[] ProfSegment(int startProf, int rows)
    {
        var seg = new float[rows * ProfileBands];
        int topRows = _profTop.Count / ProfileBands;
        for (int r = 0; r < rows; r++)
        {
            int profRow = startProf - _topProf + r;   // 0-based，全画布行号
            if (profRow < topRows)
                _profTop.CopyTo((topRows - 1 - profRow) * ProfileBands, seg, r * ProfileBands, ProfileBands);
            else
                _prof.CopyTo((profRow - topRows) * ProfileBands, seg, r * ProfileBands, ProfileBands);
        }
        return seg;
    }

    /// <summary>把帧写入画布（只增不改写）。返回增长的像素行数。</summary>
    private int Write(byte[] buf, float[] prof, double newPos)
    {
        int pProf = (int)Math.Round(newPos);
        int grown = 0;
        int rowBytes = PixelWidth * 4;
        int effH = _profH * _ds;

        if (pProf + _profH > _bottomProf)      // 底部追加
        {
            int startProf = _bottomProf - pProf;
            int startPx = startProf * _ds;
            int addPx = effH - startPx;
            if (addPx > 0)
            {
                _canvas.AddRange(new ArraySegment<byte>(buf, startPx * rowBytes, addPx * rowBytes));
                for (int i = startProf * ProfileBands; i < _profH * ProfileBands; i++) _prof.Add(prof[i]);
                _bottomPx += addPx;
                _bottomProf += _profH - startProf;
                grown += addPx;
            }
        }
        if (pProf < _topProf)                  // 顶部前插（行序倒置存入 _canvasTop）
        {
            int cutProf = _topProf - pProf;
            int cutPx = cutProf * _ds;
            for (int r = cutPx - 1; r >= 0; r--)
                _canvasTop.AddRange(new ArraySegment<byte>(buf, r * rowBytes, rowBytes));
            for (int r = cutProf - 1; r >= 0; r--)
                for (int c = 0; c < ProfileBands; c++) _profTop.Add(prof[r * ProfileBands + c]);
            _topPx -= cutPx;
            _topProf -= cutProf;
            grown += cutPx;
        }
        return grown;
    }

    // ---------------- 剖面 / 数学 ----------------

    /// <summary>BGRA 帧 → (profH, K) 行剖面（灰度，中央区域，行方向 ds 降采样）。</summary>
    private float[] RowProfile(byte[] buf, int w)
    {
        int k = ProfileBands;
        int x0 = (int)(w * EdgeFrac);
        int x1 = w - x0;
        int bandW = Math.Max(1, (x1 - x0) / k);
        var prof = new float[_profH * k];
        for (int pr = 0; pr < _profH; pr++)
        {
            for (int band = 0; band < k; band++)
            {
                int bx0 = x0 + band * bandW;
                int bx1 = Math.Min(bx0 + bandW, x1);
                float acc = 0;
                for (int sub = 0; sub < _ds; sub++)
                {
                    int rowBase = (pr * _ds + sub) * w * 4;
                    float s = 0;
                    for (int x = bx0; x < bx1; x++)
                    {
                        int i = rowBase + x * 4;
                        s += buf[i] + buf[i + 1] + buf[i + 2];   // B+G+R（与灰度等价的通道均值）
                    }
                    acc += s / (3f * (bx1 - bx0));
                }
                prof[pr * k + band] = acc / _ds;
            }
        }
        return prof;
    }

    /// <summary>纵向平滑([1,2,3,2,1]/9)后中心差分 → (rows-5, K)。</summary>
    private static float[] SmoothDiff(float[] prof, int rows)
    {
        int k = ProfileBands;
        int outRows = rows - 5;
        if (outRows <= 0) return Array.Empty<float>();
        var sm = new float[(rows - 4) * k];
        for (int r = 0; r < rows - 4; r++)
            for (int c = 0; c < k; c++)
                sm[r * k + c] = (prof[r * k + c] + 2 * prof[(r + 1) * k + c] + 3 * prof[(r + 2) * k + c]
                               + 2 * prof[(r + 3) * k + c] + prof[(r + 4) * k + c]) / 9f;
        var outArr = new float[outRows * k];
        for (int r = 0; r < outRows; r++)
            for (int c = 0; c < k; c++)
                outArr[r * k + c] = sm[(r + 1) * k + c] - sm[r * k + c];
        return outArr;
    }

    private static double StdDev(float[] v)
    {
        if (v.Length == 0) return 0;
        double mean = 0; foreach (var x in v) mean += x; mean /= v.Length;
        double var = 0; foreach (var x in v) { double d = x - mean; var += d * d; }
        return Math.Sqrt(var / v.Length);
    }

    /// <summary>展平 NCC（前 n 个元素）。null = 无纹理不可判。</summary>
    private static double? Ncc(float[] a, float[] b, int n)
    {
        n = Math.Min(n, Math.Min(a.Length, b.Length));
        if (n <= 8) return null;
        double ma = 0, mb = 0;
        for (int i = 0; i < n; i++) { ma += a[i]; mb += b[i]; }
        ma /= n; mb /= n;
        double dot = 0, na = 0, nb = 0;
        for (int i = 0; i < n; i++)
        {
            double da = a[i] - ma, db = b[i] - mb;
            dot += da * db; na += da * da; nb += db * db;
        }
        double den = Math.Sqrt(na * nb);
        if (den < 1e-9) return null;
        return dot / den;
    }

    /// <summary>FFT 全滞后 NCC：B 相对 A 向下偏移 dy 的 NCC，dy∈[-(rows-mo), rows-mo]。</summary>
    private static (int[] lags, double[] ncc) NccAllLags(float[] a, float[] b, int rows, int minOverlap)
    {
        int k = ProfileBands;
        int maxDy = rows - minOverlap;
        var lags = new int[2 * maxDy + 1];
        for (int i = 0; i < lags.Length; i++) lags[i] = i - maxDy;

        int n = 1;
        while (n < 2 * rows) n <<= 1;

        // 累加各列互相关谱: SUM_k FA_k · conj(FB_k)，一次逆变换得 cc[dy]
        var accRe = new double[n]; var accIm = new double[n];
        var re = new double[n]; var im = new double[n];
        var reB = new double[n]; var imB = new double[n];
        for (int c = 0; c < k; c++)
        {
            Array.Clear(im); Array.Clear(imB);
            for (int i = 0; i < n; i++) re[i] = i < rows ? a[i * k + c] : 0;
            for (int i = 0; i < n; i++) reB[i] = i < rows ? b[i * k + c] : 0;
            Fft(re, im, false);
            Fft(reB, imB, false);
            for (int i = 0; i < n; i++)
            {
                double ar = re[i], ai = im[i], br = reB[i], bi = -imB[i];
                accRe[i] += ar * br - ai * bi;
                accIm[i] += ar * bi + ai * br;
            }
        }
        Fft(accRe, accIm, true);   // 逆变换（内部已除 N）

        // 前缀和（行内先对 K 求和）
        var ca = new double[rows + 1]; var caa = new double[rows + 1];
        var cb = new double[rows + 1]; var cbb = new double[rows + 1];
        for (int r = 0; r < rows; r++)
        {
            double sa = 0, qa = 0, sb = 0, qb = 0;
            for (int c = 0; c < k; c++)
            {
                double va = a[r * k + c], vb = b[r * k + c];
                sa += va; qa += va * va; sb += vb; qb += vb * vb;
            }
            ca[r + 1] = ca[r] + sa; caa[r + 1] = caa[r] + qa;
            cb[r + 1] = cb[r] + sb; cbb[r + 1] = cbb[r] + qb;
        }

        var ncc = new double[lags.Length];
        for (int idx = 0; idx < lags.Length; idx++)
        {
            int dy = lags[idx];
            int ov = rows - Math.Abs(dy);
            double cnt = (double)ov * k;
            double sA, qA, sB, qB;
            if (dy >= 0)
            {
                sA = ca[rows] - ca[dy]; qA = caa[rows] - caa[dy];
                sB = cb[rows - dy]; qB = cbb[rows - dy];
            }
            else
            {
                sA = ca[rows + dy]; qA = caa[rows + dy];
                sB = cb[rows] - cb[-dy]; qB = cbb[rows] - cbb[-dy];
            }
            int ccIdx = ((dy % n) + n) % n;
            double cc = accRe[ccIdx];
            double num = cc - sA * sB / cnt;
            double va2 = qA - sA * sA / cnt;
            double vb2 = qB - sB * sB / cnt;
            double den = Math.Sqrt(Math.Max(va2 * vb2, 0));
            ncc[idx] = (double.IsFinite(den) && den > cnt * 0.05) ? num / Math.Max(den, 1e-9) : -2.0;
        }
        return (lags, ncc);
    }

    /// <summary>迭代基-2 复数 FFT（inverse=true 时含 1/N 归一）。n 必须为 2 的幂。</summary>
    private static void Fft(double[] re, double[] im, bool inverse)
    {
        int n = re.Length;
        // 位反转置换
        for (int i = 1, j = 0; i < n; i++)
        {
            int bit = n >> 1;
            for (; (j & bit) != 0; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j)
            {
                (re[i], re[j]) = (re[j], re[i]);
                (im[i], im[j]) = (im[j], im[i]);
            }
        }
        for (int len = 2; len <= n; len <<= 1)
        {
            double ang = 2 * Math.PI / len * (inverse ? 1 : -1);
            double wRe = Math.Cos(ang), wIm = Math.Sin(ang);
            for (int i = 0; i < n; i += len)
            {
                double curRe = 1, curIm = 0;
                for (int j = 0; j < len / 2; j++)
                {
                    int p = i + j, q = i + j + len / 2;
                    double tRe = re[q] * curRe - im[q] * curIm;
                    double tIm = re[q] * curIm + im[q] * curRe;
                    re[q] = re[p] - tRe; im[q] = im[p] - tIm;
                    re[p] += tRe; im[p] += tIm;
                    double nRe = curRe * wRe - curIm * wIm;
                    curIm = curRe * wIm + curIm * wRe;
                    curRe = nRe;
                }
            }
        }
        if (inverse)
        {
            for (int i = 0; i < n; i++) { re[i] /= n; im[i] /= n; }
        }
    }

    private static double Median(List<double> v)
    {
        var s = v.OrderBy(x => x).ToList();
        int m = s.Count / 2;
        return s.Count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2;
    }
}
