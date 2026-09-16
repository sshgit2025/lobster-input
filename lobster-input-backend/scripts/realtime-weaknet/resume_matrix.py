"""弱网断连续传的矩阵式验证:严格模拟安卓端实现的算法
(前缀冻结 + 1.5s 已发送尾巴重放 + 断链间隙音频缓冲 + 归一化重叠裁剪拼接),
在多断点/多间隙/多次断连/多语料下,与完整不断连基线做归一化 diff,
自动检出重复、缺失、错乱。

用法: venv/bin/python resume_matrix.py
"""
from __future__ import annotations

import difflib
import json
import socket
import struct
import threading
import time
import uuid
import wave
from collections import deque

from repro_weaknet import CHUNK_BYTES, CHUNK_MS, login, open_ws

TAIL_LIMIT_BYTES = 48_000  # 1.5s,与安卓 RealtimeResume.SENT_TAIL_LIMIT_BYTES 一致
BYTES_PER_SEC = 32_000


def norm(s: str) -> str:
    return "".join(ch for ch in s if ch.isalnum())


def merge_with_overlap(prefix: str, tail: str) -> str:
    """与安卓 RealtimeResume.mergeWithOverlap 逐行同构"""
    if not prefix:
        return tail
    if not tail:
        return prefix
    np_, nt = norm(prefix), norm(tail)
    best = 0
    k = min(len(np_), len(nt))
    while k > 0:
        if np_.endswith(nt[:k]):
            best = k
            break
        k -= 1
    if best == 0:
        return prefix + tail
    count = 0
    cut = len(tail)
    for i, ch in enumerate(tail):
        if ch.isalnum():
            count += 1
        if count >= best:
            cut = i + 1
            break
    return prefix + tail[cut:]


class RtSession:
    """一个实时识别 ws 会话:后台读线程维护最新 partial/最终文本"""

    def __init__(self, token: str):
        self.sid = f"android_{uuid.uuid4()}"
        self.ws = open_ws(token, self.sid)
        while True:
            data = json.loads(self.ws.recv(timeout=15))
            if data.get("type") == "ready":
                break
        self.latest = ""
        self.final: str | None = None
        self.finished = threading.Event()
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        try:
            while True:
                data = json.loads(self.ws.recv(timeout=95))
                t = data.get("type")
                if t in ("partial", "completed") and data.get("text"):
                    self.latest = data["text"]
                elif t == "finished":
                    self.final = data.get("text") or self.latest
                    break
                elif t == "error":
                    break
        except Exception:
            pass
        finally:
            self.finished.set()

    def send(self, chunk: bytes):
        self.ws.send(chunk)

    def finish(self) -> str:
        self.ws.send(json.dumps({"type": "finish"}))
        self.finished.wait(timeout=95)
        try:
            self.ws.close()
        except Exception:
            pass
        return (self.final or self.latest).strip()

    def abort_rst(self):
        try:
            raw = self.ws.socket
            raw.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            raw.close()
        except Exception:
            pass


def run_baseline(token: str, pcm: bytes) -> str:
    sess = RtSession(token)
    pos = 0
    while pos < len(pcm):
        sess.send(pcm[pos:pos + CHUNK_BYTES])
        pos += CHUNK_BYTES
        time.sleep(CHUNK_MS / 1000)
    return sess.finish()


