# 拼音输入词库构建

本目录脚本基于成熟开源词库 **rime-ice(雾凇拼音)** 生成键盘所用紧凑词库。

## 词库来源
- 仓库: https://github.com/iDvel/rime-ice (长期维护的简体中文 RIME 词库)
- 文件: `cn_dicts/8105.dict.yaml`(单字, 准确字频) + `cn_dicts/base.dict.yaml`(基础词库, 词频准确, 拼音人工标注)
- 拼音 ü/üe 已写作 v/ve, 与用户实际敲键一致; 多音字标注正确(重庆=chongqing, 银行=yinhang)
- 许可: rime-ice 上游仓库使用 GPL-3.0。这里的词库经过格式转换；本项目 MIT 许可证不覆盖这些派生词库。完整许可见根目录 `licenses/rime-ice-GPL-3.0.txt`。

## 复现
```bash
curl -o rime_8105.yaml https://raw.githubusercontent.com/iDvel/rime-ice/main/cn_dicts/8105.dict.yaml
curl -o rime_base.yaml https://raw.githubusercontent.com/iDvel/rime-ice/main/cn_dicts/base.dict.yaml
python3 build_dict.py   # 输出 pinyin_dict.txt / syllables.txt
```

## 输出格式
- `pinyin_dict.txt`: 每行 `拼音连写key \t 词1 词频等级1 词2 词频等级2 ...`(候选按词频降序; 词频等级=log2(freq)量化, 供整句最优切分)
  - **全拼主表绝不按 key 截断候选**: 曾经 top-30/key 导致 yi 音节第 31+ 位单字(咦/呓/翊…)整库丢失、用户无论如何打不出(2026-07 修复)。全量保留仅 +0.02MB(全库超 30 候选的 key 仅 85 个); 可达性由客户端候选滚动/展开面板(等效 RIME 翻页)+ 引擎精确候选保底(takeWithExactGuarantee)保证。
  - `initials_dict.txt` 简拼表保持 top-N 截断: 简拼是重码"预测"通道, 业界只出高频; 全拼通道始终可打出任意字, 不影响可达性。
- `syllables.txt`: 合法拼音音节集合(音节切分与 9 宫格 T9 还原用)
- 两端(Android assets / iOS bundle)复用同一份文件; 运行时按 key 排序数组 + 二分查找加载, 内存友好。
