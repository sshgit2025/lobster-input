"""模拟安卓端实时流式识别客户端,复现弱网下 "Software caused connection abort" 类报错。

场景:
  baseline  正常流式识别 → finish → 等 finished        (验证链路与鉴权)
  abort     中途 SO_LINGER=0 RST 断开                   (复现服务端 connect-无-finished 日志特征)
  weaknet   经本地 TCP 代理连接,中途代理向客户端发 RST  (模拟弱网链路中断,观察客户端 send 抛出的原始 socket 错误)

用法: venv/bin/python repro_weaknet.py <baseline|abort|weaknet>
"""
from __future__ import annotations

import json
import socket
import ssl
import struct
import sys
import threading
import time
import urllib.request
import uuid
import wave

from websockets.sync.client import connect

HOST = "api.example.com"
BASE = f"https://{HOST}/lobster"
EMAIL = "developer@example.com"
FIXED_CODE = "123456"
PLATFORM = "android"
CHUNK_MS = 100
CHUNK_BYTES = 16000 * 2 * CHUNK_MS // 1000  # 3200B = 100ms @16k s16le mono

SSL_CTX = ssl.create_default_context()
SSL_CTX.check_hostname = False
SSL_CTX.verify_mode = ssl.CERT_NONE  # 本机 CA 链不全,仅测试用


def http_post(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Client-Platform": PLATFORM,
            "Accept-Language": "zh",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, context=SSL_CTX, timeout=15) as resp:
        return json.loads(resp.read())


def login() -> str:
    import os
    if os.path.exists("token.cache"):
        tok = open("token.cache").read().strip()
        if tok:
            print("[login] reuse cached token")
            return tok
    try:
        http_post("/api/v1/auth/send-code", {"email": EMAIL})
    except urllib.error.HTTPError as e:  # 频率限制时直接尝试固定码
        print(f"[login] send-code HTTP {e.code}: {e.read()[:200]}")
    data = http_post("/api/v1/auth/verify", {"email": EMAIL, "code": FIXED_CODE})
    print(f"[login] ok email={data['email']} tier={data['tier']}")
    open("token.cache", "w").write(data["token"])
    return data["token"]


def load_pcm() -> bytes:
    w = wave.open("speech.wav")
    assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
    return w.readframes(w.getnframes())


def ws_url(session_id: str) -> str:
    return (
        f"wss://{HOST}/lobster/api/v2/audio/android/asr/realtime"
        f"?language=zh&sample_rate=16000&audio_format=pcm&vad=true"
        f"&max_duration_sec=60&asr_session_id={session_id}"
    )


def reader(ws, tag: str):
    try:
        while True:
            msg = ws.recv()
            if isinstance(msg, bytes):
                continue
            data = json.loads(msg)
            t = data.get("type")
            print(f"[{tag}] <- {t}: {data.get('text') or data.get('message') or ''!s}"[:160])
            if t in ("finished", "error"):
                break
    except Exception as e:
        print(f"[{tag}] reader ended: {type(e).__name__}: {e}")


def open_ws(token: str, session_id: str, sock=None):
    kwargs = dict(
        additional_headers={
            "Authorization": f"Bearer {token}",
            "X-Client-Platform": PLATFORM,
            "Accept-Language": "zh",
            "X-Accept-Language": "zh",
        },
        open_timeout=15,
        max_size=None,
    )
    if sock is not None:
        return connect(ws_url(session_id), sock=sock, ssl=SSL_CTX,
                       server_hostname=HOST, **kwargs)
    return connect(ws_url(session_id), ssl=SSL_CTX, **kwargs)


def wait_ready(ws, tag: str):
    while True:
        data = json.loads(ws.recv(timeout=15))
        print(f"[{tag}] <- {data.get('type')}: {json.dumps(data, ensure_ascii=False)[:160]}")
        if data.get("type") == "ready":
            return


def stream(ws, pcm: bytes, seconds: float, tag: str) -> int:
    """按实时节奏发送音频,返回已发送字节数;send 失败时抛出异常。"""
    sent = 0
    n_chunks = int(seconds * 1000 / CHUNK_MS)
    for i in range(n_chunks):
        chunk = pcm[i * CHUNK_BYTES:(i + 1) * CHUNK_BYTES]
        if not chunk:
            break
        ws.send(chunk)
        sent += len(chunk)
        time.sleep(CHUNK_MS / 1000)
    return sent


