"""Kitflo voice sidecar: local voice cloning, speech and enhancement over HTTP. Contract: API.md."""
import argparse
import contextlib
import gc
import hmac
import io
import json
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import traceback
import uuid
import warnings
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # python -I drops the script dir
warnings.filterwarnings("ignore")


def watch_parent():
    """Exit when Kitflo is gone (its KITFLO_PARENT_PID no longer exists, or we were re-parented to launchd, pid 1)
    rather than hold ~5 GB. Started before the heavy imports below so a crashed app can't leave us loading models."""
    try:
        pid = int(os.environ.get("KITFLO_PARENT_PID") or 0)
    except ValueError:
        pid = 0
    while True:
        if os.getppid() == 1:
            os._exit(0)
        if pid:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                os._exit(0)
            except PermissionError:
                pass
        time.sleep(2)


if __name__ == "__main__":
    threading.Thread(target=watch_parent, daemon=True).start()

import numpy as np
import soundfile as sf
import torch

import enhance
import pick
import pro
from pick import chunks

SR = 24000  # OmniVoice's rate
WHISPER = "openai/whisper-large-v3-turbo"
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
DTYPE = torch.float16 if DEVICE == "mps" else torch.float32
STEPS = {"fast": 16, "balanced": 32, "studio": 32}
GUIDANCE = 2.5  # tuning sweep: +0.02 speaker similarity over 2.0; 64 steps did not help
STUDIO_TAKES = 4
CEILING_DEFAULT = 0.80  # "how well real speech matches itself" when the source was too short to measure
TEST_TEXT = {  # fixed sentence for scoring candidate passages in /voices/train
    "en": "The quick brown fox jumps over the lazy dog near the old river bank.",
    "ta": "இன்று வானிலை மிகவும் நன்றாக இருக்கிறது, நாம் வெளியே நடந்து செல்லலாம்.",
    "hi": "आज मौसम बहुत अच्छा है, चलो बाहर टहलने चलते हैं।",
}

THIS = sys.modules[__name__]  # handed to pro.py, which can't import the server (it may be __main__)
GPU = threading.Lock()   # one model user at a time
FILES = threading.Lock()  # voice.json read-modify-write
LOAD = threading.Lock()  # lazy Whisper / ECAPA loads happen once
STATE = {"status": "loading", "error": None, "model": None}
JOBS, JOB_AT = {}, {}
CANCEL = {}  # job id -> threading.Event, for scan/train jobs
CFG = {"key": "", "data": None, "port": 0}
MAX_BODY = 50 * 1024 * 1024
MAX_TEXT = 5000
MAX_AUDIO_S = 15 * 60
CODE = re.compile(r"[A-Za-z0-9_-]{1,16}")
LOW_MEM = os.environ.get("KITFLO_VOICE_LOW_MEM", "1") != "0"  # Whisper on CPU: slower, but ~3 GB less GPU memory on a 16 GB Mac
UNEXPECTED = "The voice engine hit an unexpected problem. Try again; if it repeats, restart Kitflo."
_whisper = _ecapa = None
_prompts = {}  # prompt .pt path -> (mtime, VoiceClonePrompt)
_embeds = {}   # ref wav path -> (mtime, speaker embedding)


class ApiError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status, self.message = status, message


def bad(msg):
    return ApiError(400, msg)


def data_dir(*p):
    return os.path.join(CFG["data"], *p)


# ---------------------------------------------------------------- models

def load_model():
    try:
        from omnivoice import OmniVoice
        STATE["model"] = OmniVoice.from_pretrained("k2-fsa/OmniVoice", device_map=DEVICE, dtype=DTYPE)
        STATE["status"] = "ready"
    except Exception:
        traceback.print_exc()
        STATE["status"], STATE["error"] = "error", "The voice model failed to load. Restart Kitflo; if it keeps happening, reinstall the voice engine in Settings."
        return
    try:  # warm the default voice's kernels so the first real request isn't the slow one
        speak_prompt(None, None, "Hi.", 8, 1.0, 0)
    except Exception:
        traceback.print_exc()


def not_training():
    if STATE["status"] == "training":
        raise ApiError(409, "Your voice is training. Speaking is paused until it finishes (you can cancel it on the Voices tab).")


def model():
    if STATE["status"] == "training":
        raise ApiError(409, "Your voice is training. Speaking is paused until it finishes (you can cancel it on the Voices tab).")
    if STATE["status"] == "loading":
        raise ApiError(503, "The voice model is still loading. Wait a few seconds and try again.")
    if STATE["status"] == "error":
        raise ApiError(503, STATE["error"])
    return STATE["model"]


def get_whisper():
    """fp32 on purpose: with timestamps, fp16 Whisper on MPS emits '!!!!' garbage."""
    global _whisper
    with LOAD:
        if _whisper is None:
            from transformers import WhisperForConditionalGeneration, WhisperProcessor
            m = WhisperForConditionalGeneration.from_pretrained(WHISPER, dtype=torch.float32).to("cpu" if LOW_MEM else DEVICE).eval()
            _whisper = (m, WhisperProcessor.from_pretrained(WHISPER))
    return _whisper


def unload_small():
    """Drop ECAPA and DeepFilterNet after a long job (they are small, and reload in a couple of seconds)."""
    global _ecapa
    with LOAD:
        _ecapa = None
    enhance.unload()
    gc.collect()
    free_gpu()


def free_gpu():
    if DEVICE == "mps":
        torch.mps.empty_cache()


def unload_whisper():
    """Drop Whisper (~3 GB) once a prepare/train/studio run is done; it reloads lazily in 5-10 s."""
    global _whisper
    with LOAD:
        _whisper = None
    gc.collect()
    free_gpu()


