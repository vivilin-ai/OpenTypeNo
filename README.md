# OpenTypeNo

[中文](README_CN.md) | [日本語](README_JP.md)

**A free, open source, privacy-first voice input tool for macOS.**

![OpenTypeNo hero image](assets/hero.png)

A minimal macOS voice input app. OpenTypeNo captures your voice, transcribes it locally, and pastes the result into whatever app you were using — all in under a second.

This project is a fork of the original [TypeNo](https://typeno.com) project. We extend our special thanks to them.

Special thanks to [marswave ai's coli project](https://github.com/marswaveai/coli) for powering local speech recognition.

## How It Works

1. **Short-press Control** (default hotkey, customizable) to start recording
2. **Short-press Control** again to stop
3. Text is automatically transcribed and pasted into your active app (also copied to clipboard)

OpenTypeNo stays out of your way and operates mostly in the background, minimizing UI clutter.

## Install

### Option 1 — Download the App

- [Download OpenTypeNo for macOS](https://github.com/vivilin-ai/OpenTypeNo/releases/latest)
- Download the latest `OpenTypeNo.app.zip`
- Unzip it
- Move `OpenTypeNo.app` to `/Applications`
- Open OpenTypeNo

OpenTypeNo is signed and notarized by Apple — it should open without any warnings.

### Install the speech engine

OpenTypeNo uses [coli](https://github.com/marswaveai/coli) for local speech recognition. It requires `Node.js` and `ffmpeg`:

```bash
# Install ffmpeg
brew install ffmpeg

# Install Coli
npm install -g @marswave/coli
```

If Coli is missing, OpenTypeNo will show an in-app setup prompt with the install command.

### First Launch

OpenTypeNo needs two one-time permissions:
- **Microphone** — to capture your voice
- **Accessibility** — to paste text into apps

The app will guide you through granting these on first launch.

> **Note**: On the very first use, the app will automatically download the local speech model in the background. This may take a few minutes depending on your network connection, and a progress indicator will be shown. Once downloaded, all future transcriptions will be instant.

### Option 2 — Build from Source

```bash
git clone https://github.com/vivilin-ai/OpenTypeNo.git
cd OpenTypeNo
scripts/generate_icon.sh
scripts/build_app.sh
```

The app will be at `dist/OpenTypeNo.app`. Move it to `/Applications/` for persistent permissions.

## Usage & Features

| Action | Trigger |
|---|---|
| Start/stop recording | Short-press `Control` (Customizable: ⌃, ⌥, ⌘, ⇧) |
| Trigger Mode | Choose between Single Tap or Double Tap |
| Start/stop recording | Menu bar → Record |
| Transcribe a file | Drag `.m4a`/`.mp3`/`.wav`/`.aac` to the menu bar icon |
| Open Settings | Menu bar → Settings... (`,`) |
| Check for updates | Menu bar → Check for Updates... |
| Quit | Menu bar → Quit (`⌘Q`) |

### Advanced Settings

Open the Settings window from the menu bar to configure:
- **Transcription Mode**: Choose between local privacy-first transcription (`coli`) or **Cloud ASR** (OpenAI Whisper) for higher accuracy (requires API Key).
- **Post-Processing**: Automatically format punctuation, remove filler words (ums, ahs), and correct typos using an LLM. Supports custom API Base URL, model name, and API Key — compatible with any OpenAI-format provider (e.g. DeepSeek, SiliconFlow, OpenRouter, etc.).

## Design Philosophy

OpenTypeNo focuses on one core loop: voice → text → paste. By reducing UI clutter to the absolute minimum, the fastest way to type is to not type at all.

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=vivilin-ai/OpenTypeNo&type=Date)](https://star-history.com/#vivilin-ai/OpenTypeNo&Date)

## License

GNU General Public License v3.0