def scenario_baseline(token: str, pcm: bytes):
    sid = f"android_{uuid.uuid4()}"
    print(f"[baseline] session={sid}")
    ws = open_ws(token, sid)
    wait_ready(ws, "baseline")
    t = threading.Thread(target=reader, args=(ws, "baseline"), daemon=True)
    t.start()
    stream(ws, pcm, 5.9, "baseline")
    ws.send(json.dumps({"type": "finish"}))
    t.join(timeout=95)
    ws.close()
    print("[baseline] done")


def scenario_abort(token: str, pcm: bytes):
    sid = f"android_{uuid.uuid4()}"
    print(f"[abort] session={sid}")
    ws = open_ws(token, sid)
    wait_ready(ws, "abort")
    t = threading.Thread(target=reader, args=(ws, "abort"), daemon=True)
    t.start()
    stream(ws, pcm, 2.0, "abort")
    # 模拟弱网:TCP 层直接 RST,不发 close 帧
    raw = ws.socket
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    raw.close()
    print(f"[abort] RST sent after 2s of audio; session={sid}")
    print("[abort] 现在检查服务端日志应出现 connect 无 finished 的特征")


class KillableProxy(threading.Thread):
    """本地 TCP 代理:127.0.0.1:19443 -> uat:443,kill() 时向客户端发 RST 并停止转发。"""

    def __init__(self):
        super().__init__(daemon=True)
        self.lsock = socket.create_server(("127.0.0.1", 19443))
        self.client_conn = None
        self.upstream = None
        self.dead = False

    def run(self):
        conn, _ = self.lsock.accept()
        self.client_conn = conn
        up = socket.create_connection((HOST, 443), timeout=15)
        self.upstream = up
        threading.Thread(target=self.pipe, args=(conn, up), daemon=True).start()
        threading.Thread(target=self.pipe, args=(up, conn), daemon=True).start()

    def pipe(self, src, dst):
        try:
            while not self.dead:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass

    def kill(self):
        self.dead = True
        for s in (self.client_conn, self.upstream):
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                s.close()
            except OSError:
                pass


def scenario_weaknet(token: str, pcm: bytes):
    sid = f"android_{uuid.uuid4()}"
    print(f"[weaknet] session={sid}")
    proxy = KillableProxy()
    proxy.start()
    time.sleep(0.2)
    sock = socket.create_connection(("127.0.0.1", 19443), timeout=15)
    ws = open_ws(token, sid, sock=sock)
    wait_ready(ws, "weaknet")
    t = threading.Thread(target=reader, args=(ws, "weaknet"), daemon=True)
    t.start()

    def killer():
        time.sleep(2.0)
        print("[weaknet] !! 代理切断链路(模拟弱网中断,向客户端发 RST)")
        proxy.kill()

    threading.Thread(target=killer, daemon=True).start()
    try:
        stream(ws, pcm, 5.9, "weaknet")
        ws.send(json.dumps({"type": "finish"}))
        print("[weaknet] 发送全程无异常(异常可能出现在 reader)")
    except Exception as e:
        print(f"[weaknet] ** 客户端发送音频帧失败: {type(e).__name__}: {e}")
        cause = e.__cause__ or e.__context__
        while cause is not None:
            print(f"[weaknet] ** 底层原因: {type(cause).__name__}: {cause}")
            cause = cause.__cause__ or cause.__context__
        # 对底层 socket 直接写,拿到 OS 层原始错误文案(OkHttp t.message 的来源)
        try:
            sock.send(b"\x00" * 16)
            time.sleep(0.2)
            sock.send(b"\x00" * 16)
        except OSError as ose:
            print(f"[weaknet] ** OS 层 socket 错误: errno={ose.errno} message={ose.strerror!r}")
        print("[weaknet] ** 安卓 OkHttp 在同样场景下 onFailure 的 t.message 即上述底层"
              " socket 错误文案(Android/Linux 上常见为 'Software caused connection abort')")
    t.join(timeout=5)


def _norm(s: str) -> str:
    """去标点/空白归一化,用于重叠匹配"""
    return "".join(ch for ch in s if ch.isalnum())