def transcribe(x, sr, language=None):
    """Whisper on mono audio. Returns (text, segments [(start, end, text)], language code)."""
    from transformers.models.whisper.tokenization_whisper import LANGUAGES
    from omnivoice.utils.lang_map import LANG_IDS
    m, proc = get_whisper()
    x16 = enhance.resample(np.asarray(x, dtype=np.float32), sr, 16000)
    long = len(x16) > 30 * 16000  # >30 s uses Whisper's sequential long-form decoding
    f = proc.feature_extractor(x16, sampling_rate=16000, return_tensors="pt", truncation=not long,
                               padding="longest" if long else "max_length", return_attention_mask=long)
    feats = f.input_features.to(m.device)
    with (GPU if m.device.type != "cpu" else contextlib.nullcontext()), torch.no_grad():
        if not language:
            tok = proc.tokenizer.convert_ids_to_tokens(int(m.detect_language(input_features=feats[:1]).flatten()[0])).strip("<|>")
            language = tok if tok in LANG_IDS else None
        kw = {"language": language} if language in LANGUAGES else {}
        if long:
            out = m.generate(feats, attention_mask=f.attention_mask.to(m.device), return_timestamps=True, return_segments=True, task="transcribe", **kw)
            segs = [(float(s["start"]), float(s["end"]), proc.tokenizer.decode(s["tokens"], skip_special_tokens=True)) for s in out["segments"][0]]
        else:
            seq = m.generate(feats, return_timestamps=True, task="transcribe", **kw)
            segs = [(o["timestamp"][0], o["timestamp"][1] if o["timestamp"][1] is not None else len(x16) / 16000, o["text"])
                    for o in proc.tokenizer.decode(seq[0], output_offsets=True, skip_special_tokens=True)["offsets"]]
    return "".join(t for _, _, t in segs).strip(), segs, language


def ecapa_embed(x, sr):
    global _ecapa
    with LOAD:
        if _ecapa is None:
            from huggingface_hub import snapshot_download
            from speechbrain.inference.speaker import EncoderClassifier
            src = snapshot_download("speechbrain/spkrec-ecapa-voxceleb")
            _ecapa = EncoderClassifier.from_hparams(source=src, savedir=data_dir("voice-tmp", "ecapa"), run_opts={"device": "cpu"})
    t = torch.from_numpy(enhance.resample(np.asarray(x, dtype=np.float32), sr, 16000))[None]
    with torch.no_grad():
        return _ecapa.encode_batch(t).flatten()


def similarity(x, sr, ref_path):
    m = os.path.getmtime(ref_path)
    if ref_path not in _embeds or _embeds[ref_path][0] != m:
        r, rsr = read_audio(ref_path)
        _embeds[ref_path] = (m, ecapa_embed(r, rsr))
    return float(torch.nn.functional.cosine_similarity(ecapa_embed(x, sr), _embeds[ref_path][1], dim=0))


def norm_text(s):
    return re.sub(r"[\W_]+", "", s.lower())


def cer(ref, hyp):
    a, b = norm_text(ref), norm_text(hyp)
    if not a:
        return 0.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[-1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1] / len(a)


# ---------------------------------------------------------------- audio io

def check_audio_path(path):
    if not isinstance(path, str) or not os.path.isabs(path) or not os.path.isfile(path):
        raise bad("Kitflo couldn't find that audio file. Choose it again.")
    return path


def too_long(info):
    if info.duration > MAX_AUDIO_S:
        raise bad("That recording is longer than 15 minutes. Trim it and try again.")


def read_audio(path):
    """Mono float32 + rate. Falls back to macOS afconvert for formats libsndfile cannot read (m4a)."""
    check_audio_path(path)
    src, tmp = path, None
    try:
        try:
            info = sf.info(src)
        except Exception:
            tmp = data_dir("voice-tmp", f"conv-{uuid.uuid4().hex[:8]}.wav")
            subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16", path, tmp], check=True, capture_output=True)
            src, info = tmp, sf.info(tmp)
        too_long(info)  # before reading the samples into memory
        x, sr = sf.read(src, dtype="float32", always_2d=True)
    except ApiError:
        raise
    except Exception:
        raise bad("Kitflo couldn't read that audio file. Export it as WAV, MP3 or M4A and try again.")
    finally:
        if tmp and os.path.exists(tmp):
            os.remove(tmp)
    return x.mean(axis=1), sr


def write_wav(path, x, sr):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sf.write(path, x, sr, subtype="PCM_16")


def out_path(label, ext="wav"):
    slug = re.sub(r"[^a-z0-9]+", "-", label.lower())[:30].strip("-") or "audio"
    return data_dir("voice-out", f"{datetime.now():%Y%m%d-%H%M%S}-{slug}-{uuid.uuid4().hex[:6]}.{ext}")


def text_arg(body, key):
    v = body.get(key)
    if v is None:
        return ""
    if not isinstance(v, str):
        raise bad(f"'{key}' must be text.")
    return v


def evict(prefix):
    """Forget cached prompts/embeddings whose file path starts with prefix."""
    for cache in (_prompts, _embeds):
        for k in [k for k in cache if k.startswith(prefix)]:
            cache.pop(k, None)


def new_job(message):
    now = time.time()
    for k in [k for k, t in list(JOB_AT.items()) if now - t > 3600 and JOBS.get(k, {}).get("state") != "running"]:
        JOBS.pop(k, None)
        JOB_AT.pop(k, None)
    jid = uuid.uuid4().hex[:10]
    JOBS[jid] = {"state": "running", "progress": 0.0, "message": message, "result": None, "error": None}
    JOB_AT[jid] = now
    return jid, JOBS[jid]


def fail_job(j, e, fallback):
    if not isinstance(e, ApiError):
        traceback.print_exc()
    j.update(state="failed", error=e.message if isinstance(e, ApiError) else fallback)


# ---------------------------------------------------------------- languages and voices

def lang_table():
    from omnivoice.utils.lang_map import LANG_NAME_TO_ID, lang_display_name
    names = {}
    for n, c in sorted(LANG_NAME_TO_ID.items()):
        names.setdefault(c, lang_display_name(n))
    return names


