using System.Windows.Threading;

namespace LobsterInput.Helpers;

/// <summary>
/// 实时识别"打字机"平滑层(悬浮窗预览用)。
///
/// 上游(火山 Seed-ASR)在实时输入下吐字是突发的:前沿大约每 ~390ms 跳 ~2 个字,并伴随
/// 偶发 ~1 秒停顿。直接整段替换显示就会"一顿一顿"。本组件把突发到达的 partial 目标文本,
/// 转换成稳定逐字揭示的连续流,改善"边说边出字"的流畅观感。
///
/// 安全原则(必须遵守,勿破坏业务):
///  - 只驱动悬浮窗显示文本,绝不参与最终提交;最终权威文本仍由 RecordingWorkflow 读取完整的
///    realtimeSession.Transcript / 后端 final 决策,并经粘贴提交,与本组件无关。
///  - <see cref="SetTarget"/> 每次都用"最新 target 的前缀"重绘,因此上游对已显示区域的"纠正 /
///    整句替换"会在下一 tick(≤30ms)立即反映;不会丢字、不会显示过期文本。
///  - <see cref="Flush"/> 立即补齐到最新 target(停止 / 收尾时调用)。
///  - 揭示速率随积压自适应(积压越多揭示越快,数百毫秒内追平最新 partial)。
///  - revealed==0 时不渲染空串。
///
/// 线程约束:必须在 UI 线程使用(DispatcherTimer 绑定传入的 Dispatcher,渲染回调编辑 WPF 控件)。
/// </summary>
public sealed class TypewriterReveal
{
    private readonly Action<string> _render;
    private readonly DispatcherTimer _timer;
    private string _target = "";
    private int _revealed;
    private long _lastRevealAt;

    public TypewriterReveal(Dispatcher dispatcher, Action<string> render)
    {
        _render = render;
        _timer = new DispatcherTimer(DispatcherPriority.Normal, dispatcher)
        {
            Interval = TimeSpan.FromMilliseconds(TickMs)
        };
        _timer.Tick += (_, _) => Step();
    }

    /// <summary>设置最新目标文本(来自 partial / completed)。已显示区域内的纠正会立即生效。</summary>
    public void SetTarget(string? text)
    {
        _target = text ?? "";
        if (_revealed > _target.Length) _revealed = _target.Length;
        ClampBoundary();
        if (_target.Length == 0)
        {
            _timer.Stop();
            _render("");
            return;
        }
        if (_revealed > 0) _render(CurrentPrefix());
        if (_revealed < _target.Length) StartTimer();
    }

    /// <summary>立即补齐到最新目标并停止动画(停止 / 收尾时调用)。</summary>
    public void Flush()
    {
        _timer.Stop();
        _revealed = _target.Length;
        _render(_target);
    }

    /// <summary>清空状态并停止动画(显示清理由调用方负责)。</summary>
    public void Reset()
    {
        _timer.Stop();
        _target = "";
        _revealed = 0;
        _lastRevealAt = 0;
    }

    private void StartTimer()
    {
        if (_timer.IsEnabled) return;
        _lastRevealAt = NowMs();
        _timer.Start();
    }

    private void Step()
    {
        if (_revealed >= _target.Length)
        {
            _timer.Stop();
            return;
        }

        var now = NowMs();
        var changed = false;
        while (_revealed < _target.Length)
        {
            var backlog = _target.Length - _revealed;
            long interval = backlog >= 8 ? 22 : (backlog >= 4 ? 55 : 120);
            if (now - _lastRevealAt < interval) break;
            _revealed++;
            // 跨过 UTF-16 代理对低位,避免切断 emoji 等字符。
            if (_revealed < _target.Length
                && char.IsHighSurrogate(_target[_revealed - 1])
                && char.IsLowSurrogate(_target[_revealed]))
            {
                _revealed++;
            }
            _lastRevealAt += interval;
            changed = true;
        }

        if (changed) _render(CurrentPrefix());
        if (_revealed >= _target.Length) _timer.Stop();
    }

    private void ClampBoundary()
    {
        if (_revealed > 0 && _revealed < _target.Length && char.IsLowSurrogate(_target[_revealed]))
        {
            _revealed--;
        }
    }

    private string CurrentPrefix()
    {
        if (_revealed <= 0) return "";
        if (_revealed >= _target.Length) return _target;
        return _target.Substring(0, _revealed);
    }

    private static long NowMs() => Environment.TickCount64;

    private const double TickMs = 30;
}
