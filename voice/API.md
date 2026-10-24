# Kitflo Voice sidecar: API contract

`voice/server.py` is a Python sidecar (stdlib `ThreadingHTTPServer`, MIT). Kitflo starts it like `LLM.start()` in `Engine.swift`:

```
KITFLO_APP_KEY=<uuid> KITFLO_PARENT_PID=<app pid> <env>/bin/python -I <Resources>/voice/server.py --port 8180 --data "<~/Library/Application Support/Kitflo>"
```

The app key goes in the `KITFLO_APP_KEY` environment variable, never argv (other local processes can read argv with `ps`). The server pops it at startup and exits with an error if it is missing or empty. `KITFLO_PARENT_PID` is the app's pid: the server exits within about 2 s if that process is gone, or if it is re-parented to launchd (pid 1).

**Host check:** every request must carry `Host: 127.0.0.1:<port>` or `Host: localhost:<port>`, otherwise 403 (blocks DNS-rebinding from web pages). Error responses close the connection. Request bodies over 50 MB get 413; `text`/`input` over 5,000 characters get 400; audio over 15 minutes is rejected.

- Env: `~/Library/Application Support/Kitflo/voice-env`, created by `uv sync --frozen --no-install-project --managed-python` in `voice/` with `UV_PROJECT_ENVIRONMENT` set to that path.
- Binds **127.0.0.1 only**. Model: `OmniVoice.from_pretrained("k2-fsa/OmniVoice", device_map="mps", dtype=torch.float16)`, loaded in a background thread at start.
- All JSON in/out unless noted. Errors: HTTP 4xx/5xx with `{"error": "<human sentence saying what to do>"}`. Never a raw traceback.

## Auth
- App endpoints (everything not under `/v1`, except `/health`): `Authorization: Bearer <app-key>`.
- `/v1/*`: the app key, or the user API key from `<data>/voice-api.json` = `{"enabled": bool, "key": "kf_..."}`. Re-read on every request, so toggling needs no restart. Disabled or missing → 401.

## Data layout (under `--data`)
- `voices/<id>/voice.json`: `{"id","name","created_at","consent":true,"languages":{"<code>":{"ref_text","duration_s","quality","ceiling"}}}`; `ceiling` is the mean ECAPA cosine between the chosen passage and held-out real speech from the same recording (0.80 when the source was under 20 s)
- `voices/<id>/ref-<code>.wav` (24 kHz mono, enhanced + normalised) and `voices/<id>/prompt-<code>.pt` (cached `VoiceClonePrompt`)
- `voice-out/`: generated and enhanced files, named `<yyyyMMdd-HHmmss>-<slug>.wav`
- `voice-tmp/`: prepare/train scratch

`<code>` is a language code from `GET /languages` (e.g. `en`, `ta`, `hi`).

## Endpoints
| Method, path | Body | Returns |
|---|---|---|
| `GET /health` (no auth) | none | `{"status":"loading"\|"ready"\|"error","device":"mps","error":null}` |
| `GET /languages` | none | `{"languages":[{"code":"ta","name":"Tamil"}...]}`, sorted by name, from OmniVoice's language map |
| `POST /voices/prepare` | `{"audio_path", "language"?}` (any length; `language` null means auto-detect) | `{"ref_path","ref_text","start","end","duration_s","source_duration_s","language","transcript_full","waveform":[200 peak floats 0–1 of the SOURCE],"quality":{"score":0-100,"checks":[{"id","ok":bool,"message","tip"}]}}` |
| `POST /voices/save` | `{"voice_id"?,"name","language","ref_path","ref_text","consent":true}` (no `voice_id` creates a new voice; with one, adds or replaces that language) | `{"voice":<voice.json>}`; 400 if `consent` is not true |
| `GET /voices` | none | `{"voices":[<voice.json>...]}` newest first |
| `PATCH /voices/<id>` | `{"name"}` | `{"voice"}` |
| `DELETE /voices/<id>` | none | `{"ok":true}` |
| `DELETE /voices/<id>/languages/<code>` | none | `{"voice"}` |
| `GET /voices/<id>/preview?lang=<code>` | none | `audio/wav` of the reference |
| `POST /voices/train` | `{"voice_id"?,"name","language","audio_path","consent":true}` (a 1–3 min guided recording) | `{"job_id"}` |
| `GET /jobs/<job_id>` | none | `{"state":"running"\|"done"\|"failed","progress":0-1,"message","result":{"voice"}\|null,"error"}` |
| `POST /speak` | `{"voice_id" ("" = OmniVoice default voice),"language","text","preset":"fast"\|"balanced"\|"studio","speed":1.0,"seed"?}` | `{"path","duration_s","takes","similarity"?,"match"?,"intelligibility"?,"language_matched":bool}`. `similarity` is ECAPA cosine of the take vs the voice's reference clip; `match = min(similarity / ceiling, 1.0)` where `ceiling` is the voice's stored real-speech ceiling (see voice.json), so 1.0 means "as close as the speaker's own real speech is to itself". Both are also in a `/speak/jobs` result |
| `POST /speak/jobs` | same body as `/speak` | `{"job_id"}`. `GET /jobs/<id>` then reports `progress` per generated chunk and, when `state` is `done`, `result` is exactly the JSON `/speak` returns (not `{voice}`) |
| `POST /voices/<id>/warm` | `{"language"?}` | `{"ok":true}`. Loads (or rebuilds) that language's prompt into the cache and runs a tiny generate under the GPU lock so the first real `/speak` is fast. The server also warms the default voice once after the model loads |
| `POST /enhance` | `{"audio_path","level":"clean"\|"studio"}` | `{"path","duration_s","before_lufs","after_lufs"}` |
| `POST /v1/audio/speech` | OpenAI shape: `{"model","input","voice","response_format":"wav"\|"flac"\|"pcm","speed","language"?,"quality"?}`; `voice` is a Kitflo voice id or name, or any unknown/OpenAI name for the default voice; `mp3` gives 400 suggesting wav | audio bytes |
| `GET /v1/audio/voices` | none | `{"voices":[{"voice_id","name","languages":[codes]}]}` |
| `POST /v1/audio/enhance?level=clean` | raw audio bytes (any format soundfile reads) | `audio/wav` |