def merge_with_overlap(prefix: str, tail_text: str) -> str:
    """把重放尾巴产生的重叠识别文本裁掉:找 prefix 归一化后缀与 tail_text 归一化前缀的最长重叠。"""
    np, nt = _norm(prefix), _norm(tail_text)
    best = 0
    for k in range(min(len(np), len(nt)), 0, -1):
        if np.endswith(nt[:k]):
            best = k
            break
    if best == 0:
        return prefix + tail_text
    # 在 tail_text 原文中找到覆盖 best 个归一化字符的切点
    count = 0
    cut = 0
    for i, ch in enumerate(tail_text):
        if ch.isalnum():
            count += 1
        if count >= best:
            cut = i + 1
            break
    return prefix + tail_text[cut:]


def scenario_resume2(token: str, pcm: bytes):
    """增强版续传:断连后重放最近 1.5s 已发送音频尾巴,再用重叠裁剪拼接,消除接缝丢字。"""
    cut_bytes = int(2.0 * 32000)
    tail_bytes = int(1.5 * 32000)
    sid_a = f"android_{uuid.uuid4()}"
    print(f"[resume2] 会话A={sid_a}")
    ws_a = open_ws(token, sid_a)
    wait_ready(ws_a, "resume2.A")
    a_partial = {"text": ""}

    def reader_a():
        try:
            while True:
                data = json.loads(ws_a.recv())
                if data.get("type") in ("partial", "completed") and data.get("text"):
                    a_partial["text"] = data["text"]
        except Exception:
            pass

    threading.Thread(target=reader_a, daemon=True).start()
    sent = 0
    while sent < cut_bytes:
        ws_a.send(pcm[sent:sent + CHUNK_BYTES])
        sent += CHUNK_BYTES
        time.sleep(CHUNK_MS / 1000)
    raw = ws_a.socket
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    raw.close()
    t_break = time.time()
    prefix = a_partial["text"]
    print(f"[resume2] !! 断连,A 前缀: {prefix!r}")

    time.sleep(0.3)
    sid_b = f"android_{uuid.uuid4()}"
    ws_b = open_ws(token, sid_b)
    wait_ready(ws_b, "resume2.B")
    print(f"[resume2] 重连+ready {((time.time()-t_break)*1000):.0f}ms")

    b_final = {"text": ""}
    done_evt = threading.Event()

    def reader_b():
        try:
            while True:
                data = json.loads(ws_b.recv(timeout=95))
                t = data.get("type")
                if t in ("partial", "completed") and data.get("text"):
                    b_final["text"] = data["text"]
                elif t == "finished":
                    b_final["text"] = data.get("text") or b_final["text"]
                    break
                elif t == "error":
                    print(f"[resume2.B] error: {data.get('message')}")
                    break
        except Exception as e:
            print(f"[resume2.B] reader ended: {type(e).__name__}")
        finally:
            done_evt.set()

    threading.Thread(target=reader_b, daemon=True).start()
    # 先重放尾巴(已发送但可能未出字的音频),再续未发送部分
    replay_start = max(0, sent - tail_bytes)
    pos = replay_start
    while pos < sent:
        ws_b.send(pcm[pos:pos + CHUNK_BYTES])
        pos += CHUNK_BYTES
    while sent < len(pcm):
        ws_b.send(pcm[sent:sent + CHUNK_BYTES])
        sent += CHUNK_BYTES
        time.sleep(CHUNK_MS / 1000)
    ws_b.send(json.dumps({"type": "finish"}))
    done_evt.wait(timeout=95)
    ws_b.close()

    merged = merge_with_overlap(prefix, b_final["text"])
    print("\n=== 增强续传结果 ===")
    print(f"A 前缀    : {prefix!r}")
    print(f"B 尾巴重放: {b_final['text']!r}")
    print(f"重叠合并  : {merged!r}")
    print(f"原始播报  : '今天天气不错,我们下午一起去公园散步吧,顺便买一杯咖啡喝一喝。'")


