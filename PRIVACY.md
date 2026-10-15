# Privacy Policy

_Last updated: 15 October 2026_

OpenFlo is a voice dictation app for macOS that runs entirely on your own computer. This policy explains what it touches and where that data goes. Short version: **nothing you say or type leaves your Mac through OpenFlo, and the OpenFlo project collects no data at all.**

## What OpenFlo does not do

- No accounts, sign-in or user IDs.
- No analytics, telemetry, crash reporting or tracking of any kind.
- No servers run by the OpenFlo project. There is nowhere for your data to be sent.
- No advertising and no sale or sharing of data.

## What OpenFlo processes, and where

| Data | When | Where it goes |
|---|---|---|
| **Microphone audio** | Only while you hold (or have toggled) the dictation key | Streamed in memory to Apple's on-device speech recognizer (`SpeechAnalyzer`). Never written to disk, never uploaded. Discarded once transcription finishes. |
| **Transcript text** | After each dictation | Sent to a local AI model (`llama-server`) on `127.0.0.1`, which only your own Mac can reach. The server needs a random key generated at each launch, so other apps and websites can't use it. |
| **Name of the frontmost app** | When dictation starts | Stored with that history entry so you can see where you dictated. Never sent anywhere. |
| **Clipboard** | When pasting | OpenFlo puts the text on your clipboard, presses ⌘V, then puts your previous clipboard text back about 0.8 s later. |
| **Hotkey presses** | Always, while OpenFlo runs | OpenFlo only checks whether the dictation key (fn, Right ⌥ or Right ⌘) is up or down. It does not log or record other keys. |

## What is stored on your Mac

Everything below lives in `~/Library/Application Support/OpenFlo/store.json`, readable only by your macOS user account:

- **History**: raw transcript, cleaned text, app name, time and length of each dictation
- **Dictionary words and snippets** you add
- **Settings** (style, hotkey, language, sounds)

You can clear history at any time in **Settings → Clear history**. Deleting that file, or the app, removes everything.

## Permissions OpenFlo asks for

- **Microphone**: to hear you while the dictation key is held.
- **Accessibility**: to notice the dictation key in any app and to paste the result into the focused text field. OpenFlo does not read the contents of other apps' windows.

You can revoke either at any time in System Settings → Privacy & Security.

## Network activity

OpenFlo does not send your audio, text or settings anywhere. The only network activity related to it is:

- **Apple speech models**: the first time you use a language, macOS downloads Apple's on-device speech model for it from Apple. That download is handled by macOS under [Apple's privacy policy](https://www.apple.com/legal/privacy/). Recognition itself then runs offline.
- **Setup downloads you run yourself**: Homebrew (`llama.cpp`) and the Qwen model file from Hugging Face, per the README. These happen once, from your terminal, and are covered by those services' own policies.

## Third-party components

- **Apple SpeechAnalyzer**: part of macOS, runs on-device.
- **llama.cpp** (MIT) and **Qwen2.5-1.5B-Instruct** (Apache 2.0): run locally. No data is sent to their authors.

## Children

OpenFlo collects no personal data from anyone, including children.

## Changes

If this policy changes, the update will be committed to this file in the public repository, so its full history is visible.

## Contact

Questions or concerns? Open an issue on the GitHub repository.
