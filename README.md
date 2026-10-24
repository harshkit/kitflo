<p align="center"><img src="assets/icon.png" width="128" alt="Kitflo, a free offline voice dictation app for Mac"></p>

<h1 align="center">Kitflo</h1>

<p align="center"><sub>by <a href="https://www.harshkit.com/">Harshkit</a> · formerly OpenFlo</sub></p>

<p align="center"><b>Free, open-source, offline voice dictation and meeting notes for Mac.</b><br>
Hold <code>fn</code>, talk, let go and clean text appears in any app. Record a meeting and get who-said-what plus AI notes.<br>100% on-device: no cloud, no account, no subscription.</p>

<p align="center">
  <a href="https://github.com/harshkit/kitflo/releases/latest"><img src="https://img.shields.io/github/v/release/harshkit/kitflo?label=download&color=ff9e52" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-M1%E2%80%93M5-black" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/100%25-offline-2ea44f" alt="100% offline">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  <a href="https://github.com/harshkit/kitflo/stargazers"><img src="https://img.shields.io/github/stars/harshkit/kitflo?style=social" alt="GitHub stars"></a>
</p>

<p align="center"><a href="https://www.harshkit.com/apps/kitflo/">Website</a> · <a href="#install-one-line">Install</a> · <a href="#-new-meeting-notes">Meeting notes</a> · <a href="#-new-voice-clone-speak-enhance">Voice</a> · <a href="#features">Features</a> · <a href="PRIVACY.md">Privacy</a></p>

---

Kitflo is a **free, private alternative to paid AI dictation and meeting-note apps** like Wispr Flow, Superwhisper, Otter and Granola. It turns rambling speech into clean writing in **under a second**, and turns meetings into a who-said-what transcript plus notes, without anything leaving your Mac.

## Install (one line)

```bash
curl -fsSL https://raw.githubusercontent.com/harshkit/kitflo/main/install.sh | bash
```

That installs everything: the local AI engine, the ~1 GB cleanup model and the app. The ~0.57 GB speech model downloads the first time you dictate. Then allow **Microphone** and **Accessibility** when asked, and set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**.

## 🆕 Meeting notes

Record a meeting, call, demo or anything on screen. Kitflo works out **who said what** and writes the notes for you, on your Mac.

| | |
|---|---|
| 🎙️🖥️🎥 **Three modes** | Audio only · Audio + Screen · Audio + Screen + Camera (a draggable camera bubble recorded with the screen) |
| 🎯 **Record anything** | The whole screen, **one app** (e.g. only Zoom, with only its audio) or **one window** (e.g. the browser window with your meeting tab), picked with macOS's own picker |
| 🔀 **Two audio tracks** | Your mic and the system audio are captured separately, so **You** vs everyone else is always right; other people are told apart as Speaker 1, 2, 3… |
| ⏯️ **Floating recording bar** | Timer, **pause/resume**, **mic** and **camera** on/off, stop. Paused parts are cut out of the video |
| 👀 **Reads your screen** | Text on screen is read on-device every few seconds, so notes cover what you **showed**, not just what you said |
| 📝 **AI notes** | Title, summary, key points, **action items with owners** and decisions, plus the full timestamped transcript |
| 📁 **Your files** | Video or audio saved to `~/Movies/Kitflo` (changeable). Copy notes anywhere with one click |

Meeting notes need **Screen Recording** permission (for system audio and video): **Notes tab → Allow Screen Recording**, turn Kitflo on, then **Restart Kitflo**.

## 🆕 Voice: clone, speak, enhance

A new **Voice** page with four tabs: **Speak · Voices · Enhance · API**. Clone your voice, make it read anything in 600+ languages and clean up recordings, all on your Mac.

| | |
|---|---|
| ⚡ **Quick clone** | Record or drop in a clip of any length. Kitflo picks the best 3–10 s passage, writes the transcript and shows a **quality score** with tips |
| 🎤 **Train my voice** | A guided 1–2 minute read-aloud. Kitflo tests up to 5 candidate passages and keeps the one that sounds most like you |
| ✨ **Pro training** | Point Kitflo at a folder of your videos or audio (30+ min of only your voice). It keeps just your clean speech, fine-tunes a personal voice adapter on your Mac (about 1–2 h), then lets you pick the winner in a **blind A/B test** |
| 🌐 **Auto language** | Mixed speech like Hinglish works: Kitflo detects the language from your text |
| 🗣️ **Multiple voices** | Each voice holds **one sample per language** so the accent sounds native (e.g. an English and a Tamil sample) |
| 🌍 **Speaks 600+ languages** | Including English, Hindi and Tamil. Long scripts are fine and numbers are read as words |
| 🎚️ **Three presets** | **Fast**, **Balanced**, or **Studio**: 3 takes, keeps the one closest to your voice that says the words right |
| 🎧 **Enhance** | Adobe-Podcast-style cleanup of any recording or video's audio. **Clean**: noise and echo removal plus podcast loudness (−16 LUFS). **Studio**: Clean plus EQ and compression. Before/after A/B toggle, then download |
| 💾 **Download** | Speech as **WAV** or **M4A** |
| 🔌 **Local API** | OpenAI-compatible, off by default, API key generated in Kitflo, listens only on this Mac |