## Behaviour
- **prepare**:
  1. Enhance (`clean`).
  2. Transcribe with Whisper large-v3-turbo (transformers pipeline, `openai/whisper-large-v3-turbo`, word timestamps).
  3. Pick the best 3–10 s run of whole sentences: most voiced audio, no clipping, low noise. If none qualifies, take the best 3–10 s window with a quality warning.
  3b. For sources of 20 s or more (and once the model is loaded) keep the top 3 passages and clone-test each: build a prompt, speak one fixed test sentence (`TEST_TEXT`, else a sentence outside all candidates), and score the take by mean ECAPA cosine against held-out windows of the source that lie outside that passage. The best-scoring passage is returned. The same held-out windows give the voice's `ceiling`. This adds about 1–2 minutes; `/voices/prepare` stays synchronous.
  4. Trim the edges to silence with 0.15 s padding, normalise, write a 24 kHz mono wav.
  5. Quality checks: length, clipping, noise floor (SNR), loudness, speech ratio. Each failure gets a one-line tip.
- **train**:
  1. Run prepare-style segmentation over the recording to get up to 5 candidate passages.
  2. For each, build a prompt and generate one fixed test sentence in that language.
  3. Score each take: ECAPA speaker similarity to held-out real speech outside that passage (the whole recording only if it is too short to hold any out) (speechbrain `spkrec-ecapa-voxceleb`, Apache-2.0) plus intelligibility, i.e. 1 − CER of Whisper on the take versus the text.
  4. Keep the best passage and save it as that voice's language.
- **speak**:
  - Use the voice's reference for `language`; otherwise its first language (`language_matched=false`).
  - Cached prompt `.pt`.
  - Presets: all presets use `guidance_scale=2.5` (tuning sweep: +0.02 speaker similarity vs 2.0; 64 steps did not help); fast `num_step=16`, balanced `32`, studio = 4 takes at `32` with seeds `seed, seed+1, seed+2, seed+3`, keeping the best by `0.6*similarity + 0.4*intelligibility`.
  - Long text is split by sentence, about 300 characters per chunk, same prompt and seed, joined with a 30 ms crossfade.
  - Digits are spoken as words via `num2words` where it supports the language.
  - Output is peak-limited to −1 dBFS.
- **enhance**:
  - `clean` = DeepFilterNet 3 denoise, then loudness to −16 LUFS, peak −1 dBFS.
  - `studio` = clean, then a light high-pass at 80 Hz, gentle presence EQ and compression, then −16 LUFS. (Resemble Enhance is not usable: it pins torch 2.1.)
- The GPU model is used by one request at a time (a lock); `/health` and `/jobs` stay responsive.

## Pins (`voice/pyproject.toml`)
Python 3.11 only (DeepFilterLib wheels), `torch==2.8.0`, `torchaudio==2.8.0`, `transformers==5.15.1`. torch 2.14 + transformers 5.20 segfaults loading OmniVoice on MPS. No `omnivoice[tn]`, because pynini needs OpenFST.

## Pro training
Fine-tuning a LoRA adapter per voice (scan a folder of the speaker's recordings, train, automatic A/B, speak with the adapter) is specified in `PRO.md`: `/pro/scan`, `/pro/train`, `/pro/cancel`, `DELETE /voices/<id>/pro`, `POST /voices/<id>/pro/enabled`. While training, `/health` reports `"status":"training"` and speaking endpoints answer 409. Implementation: `pro.py` (training runs in a child process, `python -I pro.py train`). Jobs for these endpoints carry an extra `detail` object in `GET /jobs/<id>`; scan/train results add a few fields beyond PRO.md (`threshold`, `language`, `clips`, `dev_clips` on scan; `dropped.unusable_length`).
