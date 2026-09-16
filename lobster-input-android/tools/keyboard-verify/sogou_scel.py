#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""搜狗细胞词库 .scel 解析(标准格式:拼音表@0x1540,词表@0x2628)。

T5 城市信息层(2026-07-10)与 T6 品牌层(2026-07-17)共用。之前 T5 的解析脚本留在会话
scratchpad 已随会话清理丢失——本文件入库为准,勿再放临时目录。

词条输出保留 scel 人工标注的音节边界(空格分隔),下游生成器不得贪心重切。
"""
import struct


def _le16(b, pos):
    return struct.unpack_from("<H", b, pos)[0]


def parse_scel(data: bytes):
    """解析 scel 字节流,yield (word, [syllable...])。坏文件抛异常由调用方跳过。"""
    if len(data) < 0x2628 or data[:4] not in (b"\x40\x15\x00\x00", b"\x41\x15\x00\x00"):
        raise ValueError("not a scel file")
    # ---- 拼音表:0x1540 起,前 4 字节为表项计数区,随后 [idx:2][len:2][utf16le 拼音] ----
    py_table = {}
    pos = 0x1540 + 4
    while pos < 0x2628:
        idx = _le16(data, pos)
        ln = _le16(data, pos + 2)
        if ln == 0 or pos + 4 + ln > 0x2628:
            break
        py_table[idx] = data[pos + 4:pos + 4 + ln].decode("utf-16le", "ignore")
        pos += 4 + ln
    # ---- 词表:0x2628 起,[同音词数:2][拼音索引区长:2][索引区][词长:2][utf16le 词][扩展长:2][扩展] ----
    pos = 0x2628
    n = len(data)
    while pos + 4 <= n:
        same = _le16(data, pos)
        py_len = _le16(data, pos + 2)
        pos += 4
        if same == 0 or py_len == 0 or py_len % 2 != 0 or pos + py_len > n:
            break
        sylls = []
        for i in range(py_len // 2):
            idx = _le16(data, pos + i * 2)
            syl = py_table.get(idx)
            if syl is None:
                sylls = None
                break
            sylls.append(syl)
        pos += py_len
        ok = sylls is not None
        for _ in range(same):
            if pos + 2 > n:
                return
            wlen = _le16(data, pos)
            pos += 2
            if pos + wlen > n:
                return
            word = data[pos:pos + wlen].decode("utf-16le", "ignore")
            pos += wlen
            if pos + 2 > n:
                return
            ext_len = _le16(data, pos)
            pos += 2 + ext_len
            if ok and word:
                yield word, list(sylls)


def parse_scel_file(path: str):
    with open(path, "rb") as f:
        data = f.read()
    yield from parse_scel(data)


if __name__ == "__main__":
    import sys
    cnt = 0
    for w, syl in parse_scel_file(sys.argv[1]):
        if cnt < 10:
            print(w, " ".join(syl))
        cnt += 1
    print("total:", cnt)