def run_resume_case(token: str, pcm: bytes, break_fracs: list[float], gap_s: float) -> tuple[str, list[float]]:
    """严格按安卓实现模拟:返回(拼接全文, 各次重连耗时ms)"""
    breaks = sorted(int(f * len(pcm)) // CHUNK_BYTES * CHUNK_BYTES for f in break_fracs)
    prefix = ""
    sent_tail: deque[bytes] = deque()
    tail_bytes = 0

    def record_tail(chunk: bytes):
        nonlocal tail_bytes
        sent_tail.append(chunk)
        tail_bytes += len(chunk)
        while tail_bytes > TAIL_LIMIT_BYTES and sent_tail:
            tail_bytes -= len(sent_tail.popleft())

    sess = RtSession(token)
    reconnect_ms: list[float] = []
    pos = 0
    bi = 0
    while pos < len(pcm):
        chunk = pcm[pos:pos + CHUNK_BYTES]
        sess.send(chunk)
        record_tail(chunk)
        pos += len(chunk)
        time.sleep(CHUNK_MS / 1000)
        if bi < len(breaks) and pos >= breaks[bi]:
            bi += 1
            # 给 partial 一点到达时间(真实场景 partial 持续到达,断链检测也非瞬时)
            time.sleep(0.15)
            sess.abort_rst()
            t0 = time.time()
            prefix = merge_with_overlap(prefix, sess.latest.strip())
            # 断链间隙:录音继续,进入待发缓冲
            gap_bytes = min(int(gap_s * BYTES_PER_SEC) // CHUNK_BYTES * CHUNK_BYTES, len(pcm) - pos)
            pending = list(sent_tail) + [
                pcm[p:p + CHUNK_BYTES] for p in range(pos, pos + gap_bytes, CHUNK_BYTES)
            ]
            pos += gap_bytes
            sent_tail.clear()
            tail_bytes = 0
            time.sleep(gap_s)  # 模拟弱网中断持续时间
            sess = RtSession(token)  # 重连新会话
            reconnect_ms.append((time.time() - t0 - gap_s) * 1000)
            for c in pending:  # 尾巴+缺口快速冲刷(对应 flushBufferedRealtimeAudio)
                sess.send(c)
                record_tail(c)
    final = sess.finish()
    return merge_with_overlap(prefix, final), reconnect_ms


def diff_report(baseline: str, merged: str) -> str:
    nb, nm = norm(baseline), norm(merged)
    if nb == nm:
        return "PERFECT(与基线完全一致)"
    sm = difflib.SequenceMatcher(None, nb, nm)
    issues = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op == "delete":
            issues.append(f"缺失[{nb[i1:i2]}]")
        elif op == "insert":
            issues.append(f"多出[{nm[j1:j2]}]")
        elif op == "replace":
            issues.append(f"替换[{nb[i1:i2]}→{nm[j1:j2]}]")
    ratio = sm.ratio()
    return f"相似度{ratio:.3f} " + " ".join(issues)


def main():
    token = login()
    samples = {}
    for name in ("speech", "speech2"):
        w = wave.open(f"{name}.wav")
        samples[name] = w.readframes(w.getnframes())

    print("== 先跑不断连基线 ==")
    baselines = {}
    for name, pcm in samples.items():
        baselines[name] = run_baseline(token, pcm)
        print(f"[baseline:{name}] {baselines[name]!r}")
        time.sleep(1)

    cases = [
        ("前段断连",   [0.25],        0.3),
        ("中段断连",   [0.50],        0.3),
        ("后段断连",   [0.75],        0.3),
        ("长间隙断连", [0.50],        1.5),
        ("两次断连",   [0.33, 0.66],  0.3),
    ]
    results = []
    for name, pcm in samples.items():
        for case_name, fracs, gap in cases:
            merged, recon = run_resume_case(token, pcm, fracs, gap)
            verdict = diff_report(baselines[name], merged)
            results.append((name, case_name, merged, recon, verdict))
            print(f"\n[{name}/{case_name}] 重连耗时={[f'{m:.0f}ms' for m in recon]}")
            print(f"  拼接: {merged!r}")
            print(f"  判定: {verdict}")
            time.sleep(1)

    print("\n==================== 汇总 ====================")
    for name, case_name, _, recon, verdict in results:
        ok = "✅" if verdict.startswith("PERFECT") or "相似度0.9" in verdict else "⚠️"
        print(f"{ok} {name:8s} {case_name:6s} 重连={','.join(f'{m:.0f}ms' for m in recon):>15s}  {verdict}")


if __name__ == "__main__":
    main()