def scenario_resume(token: str, pcm: bytes):
    """验证客户端编排的断连续传:会话A 断于 2.0s → 300ms 后新会话B 续传剩余音频,
    最终文本 = A 的最后 partial + B 的 final 拼接。上游火山无会话续传,此方案不依赖它。"""
    cut_bytes = int(2.0 * 32000)  # 2.0s 处断连
    # ---- 会话 A ----
    sid_a = f"android_{uuid.uuid4()}"
    print(f"[resume] 会话A={sid_a}")
    ws_a = open_ws(token, sid_a)
    wait_ready(ws_a, "resume.A")
    a_partial = {"text": ""}

    def reader_a():
        try:
            while True:
                data = json.loads(ws_a.recv())
                if data.get("type") in ("partial", "completed") and data.get("text"):
                    a_partial["text"] = data["text"]
                    print(f"[resume.A] <- {data['type']}: {data['text']}")
        except Exception as e:
            print(f"[resume.A] reader ended: {type(e).__name__}")

    ta = threading.Thread(target=reader_a, daemon=True)
    ta.start()
    sent = 0
    while sent < cut_bytes:
        ws_a.send(pcm[sent:sent + CHUNK_BYTES])
        sent += CHUNK_BYTES
        time.sleep(CHUNK_MS / 1000)
    # 模拟弱网 RST(不发 close 帧)
    raw = ws_a.socket
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    raw.close()
    t_break = time.time()
    print(f"[resume] !! 2.0s 处链路断开,A 侧已识别前缀: {a_partial['text']!r}")

    # ---- 缺口期间音频继续采集进缓冲(这里即 pcm[sent:]),300ms 后重连 ----
    time.sleep(0.3)
    sid_b = f"android_{uuid.uuid4()}"
    ws_b = open_ws(token, sid_b)
    wait_ready(ws_b, "resume.B")
    reconnect_ms = (time.time() - t_break) * 1000
    print(f"[resume] 会话B={sid_b} 重连+ready 耗时 {reconnect_ms:.0f}ms (含刻意等待300ms)")

    b_final = {"text": ""}

    def reader_b():
        try:
            while True:
                data = json.loads(ws_b.recv(timeout=95))
                t = data.get("type")
                if t in ("partial", "completed") and data.get("text"):
                    b_final["text"] = data["text"]
                    print(f"[resume.B] <- {t}: {data['text']}")
                elif t == "finished":
                    b_final["text"] = data.get("text") or b_final["text"]
                    print(f"[resume.B] <- finished: {b_final['text']}")
                    break
                elif t == "error":
                    print(f"[resume.B] <- error: {data.get('message')}")
                    break
        except Exception as e:
            print(f"[resume.B] reader ended: {type(e).__name__}")

    tb = threading.Thread(target=reader_b, daemon=True)
    tb.start()
    # 缓冲的缺口音频一次性快速冲刷(对应客户端 flushBufferedRealtimeAudio),之后恢复实时节奏
    backlog_end = sent + int(0.3 * 32000)
    while sent < backlog_end and sent < len(pcm):
        ws_b.send(pcm[sent:sent + CHUNK_BYTES])
        sent += CHUNK_BYTES
    while sent < len(pcm):
        ws_b.send(pcm[sent:sent + CHUNK_BYTES])
        sent += CHUNK_BYTES
        time.sleep(CHUNK_MS / 1000)
    ws_b.send(json.dumps({"type": "finish"}))
    tb.join(timeout=95)
    ws_b.close()

    concat = (a_partial["text"] + b_final["text"]).strip()
    print("\n=== 续传结果 ===")
    print(f"A 前缀   : {a_partial['text']!r}")
    print(f"B 续传   : {b_final['text']!r}")
    print(f"拼接全文 : {concat!r}")
    print(f"原始播报 : '今天天气不错,我们下午一起去公园散步吧,顺便买一杯咖啡喝一喝。'")

    # ---- 拼接文本走 /process 文本管线(不带 asr_session_id,避免服务端用只含后半段的 final 覆盖) ----
    req = urllib.request.Request(
        BASE + "/api/v2/audio/android/process",
        data=json.dumps({
            "operation": "transcribe",
            "text": concat,
            "client_asr_text": concat,
            "fast_mode": False,
        }).encode(),
        headers={
            "Content-Type": "application/json",
            "X-Client-Platform": PLATFORM,
            "Accept-Language": "zh",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, context=SSL_CTX, timeout=30) as resp:
        body = json.loads(resp.read())
    print(f"/process 加工结果: {body.get('result') or body.get('transcript')!r}")


def main():
    scenario = sys.argv[1] if len(sys.argv) > 1 else "baseline"
    token = login()
    pcm = load_pcm()
    print(f"[main] pcm bytes={len(pcm)} (~{len(pcm)/32000:.1f}s)")
    {
        "baseline": scenario_baseline,
        "abort": scenario_abort,
        "weaknet": scenario_weaknet,
        "resume": scenario_resume,
        "resume2": scenario_resume2,
    }[scenario](token, pcm)


if __name__ == "__main__":
    main()