**Setup is one click** on the Voice page (**Set up**). Nothing is downloaded until you open Voice and click it: the Python engine (~2.5 GB), the voice model (3.3 GB) and, on your first clone, Whisper (1.6 GB). Voices are stored in `~/Library/Application Support/Kitflo/voices`.

**Responsible use:** cloning requires ticking *"This is my voice, or I have the speaker's permission"*. Don't clone anyone without their consent. Generated audio is for **non-commercial use** (see [Licenses](#voice-engine-credits)).

### Local API

Turn it on in **Voice → API**, generate a key, and call it on `127.0.0.1:8180`:

```bash
curl http://127.0.0.1:8180/v1/audio/speech \
  -H "Authorization: Bearer kf_YOUR_KEY" -H "Content-Type: application/json" \
  -d '{"input": "Hello from Kitflo", "voice": "my-voice", "response_format": "wav"}' -o hello.wav
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8180/v1", api_key="kf_YOUR_KEY")
audio = client.audio.speech.create(model="kitflo", voice="my-voice", input="Hello from Kitflo", response_format="wav")
audio.write_to_file("hello.wav")
```

| Endpoint | What it does |
|---|---|
| `POST /v1/audio/speech` | Text to speech in one of your voices |
| `GET /v1/audio/voices` | List your voices and their languages |
| `POST /v1/audio/enhance?level=clean` | Send raw audio, get cleaned WAV back (`clean` or `studio`) |

## Features

