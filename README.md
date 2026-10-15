<p align="center"><img src="assets/icon.png" width="128" alt="OpenFlo icon"></p>

<h1 align="center">OpenFlo</h1>

<p align="center">Free, open-source voice dictation for macOS that runs 100% on your Mac.<br>
Hold a key, talk, let go and clean text appears in whatever app you're typing in.</p>

---

## Why

Cloud dictation apps send every word you say to a server. OpenFlo doesn't. Speech recognition runs on Apple's on-device engine (Neural Engine) and the cleanup runs on a small local LLM through llama.cpp (Metal). No account, no subscription, no network needed after setup.

On an M2 MacBook Air, text lands about **0.6–1.0 s** after you release the key.

## Features

- **Hold `fn` to talk**, release to paste. **Tap `fn`** once for hands-free and tap again to stop. You can switch to Right ⌥ or Right ⌘.
- **Live transcription**: audio streams into the recognizer while you speak, so text is ready about 0.2 s after you let go.
- **AI cleanup**: removes um/uh, stutters and false starts. Applies self-corrections ("at 5, no wait, 6" → "at 6"), fixes punctuation and turns spoken lists into numbered lines. It cleans up questions; it never answers them.
- **Dictionary**: your names and jargon, always spelled your way (fuzzy-matched, so "tracking flow" becomes `TrackingFlo`).
- **Snippets**: say "my calendar link" and get your full URL.
- **Styles**: Formal, Casual, Very casual.
- **History and stats**: streak, words this week, average WPM. View the raw transcript or the cleaned text, copy with one click.
- **12 languages**, including English (India/US/UK/AU), Spanish, French, German, Japanese, Chinese and more.
- **Floating pill** with a live waveform at the bottom of the screen.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)
- [Homebrew](https://brew.sh)
- ~1 GB of disk for the cleanup model

## Install

```bash
git clone https://github.com/harsh-matchmyflight/openflo.git ~/OpenFlo
cd ~/OpenFlo
brew install llama.cpp
mkdir -p models && curl -L -o models/qwen2.5-1.5b-instruct-q4_k_m.gguf \
  https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf
./build.sh
open ~/Applications/OpenFlo.app
```

The repo must live at `~/OpenFlo`, because the app loads its model from `~/OpenFlo/models`.

Then:

1. Allow **Microphone** and **Accessibility** when asked (Accessibility lets OpenFlo see the hotkey and paste).
2. System Settings → Keyboard → set **"Press 🌐 key to" → Do Nothing**.
3. Click in any text field, hold `fn`, talk.

The first run downloads Apple's speech model for your language (managed by macOS, no extra app storage).

## How it works

```
fn down ─► mic (AVAudioEngine, 16 kHz) ─► Apple SpeechAnalyzer (streaming, on-device)
fn up   ─► transcript ─► dictionary fix ─► Qwen2.5-1.5B via llama-server (few-shot cleanup)
        ─► snippets ─► paste with ⌘V into the focused app (your clipboard is restored)
```

| File | What's in it |
|---|---|
| `Sources/OpenFlo/Engine.swift` | recorder, speech session, LLM cleanup, dictionary/snippet post-processing, paste |
| `Sources/OpenFlo/Overlay.swift` | the floating pill |
| `Sources/OpenFlo/Views.swift` | Home, Dictionary, Snippets, Style, Settings |
| `Sources/OpenFlo/App.swift` | menu bar, hotkey, window |
| `Sources/OpenFlo/Store.swift` | settings and history (`~/Library/Application Support/OpenFlo/store.json`) |

### Why these models

Measured on an M2 (8-core GPU, 16 GB):

| Option | Time after key release | Notes |
|---|---|---|
| Whisper large-v3-turbo (whisper.cpp, Metal) | ~2.4 s | encoder too slow on M2 |
| **Apple SpeechAnalyzer (streaming)** | **~0.2 s** | chosen: on-device, no app storage |
| Qwen2.5-3B cleanup | ~1–2 s | slower, sometimes answered questions |
| **Qwen2.5-1.5B + few-shot** | **~0.4 s** | chosen: handled every test case |

## Dev

```bash
swift build -c release
.build/release/OpenFlo --selftest          # dictionary/snippet logic checks
.build/release/OpenFlo --file speech.wav   # run the full pipeline on a file and print timings
```

Note: `build.sh` signs the app ad hoc, so macOS asks for Accessibility again after each rebuild.

## Roadmap

- Android app (keyboard + floating bubble)
- Per-app tone
- Signed and notarized release builds

## Privacy

No accounts, no telemetry, no servers. Audio and text never leave your Mac. Full details are in [PRIVACY.md](PRIVACY.md).

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), the [Code of Conduct](CODE_OF_CONDUCT.md) and the [Security Policy](SECURITY.md).

## License

[MIT](LICENSE)
