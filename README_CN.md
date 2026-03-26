# OpenTypeNo

[English](README.md) | [日本語](README_JP.md)

**免费、开源、隐私优先的 macOS 语音输入工具。**

![OpenTypeNo 宣传图](assets/hero.webp)

一个极简的 macOS 语音输入应用。按下 Control 说话，OpenTypeNo 在本地完成转录，然后自动粘贴到你正在使用的应用中——全程不到一秒。

本项目是对原版 [TypeNo](https://typeno.com) 项目的延续和扩展，在此对其表示特别感谢！

特别感谢 [marswave ai 的 coli 项目](https://github.com/marswaveai/coli) 提供本地语音识别能力。

## 使用方式

1. **短按 Control**（默认快捷键，可自定义）开始录音
2. **再短按 Control** 停止
3. 文字自动转录并粘贴到当前应用（同时复制到剪贴板）

OpenTypeNo 尽量保持在后台运行，不打扰你的工作流。

## 安装

### 方式一：直接下载

- [下载 OpenTypeNo for macOS](https://github.com/vivilin-ai/OpenTypeNo/releases/latest)
- 下载最新的 `OpenTypeNo.app.zip`
- 解压后将 `OpenTypeNo.app` 拖到 `/Applications`
- 打开 OpenTypeNo

OpenTypeNo 已通过 Apple 签名和公证，可以直接打开使用。

### 安装语音识别引擎

OpenTypeNo 使用 [coli](https://github.com/marswaveai/coli) 进行本地语音识别：

```bash
npm install -g @marswave/coli
```

如果未安装 Coli，OpenTypeNo 会在应用内弹出引导提示。

### 首次启动

OpenTypeNo 需要两个一次性授权：
- **麦克风** — 录制你的声音
- **辅助功能** — 将文字粘贴到应用中

首次启动时，应用会自动引导你完成授权。

### 方式二：从源码构建

```bash
git clone https://github.com/vivilin-ai/OpenTypeNo.git
cd OpenTypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

应用位于 `dist/OpenTypeNo.app`。移动到 `/Applications/` 以获得持久权限。

## 操作方式 & 功能

| 操作 | 触发方式 |
|---|---|
| 开始/停止录音 | 短按 `Control`（可自定义：⌃, ⌥, ⌘, ⇧） |
| 触发模式 | 可选择单击（Single Tap）或双击（Double Tap） |
| 开始/停止录音 | 菜单栏 → Record |
| 转录文件 | 拖拽 `.m4a`/`.mp3`/`.wav`/`.aac` 到菜单栏图标 |
| 打开设置 | 菜单栏 → Settings...（`,`） |
| 检查更新 | 菜单栏 → Check for Updates... |
| 退出 | 菜单栏 → Quit（`⌘Q`） |

### 高级设置

在菜单栏中打开设置窗口，你可以配置：
- **转录模式**：选择本地优先保护隐私的转录（`coli`）或准确率更高的**云端 ASR**（OpenAI Whisper，需要 API Key）。
- **后处理功能**：使用大语言模型（支持 DeepSeek 和 Kimi，需要 API Key）自动添加标点符号、删除语助词并纠正明显的错别字。

## 设计理念

OpenTypeNo 专注于核心流程：语音 → 文字 → 粘贴。我们将多余的 UI 降至最低，最快的打字方式就是不打字。

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=vivilin-ai/OpenTypeNo&type=Date)](https://star-history.com/#vivilin-ai/OpenTypeNo&Date)

## 许可证

GNU General Public License v3.0
