# Contributing to OpenFlo

Thanks for helping. OpenFlo aims to stay **small, fast and fully local**. Please keep that in mind when proposing changes.

## Ground rules

- **Nothing leaves the Mac.** PRs that add network calls, telemetry or cloud APIs won't be merged.
- **Latency matters.** If a change touches the dictation path, include before/after timings from `OpenFlo --file`.
- **Keep it simple.** Prefer Apple frameworks and the standard library over new dependencies. Currently there are none.

## Getting started

```bash
git clone https://github.com/<you>/openflo.git && cd openflo
brew install llama.cpp
# download the model as shown in the README ("Build from source"), then:
swift build -c release
.build/release/OpenFlo --selftest
.build/release/OpenFlo --file sample.wav
./build.sh   # installs ~/Applications/OpenFlo.app
```

Tip: `say -o sample.wav --data-format=LEI16@16000 "um so, uh, meet at 5, no wait, 6"` makes quick test audio.

## Pull requests

1. Open an issue first for anything bigger than a bug fix.
2. One change per PR, with a short description of what and why.
3. Make sure `swift build -c release` and `--selftest` pass.
4. For UI changes, add a screenshot.

## Cleanup prompt changes

The few-shot examples in `Engine.swift` (`LLM.shots`) affect accuracy most. If you change them, test at least: self-corrections, questions (they must not be answered), lists and filler-heavy speech.

By contributing you agree that your work is released under the [MIT License](LICENSE) and that you'll follow the [Code of Conduct](CODE_OF_CONDUCT.md).