def resolve_lang(s):
    from omnivoice.utils.lang_map import LANG_IDS, LANG_NAME_TO_ID
    if s and s.lower() == "auto":
        return None  # detect it; also how mixed text like Hinglish is spoken
    if s in LANG_IDS:
        return s
    if s and s.lower() in LANG_NAME_TO_ID:
        return LANG_NAME_TO_ID[s.lower()]
    raise bad(f"Kitflo doesn't know the language '{s}'. Pick one from the language list.")


def vdir(vid):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", vid or ""):
        raise ApiError(404, "That voice doesn't exist. Refresh the voice list.")
    return data_dir("voices", vid)


def load_voice(vid):
    try:
        with open(os.path.join(vdir(vid), "voice.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        raise ApiError(404, "That voice doesn't exist any more. Refresh the voice list.")


def store_voice(v):
    d = vdir(v["id"])
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, "voice.json.tmp")
    with open(tmp, "w") as f:
        json.dump(v, f, ensure_ascii=False, indent=1)
    os.replace(tmp, os.path.join(d, "voice.json"))


def all_voices():
    out = []
    root = data_dir("voices")
    for vid in os.listdir(root) if os.path.isdir(root) else []:
        try:
            out.append(load_voice(vid))
        except ApiError:
            pass
    return sorted(out, key=lambda v: v.get("created_at", ""), reverse=True)


def find_voice(key):
    """Kitflo voice by id or (case-insensitive) name; None means the default voice."""
    for v in all_voices():
        if key == v["id"] or key.lower() == v["name"].lower():
            return v
    return None


def save_voice(voice_id, name, code, wav, ref_text, quality=None, wav_sr=SR, ceiling=None):
    """Write ref wav + cached prompt for one language of a voice. `wav` is a float array."""
    model()
    ceiling = min(max(ceiling, 0.5), 1.0) if ceiling else CEILING_DEFAULT
    with FILES:
        v = load_voice(voice_id) if voice_id else {"id": "v-" + uuid.uuid4().hex[:8], "name": name, "consent": True,
                                                  "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "languages": {}}
        d = vdir(v["id"])
        os.makedirs(d, exist_ok=True)
        ref = os.path.join(d, f"ref-{code}.wav")
        write_wav(ref, enhance.resample(wav, wav_sr, SR), SR)
        with GPU:
            prompt = model().create_voice_clone_prompt(ref_audio=ref, ref_text=ref_text, preprocess_prompt=True)
        prompt.save(os.path.join(d, f"prompt-{code}.pt"))
        v["languages"][code] = {"ref_text": ref_text, "duration_s": round(len(wav) / wav_sr, 2), "quality": quality,
                                "ceiling": round(ceiling, 4)}
        store_voice(v)
        return v


def get_prompt(vid, code):
    p = os.path.join(vdir(vid), f"prompt-{code}.pt")
    m = os.path.getmtime(p)
    if p not in _prompts or _prompts[p][0] != m:
        from omnivoice.models.omnivoice import VoiceClonePrompt
        _prompts[p] = (m, VoiceClonePrompt.load(p))
    return _prompts[p][1]


# ---------------------------------------------------------------- prepare / train

def analyse(src, enh, sr):
    """Per-20 ms facts the picker and quality checks share."""
    h = int(sr * 0.02)
    n = min(len(src), len(enh)) // h

    def db(x):
        return 10 * np.log10(np.mean(x[: n * h].reshape(n, h) ** 2, axis=1) + 1e-10)

    e = db(enh)
    thr = max(np.percentile(e, 10) + 12, np.percentile(e, 95) - 30)
    return {"h": h, "n": n, "src_db": db(src), "voiced": e > thr,
            "clip": (np.abs(src[: n * h]).reshape(n, h) >= 0.99).mean(axis=1)}


def frames(a, sr, lo, hi):
    h = a["h"] / sr
    return slice(max(int(lo / h), 0), min(max(int(hi / h), int(lo / h) + 1), a["n"]))


def passage_score(a, sr):
    def score(lo, hi):
        s = frames(a, sr, lo, hi)
        d = a["src_db"][s]
        snr = np.percentile(d, 90) - np.percentile(d, 10) if len(d) else 0
        return a["voiced"][s].sum() * 0.02 - 100 * a["clip"][s].mean() - 0.05 * max(0, 30 - snr)
    return score


def quality_report(a, sr, lo, hi, clip_wav, dur, fallback):
    s = frames(a, sr, lo, hi)
    d = a["src_db"][s]
    snr = float(np.percentile(d, 90) - np.percentile(d, 10)) if len(d) else 0.0
    clip = float(a["clip"][s].mean()) if len(d) else 0.0
    loud = enhance.lufs(clip_wav, sr)
    speech = float(a["voiced"][s].mean()) if len(d) else 0.0
    checks = [  # (id, penalty, ok, message if failing, message if passing, tip)
        ("length", 25, dur >= 3, f"The sample is only {dur:.1f} s long.", f"Sample length is {dur:.1f} s.", "Use a recording with at least 3 s of continuous speech."),
        ("clipping", 15, clip < 0.001, "The recording is clipping (distorted peaks).", "No clipping.", "Record again with the mic further away or the input level lower."),
        ("noise", 20, snr >= 20, f"Background noise is high (signal-to-noise about {snr:.0f} dB).", f"Clean background (about {snr:.0f} dB signal-to-noise).", "Record in a quieter room, closer to the microphone."),
        ("loudness", 10, loud > -40, f"The voice is very quiet ({loud:.0f} LUFS).", f"Good level ({loud:.0f} LUFS).", "Move closer to the microphone or raise the input level."),
        ("speech", 20, speech >= 0.6, f"Only {speech * 100:.0f}% of the sample is speech.", f"{speech * 100:.0f}% of the sample is speech.", "Pick a recording with fewer long pauses."),
        ("sentences", 15, not fallback, "No clean run of whole sentences was found.", "Whole sentences, cleanly cut.", "Speak in clear, complete sentences with a short pause between them."),
    ]
    score = max(0, 100 - sum(p for _, p, ok, *_ in checks if not ok))
    return {"score": score, "checks": [{"id": i, "ok": bool(ok), "message": bad if not ok else good, "tip": "" if ok else t}
                                       for i, _, ok, bad, good, t in checks]}


def segment(path, language, n_best=None):
    """Enhance + transcribe + pick. Up to n_best candidate passages (default: 3 for sources of 20 s or more, else 1)."""
    src, sr = read_audio(path)
    if len(src) < sr * 1.0:
        raise bad("That recording is under a second long. Record at least 3 seconds of speech.")
    enh, _, _ = enhance.process(src, sr, "clean")
    code = resolve_lang(language) if language else None
    text, words, code = transcribe(enh, sr, code)
    if not words:
        raise bad("Kitflo couldn't hear any speech in that recording. Check the right file is selected and try again.")
    a = analyse(src, enh, sr)
    score = passage_score(a, sr)
    total = len(src) / sr
    sents = [w for w in words if w[2].strip()]  # Whisper segments are sentence-sized
    cands, segs = [], list(sents)
    for _ in range(n_best or (3 if total >= 20 else 1)):
        r = pick.pick(sents, total, score)
        cands.append(r)
        if r["fallback"]:
            break
        sents = [s for s in sents if s[1] <= r["start"] or s[0] >= r["end"]]  # exclude the span just used
    out = []
    for r in cands:
        lo, hi = r["start"], r["end"]
        ref_text = "" if r["fallback"] else "".join(t for s, e, t in words if lo - 0.05 <= (s + e) / 2 <= hi + 0.05).strip()
        fr = frames(a, sr, lo, hi)
        voiced = np.flatnonzero(a["voiced"][fr])
        if len(voiced):  # trim to the speech inside the span (never before its start), 0.15 s padding
            lo = max(lo, (fr.start + voiced[0]) * 0.02 - 0.15)
            hi = (fr.start + voiced[-1] + 1) * 0.02 + 0.15
        lo = max(lo, 0.0)
        hi = min(hi, lo + 10, total)
        wav = enhance.normalize(enhance.resample(enh[int(lo * sr): int(hi * sr)], sr, SR), SR)
        if len(wav) < 3 * SR:  # OmniVoice wants 3-10 s; pad short clips with silence
            k = 3 * SR - len(wav)
            wav = np.pad(wav, (k // 2, k - k // 2))
        if r["fallback"]:  # window cuts mid-sentence, so ask Whisper what is actually inside it
            ref_text = transcribe(wav, SR, code)[0]
        out.append({"start": lo, "end": hi, "wav": wav, "ref_text": ref_text, "fallback": r["fallback"],
                    "quality": quality_report(a, sr, r["start"], r["end"], src[int(r["start"] * sr): int(r["end"] * sr)], hi - lo, r["fallback"])})
    unload_whisper()  # the clone tests that follow don't need it, and peak memory is the sum of what is loaded at once
    return {"cands": out, "language": code, "text": text, "segs": segs, "src": src, "enh": enh, "sr": sr, "a": a}


def waveform(x, n=200):
    k = max(len(x) // n, 1)
    p = np.array([np.abs(x[i * k:(i + 1) * k]).max() if len(x[i * k:(i + 1) * k]) else 0 for i in range(n)])
    return [round(float(v), 3) for v in p / max(p.max(), 1e-9)]


def heldout_embeds(seg, c):
    """Speaker embeddings of up to 12 speech windows (4-8 s) of the recording that lie outside passage c."""
    a, sr, enh = seg["a"], seg["sr"], seg["enh"]
    wins = []
    for lo, hi in ((0.0, c["start"] - 0.5), (c["end"] + 0.5, len(enh) / sr)):
        t = lo
        while t + 4 <= hi:
            e = min(t + 8, hi)
            v = a["voiced"][frames(a, sr, t, e)]
            if len(v) and v.mean() >= 0.5:
                wins.append((t, e))
            t = e
    wins = [wins[int(i * len(wins) / 12)] for i in range(12)] if len(wins) > 12 else wins
    return [ecapa_embed(enh[int(lo * sr): int(hi * sr)], sr) for lo, hi in wins]


def mean_cos(e, embs):
    return float(np.mean([torch.nn.functional.cosine_similarity(e, x, dim=0).item() for x in embs]))


def ceiling_of(seg, c, embs):
    """How well the speaker's own real speech matches itself: the chosen passage vs the held-out rest."""
    if len(embs) < 2:
        return None
    sr = seg["sr"]
    return mean_cos(ecapa_embed(seg["enh"][int(c["start"] * sr): int(c["end"] * sr)], sr), embs)


def rank_passages(seg, code, test, with_intel=False, on_step=None):
    """Clone-test every candidate: build a prompt, say `test`, score the take against held-out real speech
    (never the passage itself, which would inflate the score). Returns [(score, embs) or None] per candidate."""
    model()
    sr, out = seg["sr"], []
    for i, c in enumerate(seg["cands"]):
        if on_step:
            on_step(i, len(seg["cands"]))
        if not c["ref_text"]:
            out.append(None)
            continue
        embs = heldout_embeds(seg, c)
        with GPU:
            prompt = model().create_voice_clone_prompt(ref_audio=(torch.from_numpy(c["wav"])[None], SR), ref_text=c["ref_text"], preprocess_prompt=True)
        take = speak_prompt(prompt, code, test, STEPS["balanced"], 1.0, 1234)
        sim = mean_cos(ecapa_embed(take, SR), embs or [ecapa_embed(seg["enh"][: sr * 180], sr)])  # too short for held-out: whole recording
        out.append([sim, embs, take])
    if with_intel:  # Whisper only after all generation, so it never sits in memory next to the generator
        for r in out:
            if r:
                r[0] = 0.6 * r[0] + 0.4 * (1 - min(cer(test, transcribe(r[2], SR, code)[0]), 1))
        unload_whisper()
    return [(r[0], r[1]) if r else None for r in out]


def test_text(seg, code):
    far = lambda s, e: all(e <= c["start"] or s >= c["end"] for c in seg["cands"])  # a sentence no candidate contains
    return TEST_TEXT.get(code) or next((t.strip() for s, e, t in seg["segs"] if len(t) > 20 and far(s, e)), TEST_TEXT["en"])


def prepare(body):
    try:
        return _prepare(body)
    finally:
        unload_whisper()


def _prepare(body):
    not_training()
    lang = body.get("language")
    if lang is not None and not isinstance(lang, str):
        raise bad("'language' must be text.")
    seg = segment(check_audio_path(body.get("audio_path")), lang)
    best, ceiling = 0, None
    if len(seg["cands"]) > 1 and STATE["status"] == "ready":  # 20 s+ source: pick by how well each passage actually clones
        ranked = rank_passages(seg, seg["language"], test_text(seg, seg["language"]))
        best = max((i for i, r in enumerate(ranked) if r), key=lambda i: ranked[i][0], default=0)
        ceiling = ceiling_of(seg, seg["cands"][best], ranked[best][1]) if ranked[best] else None
    elif len(seg["src"]) / seg["sr"] >= 20:  # model still loading: keep the heuristic pick, still measure the ceiling
        ceiling = ceiling_of(seg, seg["cands"][0], heldout_embeds(seg, seg["cands"][0]))
    c = seg["cands"][best]
    if not c["ref_text"]:
        raise bad("Kitflo couldn't hear any speech in that recording. Check the right file is selected and try again.")
    ref = data_dir("voice-tmp", f"prepare-{uuid.uuid4().hex[:8]}.wav")
    write_wav(ref, c["wav"], SR)
    key = os.path.realpath(ref)
    QUALITY[key], DETECTED[key], CEILING[key] = c["quality"]["score"], seg["language"], ceiling
    return {"ref_path": ref, "ref_text": c["ref_text"], "start": round(c["start"], 2), "end": round(c["end"], 2),
            "duration_s": round(len(c["wav"]) / SR, 2), "source_duration_s": round(len(seg["src"]) / seg["sr"], 2),
            "language": seg["language"], "transcript_full": seg["text"], "waveform": waveform(seg["src"]),
            "quality": c["quality"]}


QUALITY = {}  # prepared ref_path -> quality score, so /voices/save can store it
CEILING = {}  # prepared ref_path -> real-speech ceiling (None if the source was under 20 s)
DETECTED = {}  # prepared ref_path -> detected language, used when the app saves with "auto"


def name_arg(body, required):
    name = text_arg(body, "name").strip()
    if required and not name:
        raise bad("Give the voice a name first.")
    if len(name) > 100:
        raise bad("Voice names can be at most 100 characters.")
    return name


def consent_arg(body, again):
    if body.get("consent") is not True:
        raise bad(f"Voice cloning needs your confirmation that you have the right to clone this voice. Tick the consent box and {again} again.")


def voice_id_arg(body):
    v = body.get("voice_id")
    if v is not None and not isinstance(v, str):
        raise bad("'voice_id' must be text.")
    return v or None


def save(body):
    consent_arg(body, "save")
    vid = voice_id_arg(body)
    name = name_arg(body, required=not vid)
    ref_text = text_arg(body, "ref_text").strip()
    code = resolve_lang(text_arg(body, "language"))
    ref = os.path.realpath(text_arg(body, "ref_path"))
    code = code or DETECTED.get(ref) or "en"
    DETECTED.pop(ref, None)
    ceiling = CEILING.pop(ref, None)
    if not ref.startswith(os.path.realpath(data_dir("voice-tmp")) + os.sep):
        raise bad("The prepared sample is missing. Prepare the recording again, then save.")
    if not os.path.isfile(ref):
        raise bad("This prepared sample was already saved. Record or prepare a new clip for each language.")
    if not ref_text:
        raise bad("The transcript of the sample is empty. Prepare the recording again, then save.")
    wav, sr = read_audio(ref)
    v = save_voice(vid, name, code, wav, ref_text, QUALITY.pop(ref, None), sr, ceiling)
    os.remove(ref)
    return {"voice": v}


def train(body):
    not_training()
    consent_arg(body, "start")
    vid = voice_id_arg(body)
    name = name_arg(body, required=not vid)
    path = check_audio_path(body.get("audio_path"))
    lang = text_arg(body, "language")
    resolve_lang(lang)
    model()
    jid, j = new_job("Listening to the recording")

    def run():
        try:
            seg = segment(path, lang, n_best=5)
            code = seg["language"] or "en"

            def step(i, n):
                j["message"], j["progress"] = f"Trying passage {i + 1} of {n}", 0.2 + 0.7 * i / n

            ranked = rank_passages(seg, code, test_text(seg, code), with_intel=True, on_step=step)
            good = [i for i, r in enumerate(ranked) if r]
            if not good:
                raise bad("None of the passages in that recording could be used. Record again in clear sentences.")
            i = max(good, key=lambda i: ranked[i][0])
            c = seg["cands"][i]
            j["message"], j["progress"] = "Saving the voice", 0.95
            v = save_voice(vid, name, code, c["wav"], c["ref_text"], c["quality"]["score"], ceiling=ceiling_of(seg, c, ranked[i][1]))
            j.update(state="done", progress=1.0, message="Done", result={"voice": v})
        except Exception as e:
            fail_job(j, e, "Training failed unexpectedly. Try again with a clearer recording.")
        finally:
            unload_whisper()

    threading.Thread(target=run, daemon=True).start()
    return {"job_id": jid}


# ---------------------------------------------------------------- speak

def spoken_numbers(text, code):
    from num2words import num2words

    def sub(m):
        try:
            return num2words(int(m.group().replace(",", "")), lang=code)
        except (NotImplementedError, OverflowError, ValueError):
            return m.group()
    return re.sub(r"(?<![\d.,])(?:\d{1,3}(?:,\d{3})+|\d+)(?!\d|[.,]\d)", sub, text)


def join(parts, fade=int(0.03 * SR)):
    parts = [p for p in parts if len(p)]
    if not parts:
        raise bad("Nothing could be spoken from that text. Add some words and try again.")
    out = parts[0]
    for p in parts[1:]:
        k = min(fade, len(out), len(p))
        ramp = np.linspace(0, 1, k, dtype=np.float32)
        out = np.concatenate([out[:-k], out[-k:] * (1 - ramp) + p[:k] * ramp, p[k:]])
    return out


def speak_prompt(prompt, code, text, steps, speed, seed, step=None, adapter=None):
    """Generate `text` with one prompt (None = default voice). Takes the GPU lock; `step()` runs after each chunk.
    `adapter` is a voice id whose Pro adapter to apply; None always means the base weights."""
    from omnivoice.models.omnivoice import OmniVoiceGenerationConfig
    cfg = OmniVoiceGenerationConfig(num_step=steps, guidance_scale=GUIDANCE)
    parts = []
    with GPU:
        m = model()  # fetched under the lock: a request that waited out a training run must not hold the old model
        with pro.activate(THIS, adapter):
            for c in chunks(spoken_numbers(text, code or "en")):
                torch.manual_seed(seed)  # OmniVoice.generate takes no seed
                parts.append(np.asarray(m.generate(text=c, language=code, voice_clone_prompt=prompt, speed=speed, generation_config=cfg)[0], dtype=np.float32))
                if step:
                    step()
    return enhance.limit_peak(join(parts), sr=SR)


def speed_arg(v):
    if v is None:
        return 1.0
    if isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v):
        raise bad("Speed must be a number between 0.5 and 2.0.")
    return min(max(float(v), 0.5), 2.0)


def seed_arg(v):
    if v is None:
        return random.randrange(2 ** 30)
    if isinstance(v, bool) or not isinstance(v, int) or not 0 <= v < 2 ** 31 - 4:
        raise bad("Seed must be a whole number from 0 to 2,147,483,643.")
    return v


def parse_speak(body, text_key="text", voice_key="voice_id", preset_key="preset", by_name=False):
    """Validate a speak-style request. Cheap and side-effect free, so jobs can reject bad input up front."""
    text = text_arg(body, text_key)
    if not text.strip():
        raise bad("There's no text to speak. Type something first.")
    if len(text) > MAX_TEXT:
        raise bad(f"That text is {len(text):,} characters. Split it into parts of 5,000 characters or fewer.")
    preset = body.get(preset_key) or "balanced"
    if preset not in STEPS:
        raise bad("Quality must be fast, balanced or studio.")
    lang = body.get("language")
    if lang is not None and not isinstance(lang, str):
        raise bad("'language' must be text.")
    key = text_arg(body, voice_key)
    voice = find_voice(key) if key else None
    if key and not voice and not by_name:
        raise ApiError(404, "That voice doesn't exist any more. Refresh the voice list.")
    return {"text": text, "preset": preset, "language": resolve_lang(lang) if lang else None, "voice": voice,
            "speed": speed_arg(body.get("speed")), "seed": seed_arg(body.get("seed"))}


def synth(a, tick=None):
    """Returns (audio, takes, similarity, intelligibility, language_matched). tick(done, total) after each chunk."""
    model()
    voice, code, text = a["voice"], a["language"], a["text"]
    matched, prompt, ref, adapter = True, None, None, None
    if voice:
        langs = voice["languages"]
        if not langs:
            raise bad("That voice has no recordings yet. Add a language to it first.")
        rc = code if code in langs else next(iter(langs))  # no sample in this language: clone from the first one, still speak `code`
        matched = code is None or code in langs  # code None = Auto: OmniVoice reads the language (or a mix) from the text
        prompt, ref = get_prompt(voice["id"], rc), os.path.join(vdir(voice["id"]), f"ref-{rc}.wav")
        adapter = voice["id"] if pro.has_adapter(THIS, voice) else None
    takes = STUDIO_TAKES if a["preset"] == "studio" else 1
    total, done = takes * len(chunks(spoken_numbers(text, code or "en"))), [0]

    def step():
        done[0] += 1
        if tick:
            tick(done[0], total)

    ceiling = voice["languages"][rc].get("ceiling", CEILING_DEFAULT) if voice else None
    audios = [speak_prompt(prompt, code, text, STEPS[a["preset"]], a["speed"], a["seed"] + k, step, adapter) for k in range(takes)]
    sims = [similarity(x, SR, ref) if ref else None for x in audios]
    intels = [1 - min(cer(text, transcribe(x, SR, code)[0]), 1) if a["preset"] == "studio" else None for x in audios]  # after generating, so Whisper and the generator aren't resident together
    best = max(range(takes), key=lambda k: 0.6 * (sims[k] or 0) + 0.4 * (intels[k] or 0))
    best = (0, audios[best], sims[best], intels[best])
    if a["preset"] == "studio":
        unload_whisper()
    return best[1], takes, best[2], best[3], matched, ceiling


def run_speak(a, tick=None):
    audio, takes, sim, intel, matched, ceiling = synth(a, tick)
    p = out_path(a["text"])
    write_wav(p, audio, SR)
    r = {"path": p, "duration_s": round(len(audio) / SR, 2), "takes": takes, "language_matched": matched}
    if sim is not None:
        r["similarity"] = round(sim, 4)  # vs the voice's reference clip
        r["match"] = round(max(0.0, min(sim / ceiling, 1.0)), 4)  # similarity relative to how well the speaker's real speech matches itself
    if intel is not None:
        r["intelligibility"] = round(intel, 4)
    return r


def speak_job(body):
    a = parse_speak(body)
    model()
    jid, j = new_job("Starting")

    def tick(done, total):
        j["progress"], j["message"] = min(done / total, 0.99), f"Speaking part {min(done + 1, total)} of {total}"

    def run():
        try:
            j.update(state="done", progress=1.0, message="Done", result=run_speak(a, tick))
        except Exception as e:
            fail_job(j, e, "Speaking failed unexpectedly. Try again.")
        finally:
            free_gpu()

    threading.Thread(target=run, daemon=True).start()
    return {"job_id": jid}


def warm(vid, body):
    """Load (or rebuild) a voice's prompt into the cache and run a tiny generate so the first real one is fast."""
    v = load_voice(vid)
    lang = text_arg(body, "language")
    code = (resolve_lang(lang) if lang else None) or next(iter(v["languages"]), None)
    if code not in v["languages"]:
        raise bad("That voice has no sample in that language. Add one first.")
    model()
    d = vdir(vid)
    if not os.path.isfile(os.path.join(d, f"prompt-{code}.pt")):
        with GPU:
            model().create_voice_clone_prompt(ref_audio=os.path.join(d, f"ref-{code}.wav"), ref_text=v["languages"][code]["ref_text"],
                                        preprocess_prompt=True).save(os.path.join(d, f"prompt-{code}.pt"))
    speak_prompt(get_prompt(vid, code), code, "Hi.", 8, 1.0, 0, adapter=vid if pro.has_adapter(THIS, v) else None)
    return {"ok": True}


def enhance_file(body):
    level = body.get("level") or "clean"
    if level not in ("clean", "studio"):
        raise bad("Enhance level must be clean or studio.")
    path = check_audio_path(body.get("audio_path"))
    x, sr = read_audio(path)
    y, before, after = enhance.process(x, sr, level)
    p = out_path(f"enhanced-{os.path.splitext(os.path.basename(path))[0]}")
    write_wav(p, y, sr)
    return {"path": p, "duration_s": round(len(y) / sr, 2), "before_lufs": round(before, 1), "after_lufs": round(after, 1)}


def openai_speech(body):
    fmt = text_arg(body, "response_format").lower() or "wav"
    if fmt not in ("wav", "flac", "pcm"):
        raise bad(f"The '{fmt}' format isn't supported. Use response_format 'wav' (or 'flac' or 'pcm').")
    a = parse_speak(body, "input", "voice", "quality", by_name=True)  # unknown / OpenAI voice names fall back to the default voice
    audio = synth(a)[0]
    if fmt == "pcm":
        return (audio * 32767).astype("<i2").tobytes(), "audio/pcm"
    buf = io.BytesIO()
    sf.write(buf, audio, SR, format=fmt.upper(), subtype="PCM_16")
    return buf.getvalue(), "audio/wav" if fmt == "wav" else "audio/flac"


def wav_bytes(x, sr):
    buf = io.BytesIO()
    sf.write(buf, x, sr, format="WAV", subtype="PCM_16")
    return buf.getvalue()


# ---------------------------------------------------------------- http

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    body = b""

    def log_message(self, fmt, *a):
        pass

    def send(self, status, payload, ctype="application/json"):
        data = payload if isinstance(payload, bytes) else json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        if status >= 400:  # an error may leave an unread request body on the socket: don't reuse the connection
            self.close_connection = True
            self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)

    def json_body(self):
        try:
            b = json.loads(self.body or b"{}")
            assert isinstance(b, dict)
            return b
        except Exception:
            raise bad("The request wasn't valid JSON. Update Kitflo and try again.")

    def authorized(self, path):
        tok = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
        ok = lambda k: bool(k) and hmac.compare_digest(tok.encode(), k.encode())
        if ok(CFG["key"]):
            return True
        if path.startswith("/v1/"):  # user API key, re-read every request so toggling needs no restart
            try:
                with open(data_dir("voice-api.json")) as f:
                    c = json.load(f)
                return bool(c.get("enabled")) and ok(c.get("key") or "")
            except Exception:
                return False
        return False

    def serve(self, method):
        u = urlparse(self.path)
        path, q = u.path.rstrip("/") or "/", {k: v[0] for k, v in parse_qs(u.query).items()}
        try:
            # a web page can reach 127.0.0.1 too; only our own host names are served (blocks DNS rebinding)
            if self.headers.get("Host") not in (f"127.0.0.1:{CFG['port']}", f"localhost:{CFG['port']}"):
                raise ApiError(403, "Kitflo's voice engine only answers requests addressed to 127.0.0.1 or localhost.")
            try:
                n = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                n = -1
            if n < 0:
                raise bad("The request had an invalid Content-Length.")
            if n > MAX_BODY:
                raise ApiError(413, "That request is larger than 50 MB. Send a shorter recording.")
            if path == "/health" and method == "GET":
                h = {"status": STATE["status"], "device": DEVICE, "error": STATE["error"]}
                if q.get("nonce"):  # proves to Kitflo this is the engine it started, not something else squatting the port
                    h["proof"] = hmac.new(CFG["key"].encode(), q["nonce"].encode(), "sha256").hexdigest()
                return self.send(200, h)
            if not self.authorized(path):
                raise ApiError(401, "Kitflo's voice engine didn't accept that key. Check the API key in Kitflo's Voice settings.")
            self.body = self.rfile.read(n) if n else b""
            self.route(method, path, q)
            free_gpu()  # hand cached MPS blocks back after every request
        except ApiError as e:
            self.send(e.status, {"error": e.message})
        except Exception:
            traceback.print_exc()
            self.send(500, {"error": UNEXPECTED})

    def route(self, method, path, q):
        parts = path.strip("/").split("/")
        if method == "GET":
            if path == "/languages":
                return self.send(200, {"languages": sorted(({"code": c, "name": n} for c, n in lang_table().items()), key=lambda d: d["name"])})
            if path == "/voices":
                return self.send(200, {"voices": all_voices()})
            if len(parts) == 3 and parts[0] == "voices" and parts[2] == "preview":
                v = load_voice(parts[1])
                code = q.get("lang") or next(iter(v["languages"]), "")
                if not CODE.fullmatch(code):
                    raise bad("That language code isn't valid. Pick one from the language list.")
                p = os.path.join(vdir(v["id"]), f"ref-{code}.wav")
                if not os.path.isfile(p):
                    raise ApiError(404, "That voice has no sample in that language.")
                with open(p, "rb") as f:
                    return self.send(200, f.read(), "audio/wav")
            if len(parts) == 2 and parts[0] == "jobs":
                if parts[1] not in JOBS:
                    raise ApiError(404, "That job doesn't exist any more. Start it again.")
                return self.send(200, JOBS[parts[1]])
            if path == "/v1/audio/voices":
                return self.send(200, {"voices": [{"voice_id": v["id"], "name": v["name"], "languages": list(v["languages"])} for v in all_voices()]})
        elif method == "POST":
            if path == "/voices/prepare":
                return self.send(200, prepare(self.json_body()))
            if path == "/voices/save":
                return self.send(200, save(self.json_body()))
            if path == "/voices/train":
                return self.send(200, train(self.json_body()))
            if len(parts) == 3 and parts[0] == "voices" and parts[2] == "warm":
                return self.send(200, warm(parts[1], self.json_body()))
            if path == "/pro/scan":
                return self.send(200, pro.start_scan(THIS, self.json_body()))
            if path == "/pro/train":
                return self.send(200, pro.start_train(THIS, self.json_body()))
            if path == "/pro/cancel":
                ev = CANCEL.get(text_arg(self.json_body(), "job_id"))
                if ev is None:
                    raise ApiError(404, "That job isn't running any more.")
                ev.set()
                return self.send(200, {"ok": True})
            if len(parts) == 4 and parts[0] == "voices" and parts[2:] == ["pro", "enabled"]:
                en = self.json_body().get("enabled")
                if not isinstance(en, bool):
                    raise bad("'enabled' must be true or false.")
                return self.send(200, {"voice": pro.set_enabled(THIS, parts[1], en)})
            if path == "/speak":
                return self.send(200, run_speak(parse_speak(self.json_body())))
            if path == "/speak/jobs":
                return self.send(200, speak_job(self.json_body()))
            if path == "/enhance":
                return self.send(200, enhance_file(self.json_body()))
            if path == "/v1/audio/speech":
                data, ctype = openai_speech(self.json_body())
                return self.send(200, data, ctype)
            if path == "/v1/audio/enhance":
                level = q.get("level", "clean")
                if level not in ("clean", "studio"):
                    raise bad("Enhance level must be clean or studio.")
                try:
                    too_long(sf.info(io.BytesIO(self.body)))
                except ApiError:
                    raise
                except Exception:
                    raise bad("Couldn't read that audio. Send WAV, FLAC or OGG bytes.")
                x, sr = sf.read(io.BytesIO(self.body), dtype="float32", always_2d=True)
                return self.send(200, wav_bytes(enhance.process(x.mean(axis=1), sr, level)[0], sr), "audio/wav")
        elif method == "PATCH" and len(parts) == 2 and parts[0] == "voices":
            name = name_arg(self.json_body(), required=True)
            with FILES:
                v = load_voice(parts[1])
                v["name"] = name
                store_voice(v)
            return self.send(200, {"voice": v})
        elif method == "DELETE" and parts[0] == "voices":
            if len(parts) == 2:
                if pro.PRO.get("training") == parts[1]:
                    raise ApiError(409, "That voice is training. Cancel the training first, then delete it.")
                with FILES:
                    load_voice(parts[1])
                    d = vdir(parts[1])
                    with GPU:  # nothing may be generating with this voice's adapter while its files go
                        pro.drop(parts[1])
                        try:
                            shutil.rmtree(d)
                        except OSError:
                            traceback.print_exc()
                            raise ApiError(500, "Kitflo couldn't delete that voice's files. Close anything using them and try again.")
                    evict(d + os.sep)
                return self.send(200, {"ok": True})
            if len(parts) == 3 and parts[2] == "pro":
                if STATE["status"] == "training":
                    raise ApiError(409, "Your voice is training. Cancel it first, or wait for it to finish.")
                return self.send(200, {"voice": pro.delete_pro(THIS, parts[1])})
            if len(parts) == 4 and parts[2] == "languages":
                if not CODE.fullmatch(parts[3]):
                    raise bad("That language code isn't valid. Pick one from the language list.")
                with FILES:
                    v = load_voice(parts[1])
                    v["languages"].pop(parts[3], None)
                    for f in (f"ref-{parts[3]}.wav", f"prompt-{parts[3]}.pt"):
                        p = os.path.join(vdir(v["id"]), f)
                        if os.path.exists(p):
                            os.remove(p)
                        evict(p)
                    store_voice(v)
                return self.send(200, {"voice": v})
        raise ApiError(404, "Kitflo's voice engine doesn't have that endpoint. Update Kitflo and the voice engine together.")

    do_GET = lambda self: self.serve("GET")
    do_POST = lambda self: self.serve("POST")
    do_PATCH = lambda self: self.serve("PATCH")
    do_DELETE = lambda self: self.serve("DELETE")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8180)
    ap.add_argument("--data", required=True)
    a = ap.parse_args()
    key = os.environ.pop("KITFLO_APP_KEY", "")  # env, not argv: other local processes can read argv with ps
    if not key:
        sys.exit("KITFLO_APP_KEY is not set. Start the voice engine from Kitflo, or export KITFLO_APP_KEY first.")
    CFG.update(key=key, data=os.path.abspath(a.data), port=a.port)
    shutil.rmtree(data_dir("voice-tmp"), ignore_errors=True)  # scratch from a previous run
    for d in ("voices", "voice-out", "voice-tmp"):
        os.makedirs(data_dir(d), exist_ok=True)
    threading.Thread(target=load_model, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    srv.daemon_threads = True
    print(f"voice sidecar on 127.0.0.1:{a.port}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