- 🎙️ **Hold `fn` to talk, release to paste** into any app: Slack, Gmail, Notion, VS Code, ChatGPT, anything with a text box. **Tap `fn`** for hands-free mode.
- ⚡ **Fast**: speech streams into the recognizer while you talk, so text appears **~0.6–1.0 s** after you let go (measured on an M2).
- ✨ **AI cleanup, fully local**: removes filler words and stutters, keeps only your final version ("at 5, no wait, 6" → "at 6"), adds punctuation and turns spoken lists into numbered lists. It cleans up your questions; it never answers them.
- 🗒️ **Meeting notes**: record audio, screen or camera and get who-said-what plus AI notes. See [Meeting notes](#-new-meeting-notes).
- 🆕 **Voice cloning**: clone your voice from a short clip or a guided read-aloud, with one sample per language. See [Voice](#-new-voice-clone-speak-enhance).
- 🔊 **Text-to-speech** in 600+ languages (Fast, Balanced, Studio), download as WAV or M4A.
- 🎧 **Enhance**: Adobe-Podcast-style noise, echo and loudness cleanup for any recording.
- 🔌 **Local, OpenAI-compatible API** for speech, voices and enhance. Off by default, localhost only.
- 📖 **Dictionary**: names, brands and jargon spelled your way.
- ✂️ **Snippets**: say "my calendar link" and get your full URL.
- 🎨 **Styles**: Formal, Casual or Very casual.
- 🔉 **Soft-voice boost**: automatic gain picks up quiet or distant speech.
- 📊 **History and stats**: streak, words per week, average WPM. See the raw transcript or the cleaned text.
- 🌍 **12 languages**, including English (India, US, UK, Australia), Spanish, French, German, Italian, Portuguese, Japanese, Korean and Chinese.
- 🔒 **Private by design**: no telemetry, no servers, no account. Audio is never saved. See [PRIVACY.md](PRIVACY.md).

## Kitflo vs. cloud dictation apps

| | Kitflo | Typical cloud dictation app |
|---|---|---|
| Price | **Free forever** | $12–15/month |
| Where your voice goes | **Stays on your Mac** | Uploaded to servers |
| Works offline | **Yes** | No |
| Account required | **No** | Yes |
| Open source | **Yes (MIT)** | No |
| Meeting notes with video | **Included, on-device** | Separate paid app |

## How it works

```
hold fn ─► mic (16 kHz, auto gain) ─► Parakeet TDT 0.6B v3 + dictionary boost, or Apple SpeechAnalyzer (Neural Engine)
release ─► transcript ─► Qwen2.5-1.5B via llama.cpp on Metal (few-shot cleanup)
        ─► dictionary + snippets ─► pasted into the app you were typing in
```

| Step | Engine | Measured time after release (M2) |
|---|---|---|
| Speech → text (default) | NVIDIA Parakeet TDT 0.6B v3 + CTC dictionary boost via [FluidAudio](https://github.com/FluidInference/FluidAudio), 0.57 GB one-time download | ~0.3 s (5 s clip), ~0.65 s (20 s clip) |
| Speech → text (fallback) | Apple `SpeechAnalyzer` (on-device, no download) | ~0.1–0.2 s |
| Cleanup | Qwen2.5-1.5B-Instruct Q4 via `llama-server` | ~0.3–0.8 s |

On test clips with names and tech words from the Dictionary (GitHub, README, Claude, Kubernetes, Razorpay…), Parakeet got 18/20 right and Apple 14/20; Apple ignores custom vocabulary. Pick the engine in Settings. We benchmarked Whisper large-v3-turbo too: ~2.4 s on an M2, too slow for push-to-talk.

## Requirements

- macOS 26 (Tahoe) or newer
- Apple Silicon (M1 or newer)
- ~1.6 GB free disk (cleanup model + speech model)
- **Voice (optional):** ~8 GB more free disk, 16 GB RAM recommended

## Build from source

```bash
git clone https://github.com/harshkit/kitflo.git && cd kitflo
brew install llama.cpp
mkdir -p ~/Library/Application\ Support/Kitflo/models && curl -L -o ~/Library/Application\ Support/Kitflo/models/qwen2.5-1.5b-instruct-q4_k_m.gguf \
  https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf
swift build -c release
.build/release/Kitflo --selftest           # logic checks
.build/release/Kitflo --file speech.wav    # run the full pipeline on a file and print timings
./build.sh              # installs ~/Applications/Kitflo.app
```

| File | What's in it |
|---|---|
| `Sources/Kitflo/Engine.swift` | recorder, speech session, LLM cleanup, dictionary/snippets, paste |
| `Sources/Kitflo/Overlay.swift` | the floating pill |
| `Sources/Kitflo/Views.swift` | Home, Notes, Dictionary, Snippets, Style, Settings |
| `Sources/Kitflo/App.swift` | menu bar, hotkey, window |
| `Sources/Kitflo/Store.swift` | local storage (`~/Library/Application Support/Kitflo/`) |

## FAQ

**Is Kitflo really free?** Yes. It's MIT-licensed, with no paid tier and no usage limits.

**Does it work without internet?** Yes, after the one-time install.

**Is it a Wispr Flow alternative?** It covers the same core workflow (hold a key, speak, get clean text) but runs entirely on your Mac. Kitflo is an independent project and is not affiliated with Wispr or any other company.

**Text didn't paste?** Check that Accessibility is on for Kitflo and that the 🌐 key is set to "Do Nothing". Kitflo warns you on its Home screen when either is wrong, and the text always stays on your clipboard as a fallback.

**Windows / Android?** Android is next on the roadmap.

## Roadmap

- [ ] Android keyboard + floating bubble
- [x] Stronger speech engine option with custom-vocabulary boosting
- [ ] Per-app tone
- [ ] Signed and notarized builds

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md), the [Code of Conduct](CODE_OF_CONDUCT.md) and the [Security Policy](SECURITY.md). If Kitflo saves you time, a ⭐ helps other people find it.

## License

[MIT](LICENSE) © Harsh Sharma

### Voice engine credits

Kitflo's own code is MIT. The Voice feature runs these open-source components on your Mac:

| Component | Used for | License |
|---|---|---|
| [OmniVoice](https://github.com/k2-fsa/OmniVoice) by k2-fsa | Voice cloning and speech | Code Apache-2.0; **model weights CC-BY-NC** |
| DeepFilterNet | Enhance (noise and echo removal) | MIT / Apache-2.0 |
| Whisper large-v3-turbo | Transcripts for clones | MIT |
| SpeechBrain ECAPA | Voice matching | Apache-2.0 |

⚠️ Because the OmniVoice weights are CC-BY-NC, **audio generated with Voice is for non-commercial use** only. This does not affect dictation or meeting notes.
