# Pro training (LoRA fine-tune): contract addendum to API.md

Goal: ElevenLabs-style "professional" cloning on the Mac. Kitflo fine-tunes a LoRA adapter for one voice on 30 min or more of that speaker's clean speech, then uses it whenever that voice speaks.

Feasibility was proven on an M2 with 16 GB (MPS): about 2.4 s/step, about 9 GB peak, and about 1–2 h for 30 min of audio. The training code is upstream `omnivoice` (Apache-2.0), installed in the voice env (`omnivoice.training`, `omnivoice.scripts.extract_audio_tokens`, `omnivoice.cli.train`).

MPS changes found in the test (apply them from our own code, `voice/pro.py`, not by editing site-packages):
- `attn_implementation: "sdpa"` (no flex_attention packing).
- `mixed_precision: "bf16"`.
- `batch_tokens: 2048`.
- train `num_workers: 0`.
- **dataloaders: `pin_memory=False`, dev `num_workers=0`, no `prefetch_factor`.** Upstream `builder.py` hardcodes these. Wrap or monkeypatch the builder from `pro.py` (or construct the DataLoaders ourselves).
- Tokenizer on MPS (upstream defaults to CPU without CUDA), tokenizer `eustlb/higgs-audio-v2-tokenizer`.
- LoRA r=16, alpha=32, the upstream LoRA example targets, and `lora_modules_to_save` = `audio_embeddings`, `audio_heads`.
- Launch with `python -m omnivoice.cli.train` equivalent in-process or as a child process. No `accelerate launch`.
- Add `peft` to `voice/pyproject.toml` if it isn't already pulled in. Then run `uv lock` and `uv sync` (same pins).

## Endpoints (app key)
| Method, path | Body | Returns |
|---|---|---|
| `POST /pro/scan` | `{"voice_id","folder"}` (absolute path; recursive; audio + video: wav/mp3/m4a/aac/flac/mp4/mov/m4v/mkv/webm) | `{"job_id"}` |
| `POST /pro/train` | `{"voice_id","dataset_id","steps"?}` | `{"job_id"}` |
| `GET /jobs/<id>` | none | as in API.md; plus `detail` for these jobs (below) |
| `POST /pro/cancel` | `{"job_id"}` | `{"ok":true}` |
| `DELETE /voices/<id>/pro` | none | `{"voice"}` (removes the adapter) |
| `POST /voices/<id>/pro/enabled` | `{"enabled":bool}` | `{"voice"}` (use or ignore the adapter when speaking) |

### Scan job
1. Extract audio per file. Use soundfile, and fall back to `/usr/bin/afconvert -f WAVE -d LEI16@24000 -c 1` (it handles mp4/mov AAC tracks). Skip and count files that fail.
2. Enhance `clean` (DeepFilterNet).
3. Whisper-transcribe with segment timestamps; language auto unless the voice has one. Unload Whisper after each file (memory).
4. Cut 3–15 s clips on segment boundaries.
5. **Keep a clip only if all of these hold:**
   - **Same speaker:** ECAPA cosine to the voice's reference wavs ≥ 0.55. Calibrate with the voice's `ceiling`; log the threshold used.
   - **No music or effects:** the energy DeepFilterNet removes is ≤ 35% of the original, and the spectral flatness of the residual is low. Simple, documented heuristics; record the reason for each drop.
   - **No clipping**, and SNR ≥ 15 dB.
   - Whisper `no_speech` low, and the text is non-empty.
6. Write `voices/<id>/pro/datasets/<dataset_id>/clips/*.wav` (24 kHz mono) plus `train.jsonl` and `dev.jsonl`. Use a 5% dev split, minimum 3 clips. `language_id` per clip comes from Whisper.
7. `result` = `{"dataset_id","files_total","files_failed","kept_minutes","dropped_minutes","dropped":{"other_speaker":min,"music_or_noise":min,"clipping":min,"no_speech":min},"samples":[up to 5 kept clip paths],"rejected_samples":[up to 3 {path,reason}],"enough":bool}`. `enough` = `kept_minutes` ≥ 30. Training is still allowed from 1 minute, with a warning.
8. `detail` while running: `{"file":"name","files_done":n,"files_total":n,"kept_minutes":x}`.

### Train job
1. Before starting, **unload the speaking model and free MPS** (`gc.collect()`, `torch.mps.empty_cache()`). The engine reports `/health` `"status":"training"`, and `/speak` returns 409: "Your voice is training. Speaking is paused until it finishes (you can cancel it on the Voices tab)."
2. Tokenize, then train.
   - Steps default = clamp(round(kept_minutes × 60), 300, 3000), roughly 10+ epochs. Checkpoint every 250 steps; keep only the last checkpoint plus the best by dev loss.
   - **Disk:** delete the optimizer and accelerate state at the end. Keep only the adapter (about 100 MB) at `voices/<id>/pro/adapter/`.
3. Report `detail`: `{"step","steps","loss","dev_loss"?,"eta_s","s_per_step"}`.
4. When done, run an automatic A/B. Generate 3 fixed sentences in the voice's main language with and without the adapter, same seeds. Score each with held-out ECAPA (vs dataset dev clips), UTMOS22 strong (`tarepan/SpeechMOS`, cached in torch hub) and CER. Save the wavs to `voices/<id>/pro/ab/` named `A-k.wav` / `B-k.wav` in random order. Store the mapping and scores in `voices/<id>/pro/ab.json` = `{"pairs":[{"k":1,"text":"…","pro":"A"},…],"scores":{…}}`; `k` is 1-based and matches `A-<k>.wav`/`B-<k>.wav`. Result: `{"voice","scores":{"base":{"match","utmos","cer"},"pro":{...}},"ab_dir","pairs":[same as ab.json]}`.
5. Set `voice.json` → `"pro":{"enabled":true,"trained_at","minutes","steps","scores"}`. Set `enabled` false automatically if pro is worse than base on match by more than 0.02.
6. Reload the speaking model.
7. Cancel and errors both leave the voice usable without pro, and both reload the speaking model.

### Speaking with an adapter
- **Loading:** load adapters with PEFT **without merging** (`PeftModel.from_pretrained(..., adapter_name=<voice_id>)` / `load_adapter`). Switch with `set_adapter`, or `disable_adapter()` for voices without pro. Never merge in place: other voices share the base model.
- **Cost:** keep at most 2 adapters loaded (LRU).
- **Prompt:** the voice's clone prompt is still used together with the adapter.

### Memory rules
- Never train while another model job is running.
- Whisper, ECAPA and UTMOS are loaded lazily and freed after use.
- Peak target is ≤ 9.5 GB.
