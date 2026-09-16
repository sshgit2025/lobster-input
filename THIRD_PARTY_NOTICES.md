# 第三方依赖和资源

根目录 MIT 许可证仅适用于本项目原创内容。第三方软件和数据仍受各自许可证约束。

- **rime-ice（雾凇拼音）**：移动端基础拼音词库的来源和构建说明见 `lobster-input-android/docs/pinyin-dict/README.md`，上游为 https://github.com/iDvel/rime-ice 。上游仓库声明为 GPL-3.0，完整文本保存在 [licenses/rime-ice-GPL-3.0.txt](licenses/rime-ice-GPL-3.0.txt)。本仓库的拼音词库是经过格式转换的派生资源，不能标记为 MIT；来源和转换方法见上述构建文档。
- **语言模型统计资源**：`char_bigram.txt` 和 `word_bigram.txt` 的构建记录指向 Leipzig 新闻/维基语料及 OPUS OpenSubtitles，参见 `lobster-input-android/tools/keyboard-verify/SENTENCE_LM_HANDOFF.md`。这些派生数据不能仅依据项目 MIT 推定具有相同授权；重新分发时需核对对应语料版本的许可、署名及来源记录。
- **可选扩展词库**：三个移动端的 `custom_dict.txt` 仅包含本项目编写的少量示例。完整词库不随本仓库发布。`tools/keyboard-verify` 内生成工具可能使用额外语料或外部数据，运行前应自行核对各来源的许可和再分发条件。
- **Sparkle**：macOS 自动更新依赖，见 https://github.com/sparkle-project/Sparkle 。保留其适用许可证和版权声明。
- **Rajdhani 字体**：来源为 Google Fonts 的 Rajdhani 字体项目，按 SIL Open Font License 分发，许可文本见 [licenses/Rajdhani-OFL.txt](licenses/Rajdhani-OFL.txt)。
- 历史 `Orbitron-Black.ttf` / `Orbitron-Bold.ttf` 实为下载失败的 HTML，未作为字体或源码分发。
- **Inno Setup 中文语言文件**：上游署名为 Zhenghan Yang (Kira)，来源 https://github.com/kira-96/Inno-Setup-Chinese-Simplified-Translation ，保留原始译者署名及联系方式；上游 MIT 许可文本见 [licenses/Inno-Setup-Chinese-Translation-MIT.txt](licenses/Inno-Setup-Chinese-Translation-MIT.txt)。仓库内繁体与粤语文件以其文件头注明的来源为基础调整，不能替代原始署名。
- **其他字体、图标、安装器语言文件**：这些资源可能有独立许可，分发应用时应同时保留原始许可；项目 MIT 不覆盖第三方资源。
- **依赖清单**：Python 依赖见各 `requirements.txt` / `pyproject.toml` / `uv.lock`，Web 依赖见 `package.json` / `package-lock.json`，Android 和 Apple 依赖见项目构建配置。升级或分发时请核对所用版本的许可证。

如发现资源来源或许可记录缺失，请向维护者反馈；不能仅以本项目采用 MIT 推定某项第三方资源同样适用 MIT。
